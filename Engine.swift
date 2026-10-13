// ambilight.swift — streams per-zone screen colors to a WLED controller over UDP.
//
// Capture is done with ScreenCaptureKit configured to output a tiny frame, so the
// GPU/compositor does the downscaling for us. We never touch a full-resolution
// bitmap, which is what keeps this cheap enough to run at 60fps continuously.
//
// Wire format is WLED's DRGB realtime protocol (UDP :21324):
//   byte 0 = 2 (DRGB), byte 1 = timeout seconds, then R,G,B per LED.

import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreBluetooth
import AppKit
import AVFoundation

// MARK: - Config

struct Config {
    var host = "4.3.2.1"
    var port: UInt16 = 21324
    var ledCount = 30
    var fps = 30
    var displayIndex = 0
    var displayID: CGDirectDisplayID?
    var windowID: CGWindowID?
    /// Optional normalized crop, relative to the selected display/window.
    var cropRect: CGRect?
    var layout: LightLayout = .perimeter
    var analysisWidth = 192
    var edgeDepth = 0.20
    var excludeSubtitles = true
    var responseTime = 0.12
    var leftGain = [1.0, 1.0, 1.0]
    var rightGain = [1.0, 1.0, 1.0]
    var reverseLeft = false
    var reverseRight = false
    var swapSides = false
    var bleID: UUID?
    var bleRightID: UUID?
    var listSources = false
    var listDevices = false

    /// Fraction of screen height, measured from the top, that feeds the LEDs.
    /// 1.0 = whole screen. ~0.4 is the classic bias-lighting look for a bar
    /// sitting on top of the monitor.
    var regionHeight = 0.4

    /// Exponential moving average factor. Higher = snappier, more flicker.
    var smoothing = 0.35

    var saturation = 1.35
    var gamma = 2.2
    var brightness = 1.0

    /// Below this luma, fade to black rather than showing muddy grey.
    var blackPoint = 0.04

    /// Blend toward a hue-preserving, brightness-normalized color (0 = off,
    /// 1 = full). A dim screen still has a definite tint; without this, gamma
    /// crushes it to black and the lamp sits dead on an ordinary desktop.
    var normalize = 0.0

    /// How much saturated pixels outweigh grey ones when reducing a zone to a
    /// colour. 0 = plain mean. A plain mean is what makes averaged screen
    /// colour read muddy: grey UI and dark background drag every hue toward
    /// the centre.
    var vividness = 0.6

    /// Mean per-channel change (0...1) that counts as a hard cut. On a cut the
    /// smoothing is bypassed for one frame so the lamp snaps instead of
    /// sliding through an intermediate colour that is in neither shot.
    var cutThreshold = 0.22

    /// Named feel preset: calm | balanced | punchy | movie.
    var profile: String?

    /// Detect letterbox/pillarbox bars and sample only the picture area.
    var letterbox = false
    var selfTest = false

    /// One-shot controller commands (no screen capture).
    var micLevel: Int?      // --mic <0-255>: on-device sound-reactive mode
    var micOff = false      // --mic-off
    var rawFrames: [Data] = []   // --send <hex>, repeatable: protocol probing
    var stepSeconds: Double?     // --step: seconds between one-shot frames
    var sensorDelay = 30
    var catalogue: (Int, Int)?
    var dryRun = false

    /// Modulate intensity with system audio. Captured from the same
    /// ScreenCaptureKit stream as the pixels -- the digital output stream, not
    /// a microphone, so fans and room noise cannot reach it.
    var audio = false
    var audioDepth = 0.15        // 0 = colour only, 1 = fully audio-driven

    var testMode = false
    var preview = false

    /// When set, colors go to a LotusLampX/MELK BLE controller instead of WLED.
    /// That protocol carries one solid color per frame, so the whole bar
    /// becomes a single averaged color.
    var bleName: String?
    var bleRate = 15.0      // writes/sec ceiling
    var bleDeadband = 4     // skip writes smaller than this, per channel

    /// Flags the user passed explicitly, so BLE-mode defaults don't clobber them.
    var explicit = Set<String>()
}

/// Builds a LotusLampX E1 frame: `7E <len> <cmd> p0 p1 p2 p3 p4 EF`.
///
/// There is no checksum. `len` is a hardcoded per-command constant (4 for
/// BRIGHTNESS/SPEED, 6 for DATA_TIME, usually 7) and does not describe the real length,
/// which is always 9. Slots 3-7 are payload; unused ones keep their defaults.
func e1(_ cmd: UInt8, _ params: [UInt8]) -> Data {
    // The `len` byte is a per-command constant, NOT a length -- the frame is
    // always 9 bytes. Most commands use 7, but BRIGHTNESS and SPEED use 4 and
    // the clock-sync command uses 6. Getting this wrong is the likely reason
    // SPEED never visibly did anything.
    let len: UInt8
    switch cmd {
    case 0x01, 0x02: len = 0x04      // BRIGHTNESS, SPEED
    case 0x83:       len = 0x06      // DATA_TIME
    default:         len = 0x07
    }
    var f: [UInt8] = [0x7E, len, cmd,
                      0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0xEF]
    for (i, b) in params.enumerated() where 3 + i < 8 { f[3 + i] = b }
    return Data(f)
}

private func clamp255(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }

/// How much a pixel counts toward its zone's colour. Grey pixels weigh 1;
/// fully saturated ones weigh up to 25x at vividness 1. Defined once so the
/// capture loop and the self-test cannot drift apart.
@inline(__always)
func chromaWeight(_ r: Double, _ g: Double, _ b: Double, _ vividness: Double) -> Double {
    let mx = max(r, max(g, b)), mn = min(r, min(g, b))
    let chroma = (mx - mn) / 255.0
    return 1.0 + vividness * chroma * chroma * 24.0
}

/// Zone reduction over a flat BGRA buffer. The capture loop does the same
/// thing across a strided 2D span.
func weightedMean(_ bgra: [UInt8], vividness: Double) -> (Int, Int, Int) {
    var rs = 0.0, gs = 0.0, bs = 0.0, wsum = 0.0
    var i = 0
    while i + 3 < bgra.count {
        let b = Double(bgra[i]), g = Double(bgra[i + 1]), r = Double(bgra[i + 2])
        let wgt = chromaWeight(r, g, b, vividness)
        rs += r * wgt; gs += g * wgt; bs += b * wgt; wsum += wgt
        i += 4
    }
    guard wsum > 0 else { return (0, 0, 0) }
    return (Int((rs / wsum).rounded()), Int((gs / wsum).rounded()), Int((bs / wsum).rounded()))
}

/// Parses engine options. Defaults to the process arguments; the menu bar app
/// passes a synthetic list so both front ends share identical semantics,
/// including the profile presets.
func parseArgs(_ argv: [String] = Array(CommandLine.arguments.dropFirst())) -> Config {
    var c = Config()
    var it = argv.makeIterator()
    while let a = it.next() {
        func val() -> String { it.next() ?? "" }
        c.explicit.insert(a)
        switch a {
        case "--host":       c.host = val()
        case "--port":       c.port = UInt16(val()) ?? 21324
        case "--leds":       c.ledCount = Int(val()) ?? 30
        case "--fps":        c.fps = Int(val()) ?? 0
        case "--display":    c.displayIndex = Int(val()) ?? -1
        case "--display-id", "--window":
            guard let id = UInt32(val()), id > 0 else { fputs("source ID must be a positive integer\n", stderr); exit(64) }
            if a == "--display-id" { c.displayID = id } else { c.windowID = id }
        case "--list-sources": c.listSources = true
        case "--list-devices": c.listDevices = true
        case "--device-id", "--right-device-id":
            guard let id = UUID(uuidString: val()) else {
                fputs("invalid Bluetooth UUID\n", stderr); exit(64)
            }
            if a == "--device-id" { c.bleID = id } else { c.bleRightID = id }
            if c.bleName == nil { c.bleName = "MELK" }
        case "--layout":
            guard let layout = LightLayout(rawValue: val()) else {
                fputs("layout must be whole, perimeter, sides, four or columns\n", stderr); exit(64)
            }
            c.layout = layout
        case "--analysis-width": c.analysisWidth = Int(val()) ?? 192
        case "--edge-depth": c.edgeDepth = Double(val()) ?? 0.2
        case "--response-ms": c.responseTime = (Double(val()) ?? 120) / 1000
        case "--black-point": c.blackPoint = Double(val()) ?? 0.025
        case "--include-subtitles": c.excludeSubtitles = false
        case "--reverse-left": c.reverseLeft = true
        case "--reverse-right": c.reverseRight = true
        case "--swap-sides": c.swapSides = true
        case "--left-gain", "--right-gain":
            let values = val().split(separator: ",").compactMap { Double($0) }
            if a == "--left-gain" { c.leftGain = values } else { c.rightGain = values }
        case "--crop":
            let values = val().split(separator: ",").compactMap { Double($0) }
            guard values.count == 4 else { fputs("crop requires x,y,width,height\n", stderr); exit(64) }
            c.cropRect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        case "--region":     c.regionHeight = Double(val()) ?? 0.4
        case "--smoothing":  c.smoothing = Double(val()) ?? 0.35
        case "--saturation": c.saturation = Double(val()) ?? 1.35
        case "--gamma":      c.gamma = Double(val()) ?? 2.2
        case "--normalize":  c.normalize = Double(val()) ?? 0
        case "--vividness":  c.vividness = Double(val()) ?? 0.6
        case "--cut":        c.cutThreshold = Double(val()) ?? 0.22
        case "--profile":    c.profile = val()
        case "--selftest":   c.selfTest = true
        case "--mic":        c.micLevel = Int(val()) ?? 128
        case "--mic-off":    c.micOff = true
        case "--step":
            guard let delay = Double(val()) else { fputs("controller command delay must be a number\n", stderr); exit(64) }
            c.stepSeconds = delay

        // Controller commands. Each appends a frame, so they compose:
        //   --scene 24 --speed 200 --set-brightness 180
        case "--scene":
            c.rawFrames.append(e1(0x31, [clamp255(Int(val()) ?? 1), 0xFF]))
        case "--mode":
            c.rawFrames.append(e1(0x03, [clamp255(Int(val()) ?? 1), 0x03]))
        case "--speed":
            c.rawFrames.append(e1(0x02, [clamp255(Int(val()) ?? 128)]))
        case "--set-brightness":
            c.rawFrames.append(e1(0x01, [clamp255(Int(val()) ?? 255)]))
        case "--warm":
            // "warm,cold", each 0-255
            let parts = val().split(separator: ",").map { Int($0) ?? 0 }
            let w = clamp255(parts.first ?? 128)
            let cold = clamp255(parts.count > 1 ? parts[1] : 128)
            c.rawFrames.append(e1(0x05, [0x02, w, cold, 0x02, 0x01]))
        case "--timer":
            let secs = max(0, min(65535, Int(val()) ?? 0))
            c.rawFrames.append(e1(0x76, [UInt8(secs & 0xFF), UInt8(secs >> 8)]))
        case "--sensor":
            let on: UInt8 = val().lowercased() == "on" ? 1 : 0
            let d = max(0, min(65535, c.sensorDelay))
            c.rawFrames.append(e1(0x12, [on, UInt8(d & 0xFF), UInt8(d >> 8)]))
        case "--dry-run":    c.dryRun = true
        case "--sensor-delay":
            c.sensorDelay = Int(val()) ?? 30
        case "--catalogue":
            // "start-end": step through scene IDs so they can be identified.
            // Nothing documents what any scene actually renders.
            let r = val().split(separator: "-").map { Int($0) ?? 0 }
            let lo = max(1, r.first ?? 1), hi = min(255, r.count > 1 ? r[1] : lo)
            c.catalogue = (lo, hi)
            for id in lo...max(lo, hi) { c.rawFrames.append(e1(0x31, [UInt8(id), 0xFF])) }
        case "--audio":      c.audio = true
        case "--audio-depth": c.audioDepth = Double(val()) ?? 0.6
        case "--send":
            let hex = val().replacingOccurrences(of: " ", with: "")
            var bytes = [UInt8]()
            var i = hex.startIndex
            while i < hex.endIndex, hex.index(after: i) < hex.endIndex {
                let j = hex.index(i, offsetBy: 2)
                guard let b = UInt8(hex[i..<j], radix: 16) else { break }
                bytes.append(b); i = j
            }
            c.rawFrames.append(Data(bytes))
        case "--letterbox":  c.letterbox = true
        case "--no-letterbox": c.letterbox = false
        case "--brightness": c.brightness = Double(val()) ?? 1.0
        case "--test":       c.testMode = true
        case "--preview":    c.preview = true
        case "--ble":        c.bleName = val()
        case "--ble-rate":   c.bleRate = Double(val()) ?? 15
        case "--ble-deadband": c.bleDeadband = Int(val()) ?? 4
        case "-h", "--help":
            print("""
            ambilight — stream screen colors over Bluetooth or to WLED

              --layout <name>     whole | perimeter | sides | four | columns
              --analysis-width <n> capture width, independent of light count (192)
              --edge-depth <0.05..0.5> inward depth of edge regions (0.20)
              --response-ms <n>    smoothing time constant (120)
              --black-point <n>    black threshold (movie: 0.025)
              --include-subtitles include bottom-centre text in sampling
              --left-gain <r,g,b>  channel calibration multipliers (0...2)
              --right-gain <r,g,b> calibration for the right physical bar
              --reverse-left      reverse left bar pixel order (WLED)
              --reverse-right     reverse right bar pixel order (WLED)
              --swap-sides        swap picture sides before calibration
              --list-sources      list available displays and windows
              --display-id <n>    capture a stable display ID
              --window <n>        capture a player window ID
              --crop <x,y,w,h>    normalized crop of selected source
              --list-devices      scan Bluetooth lights for eight seconds
              --device-id <uuid>  pin a specific BLE controller
              --right-device-id <uuid> separate second BLE controller (sides only)
              --host <ip>          WLED IP address        (default 4.3.2.1)
              --port <n>           UDP port               (default 21324)
              --leds <n>           number of LEDs         (default 30)
              --fps <n>            target frame rate      (default 30)
              --display <n>        display index          (default 0)
              --region <0..1>      top fraction, columns layout only (default 0.4)
              --smoothing <0..1>   higher = snappier      (default 0.35)
              --saturation <f>     color boost            (default 1.35)
              --gamma <f>          gamma correction       (default 2.2)
              --normalize <0..1>   lift dim screens to a usable brightness,
                                   keeping hue      (default 0, BLE mode 0.7)
              --vividness <0..1>   weight saturated pixels over grey ones
              --cut <0..1>         scene-cut sensitivity; lower = snappier
              --brightness <0..1>  master brightness      (default 1.0)
              --profile <name>     feel preset: calm | balanced | punchy | movie
              --letterbox          ignore black bars, sample only the picture
              --no-letterbox       disable the above
              --test               static layout colours, no screen capture
              --preview            draw the computed LED colors in the terminal
              --audio              pulse intensity with system audio
              --audio-depth <0..1> how strongly        (default 0.15)

            BLE mode (existing LotusLampX / MELK controller, no extra hardware):
              --ble <name>         connect to this BLE device (substring match)
              --ble-rate <n>       max writes per second   (default 15)
              --ble-deadband <n>   ignore smaller changes  (default 4)
            Note: this protocol sets ONE solid color for the whole strip.

            On-device sound-reactive mode (per-pixel, full speed, no BLE traffic):
              --mic <0-255>        enable it at this sensitivity, then exit
              --mic-off            disable it, then exit
              --send <hex>         write a raw frame (repeatable), then exit
              --step <secs>        delay between those frames

            Controller commands (one-shot, compose freely, then exit):
              --scene <1-255>      run an on-device scene (per-pixel, full speed)
              --mode <1-4>         Jump | Strobe | Breathe | Warning
              --speed <0-255>      animation speed
              --set-brightness <n> lamp brightness 0-255
              --warm <w,c>         warm/cold white mix
              --timer <secs>       auto-off timer (0 cancels)
              --sensor <on|off>    motion sensor, with --sensor-delay <secs>
              --catalogue <a-b>    step through scenes a..b to identify them
              --dry-run            print the frames instead of sending them
            """)
            exit(0)
        default:
            FileHandle.standardError.write("unknown option: \(a)\n".data(using: .utf8)!)
            exit(64)
        }
    }

    // Single-color BLE mode wants different defaults from a per-zone strip:
    // the whole screen (not just the top band) is the better source for one
    // averaged color, averaging washes color out so saturation goes up, and
    // at ~15 writes/sec a fast EMA reads as flicker rather than response.
    if c.bleName != nil {
        if !c.explicit.contains("--region")     { c.regionHeight = 1.0 }
        if !c.explicit.contains("--saturation") { c.saturation = 1.7 }
        if !c.explicit.contains("--smoothing")  { c.smoothing = 0.18 }
        if !c.explicit.contains("--normalize")  { c.normalize = 0.7 }
    }

    // Feel presets. Applied after the BLE defaults so they override them,
    // but never over a flag the user passed by hand.
    if let name = c.profile {
        //  smoothing, saturation, normalize, brightness, rate, deadband,
        //  vividness, cutThreshold
        let p: (Double, Double, Double, Double, Double, Int, Double, Double)
        switch name.lowercased() {
        case "calm":
            p = (0.08, 1.40, 0.55, 0.75, 10, 6, 0.40, 0.50)
        case "balanced":
            p = (0.18, 1.70, 0.70, 1.00, 15, 4, 0.60, 0.25)
        case "punchy":
            p = (0.45, 2.20, 0.85, 1.00, 20, 2, 0.80, 0.15)
        case "movie":
            // Lower normalize than punchy on purpose: films use darkness
            // deliberately, and lifting every night scene to full brightness
            // fights the thing you are watching.
            p = (0.20, 1.30, 0.18, 0.35, 15, 2, 0.45, 0.18)
            if !c.explicit.contains("--gamma") { c.gamma = 1.6 }
            if !c.explicit.contains("--black-point") { c.blackPoint = 0.025 }
            if !c.explicit.contains("--no-letterbox") { c.letterbox = true }
        default:
            FileHandle.standardError.write(
                "unknown profile \"\(name)\" (calm | balanced | punchy | movie)\n".data(using: .utf8)!)
            exit(64)
        }
        if !c.explicit.contains("--smoothing")    { c.smoothing = p.0 }
        if !c.explicit.contains("--saturation")   { c.saturation = p.1 }
        if !c.explicit.contains("--normalize")    { c.normalize = p.2 }
        if !c.explicit.contains("--brightness")   { c.brightness = p.3 }
        if !c.explicit.contains("--ble-rate")     { c.bleRate = p.4 }
        if !c.explicit.contains("--ble-deadband") { c.bleDeadband = p.5 }
        if !c.explicit.contains("--vividness")    { c.vividness = p.6 }
        if !c.explicit.contains("--cut")          { c.cutThreshold = p.7 }
        if !c.explicit.contains("--response-ms") && !c.explicit.contains("--smoothing") {
            switch name.lowercased() {
            case "calm": c.responseTime = 0.5
            case "punchy": c.responseTime = 0.04
            default: c.responseTime = 0.12
            }
        }
    }
    if c.bleRightID != nil && !c.explicit.contains("--layout") { c.layout = .sides }
    return c
}

// MARK: - Main

final class NullSink: ColorSink { func send(_ colors: [UInt8]) {} }

/// Follows the machine to sleep and back. Registered once the sink exists.
final class SleepWatcher {
    private let sink: ColorSink
    init(sink: ColorSink) {
        self.sink = sink
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(willSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(willSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
    }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func willSleep() { sink.suspend() }
    @objc private func didWake()   { sink.resume() }
}

/// Paints a synthetic BGRA frame with black bars and checks that the shipped
/// detector finds the picture area.
func checkBars(_ cfg: Config, _ label: String, w: Int, h: Int,
               top: Int, bot: Int, left: Int, right: Int) -> Bool {
    let stride = w * 4
    var buf = [UInt8](repeating: 0, count: stride * h)
    for y in top...bot {
        for x in left...right {
            let o = y * stride + x * 4
            buf[o] = 200; buf[o + 1] = 40; buf[o + 2] = 30   // BGRA
        }
    }
    let fh = FrameHandler(cfg: cfg, sink: NullSink())
    let got = buf.withUnsafeBufferPointer { fh.detectBars($0.baseAddress!, w, h, stride) }
    let want = (top, bot, left, right)
    let ok = got == want
    print("  \(ok ? "PASS" : "FAIL")  \(label): got \(got) want \(want)")
    return ok
}

/// A moving hue ramp. `spread` of 1 lays a full rainbow along the strip; 0
/// makes every LED the same hue, which is what you want for a single-color
/// BLE controller (averaging a rainbow just gives you grey).
func hueRamp(count: Int, phase: Double, spread: Double) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: count * 3)
    for i in 0..<count {
        let hue = (Double(i) / Double(count) * spread + phase)
            .truncatingRemainder(dividingBy: 1.0)
        let hp = hue * 6
        let x = 1.0 * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var r = 0.0, g = 0.0, b = 0.0
        switch Int(hp) {
        case 0: (r, g, b) = (1, x, 0)
        case 1: (r, g, b) = (x, 1, 0)
        case 2: (r, g, b) = (0, 1, x)
        case 3: (r, g, b) = (0, x, 1)
        case 4: (r, g, b) = (x, 0, 1)
        default: (r, g, b) = (1, 0, x)
        }
        buf[i * 3]     = UInt8(r * 255)
        buf[i * 3 + 1] = UInt8(g * 255)
        buf[i * 3 + 2] = UInt8(b * 255)
    }
    return buf
}

// MARK: - Runner

/// Owns a capture session and the sink it feeds.
///
/// Both front ends drive this. The menu bar app runs it **in-process** rather
/// than spawning the CLI, because macOS attributes a screen-capture request to
/// the binary that makes it: a bare helper executable inside an app bundle has
/// no grantable TCC identity of its own, so a spawned child is refused no
/// matter what the user toggles for the app.
final class Runner: NSObject, SCStreamDelegate {
    private(set) var sink: ColorSink?
    private var stream: SCStream?
    private var handler: FrameHandler?
    private var watcher: SleepWatcher?
    private var oneShot: BLESender?
    private var startTask: Task<Void, Never>?
    private var generation = 0
    private var streamingConfig: Config?

    var onStarted: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onOutputStatus: ((OutputStatus) -> Void)?
    var onPreview: ((FramePreview) -> Void)?
    var onDeviceIdentified: ((UUID) -> Void)?
    var isRunning: Bool { stream != nil }

    private func statusCallback(_ token: Int) -> (OutputStatus) -> Void {
        { [weak self] status in
            guard let self, self.generation == token else { return }
            self.onOutputStatus?(status)
        }
    }

    func start(_ proposed: Config) {
        stop()
        let cfg: Config
        do { cfg = try validatedConfig(proposed) }
        catch { onError?(error.localizedDescription); return }
        let token = generation
        if !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
            onError?("Allow Ambilight in Privacy & Security → Screen & System Audio Recording, then relaunch.")
            return
        }
        onOutputStatus?(OutputStatus(state: "Starting capture"))
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !Task.isCancelled, self.generation == token else { return }
                let filter: SCContentFilter
                let width: Double, height: Double
                let sourceName: String
                if let id = cfg.windowID {
                    guard let window = content.windows.first(where: { $0.windowID == id }) else {
                        throw ConfigurationError("The selected player window is unavailable. Choose it again in Settings.")
                    }
                    filter = SCContentFilter(desktopIndependentWindow: window)
                    width = max(1, window.frame.width); height = max(1, window.frame.height)
                    sourceName = window.title ?? window.owningApplication?.applicationName ?? "Window \(id)"
                } else {
                    let display: SCDisplay
                    if let id = cfg.displayID {
                        guard let found = content.displays.first(where: { $0.displayID == id }) else {
                            throw ConfigurationError("The selected display is disconnected. Choose another display in Settings.")
                        }
                        display = found
                    } else {
                        guard cfg.displayIndex < content.displays.count else { throw ConfigurationError("Display \(cfg.displayIndex) is unavailable") }
                        display = content.displays[cfg.displayIndex]
                    }
                    filter = SCContentFilter(display: display, excludingWindows: [])
                    width = Double(display.width); height = Double(display.height)
                    sourceName = "Display \(display.displayID)"
                }
                let s = try makeColorSink(cfg, onStatus: self.statusCallback(token), onIdentified: { [weak self] id in
                    guard let self, self.generation == token else { return }; self.onDeviceIdentified?(id)
                })
                guard !Task.isCancelled, self.generation == token else { s.stop(); return }
                self.sink = s
                self.streamingConfig = cfg
                self.watcher = SleepWatcher(sink: s)
                let h = FrameHandler(cfg: cfg, sink: s)
                h.onPreview = { [weak self] preview in
                    guard let self, self.generation == token else { return }; self.onPreview?(preview)
                }
                self.handler = h
                h.start()
                let sc = SCStreamConfiguration()
                sc.width = h.captureWidth
                h.captureHeight = max(8, Int((Double(h.captureWidth) * height / width).rounded()))
                sc.height = h.captureHeight
                sc.pixelFormat = kCVPixelFormatType_32BGRA
                // Explicit SDR/sRGB analysis. HDR matching still requires visual calibration.
                sc.colorSpaceName = CGColorSpace.sRGB
                sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cfg.fps))
                sc.queueDepth = 2; sc.showsCursor = false; sc.scalesToFit = true
                if cfg.audio { sc.capturesAudio = true; sc.sampleRate = 48000; sc.channelCount = 2 }
                let st = SCStream(filter: filter, configuration: sc, delegate: self)
                try st.addStreamOutput(h, type: .screen, sampleHandlerQueue: h.sampleQueue)
                if cfg.audio { try st.addStreamOutput(h, type: .audio, sampleHandlerQueue: h.sampleQueue) }
                try await st.startCapture()
                guard !Task.isCancelled, self.generation == token else { h.stop(); try? await st.stopCapture(); return }
                self.stream = st
                self.onStarted?("source    \(sourceName)\nlayout    \(cfg.layout.title)\ncapture   \(h.captureWidth)x\(h.captureHeight) @ \(cfg.fps)fps\nfeel      \(cfg.profile ?? "custom")")
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                let message = error.localizedDescription
                self.shutdown { [weak self] in
                    guard let self, self.generation == token + 1 else { return }
                    self.onError?(message)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            let token = self.generation
            self.shutdown { [weak self] in
                guard let self, self.generation == token + 1 else { return }
                self.onError?("Capture stopped: " + error.localizedDescription)
            }
        }
    }

    private func endCapture() {
        generation += 1
        startTask?.cancel(); startTask = nil
        handler?.stop()
        if let st = stream { Task { try? await st.stopCapture() } }
        stream = nil; handler = nil; watcher = nil; streamingConfig = nil
    }
    func stop() {
        endCapture()
        sink?.stop(); sink = nil
        oneShot?.stop(); oneShot = nil
    }
    /// Uses the existing connection to go dark and allows BLE callbacks to drain.
    func shutdown(completion: @escaping () -> Void) {
        endCapture()
        oneShot?.stop(); oneShot = nil
        guard let output = sink else { completion(); return }
        sink = nil
        output.shutdown(completion: completion)
    }

    /// Reading/off modes use the selected backend, calibration and master brightness.
    func setStatic(_ proposed: Config, color: [UInt8], off: Bool = false) {
        stop()
        do {
            let cfg = try validatedConfig(proposed), token = generation
            let s = try makeColorSink(cfg, onStatus: statusCallback(token), onIdentified: onDeviceIdentified)
            sink = s
            let count = cfg.layout.zoneCount(ledCount: cfg.ledCount)
            var raw = [Double]()
            let rgb = color.count == 3 ? color : [0, 0, 0]
            for _ in 0..<count { raw += rgb.map { off ? 0 : Double($0) / 255 } }
            var staticCfg = cfg; staticCfg.normalize = 0; staticCfg.saturation = 1; staticCfg.blackPoint = 0
            var pipeline = ColorPipeline(cfg: staticCfg)
            let zones = pipeline.process(raw, snap: true)
            let physical = expandLightZones(zones, cfg: cfg)
            onPreview?(FramePreview(colors: previewZones(zones, cfg: cfg), labels: cfg.layout.labels,
                                    captureFPS: 0, processingMS: 0,
                                    pictureRect: CGRect(x: 0, y: 0, width: 1, height: 1)))
            if off { s.suspend() } else { s.send(physical) }
        } catch { onError?(error.localizedDescription) }
    }

    /// CLI-only known one-shot controller frames, with bounded connection timeout.
    func send(device: String, deviceID: UUID? = nil, frames: [Data], step: TimeInterval = 0.15, completion: (() -> Void)? = nil) {
        stop()
        let token = generation
        let b = BLESender(nameFilter: device, rate: 10, deadband: 0, oneShot: frames, deviceID: deviceID, onStatus: statusCallback(token))
        b.stepDelay = step
        b.onOneShotComplete = { [weak self, weak b] in
            guard let self, self.generation == token else { return }
            b?.stop(); self.oneShot = nil; completion?()
        }
        oneShot = b
        // Allow initial pacing and the final controller drain as well as all writes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15 + Double(frames.count + 1) * max(0.15, step)) { [weak self, weak b] in
            guard let self, self.generation == token, self.oneShot === b else { return }
            b?.stop(); self.oneShot = nil; self.onError?("Controller command timed out. Disconnect LotusLamp X and check Bluetooth.")
        }
    }
}
