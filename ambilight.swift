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
    var fps = 60
    var displayIndex = 0

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

    /// Modulate intensity with system audio. Captured from the same
    /// ScreenCaptureKit stream as the pixels -- the digital output stream, not
    /// a microphone, so fans and room noise cannot reach it.
    var audio = false
    var audioDepth = 0.6         // 0 = colour only, 1 = fully audio-driven

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

func parseArgs() -> Config {
    var c = Config()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        func val() -> String { it.next() ?? "" }
        c.explicit.insert(a)
        switch a {
        case "--host":       c.host = val()
        case "--port":       c.port = UInt16(val()) ?? 21324
        case "--leds":       c.ledCount = Int(val()) ?? 30
        case "--fps":        c.fps = max(1, Int(val()) ?? 60)
        case "--display":    c.displayIndex = Int(val()) ?? 0
        case "--region":     c.regionHeight = Double(val()) ?? 0.4
        case "--smoothing":  c.smoothing = Double(val()) ?? 0.35
        case "--saturation": c.saturation = Double(val()) ?? 1.35
        case "--gamma":      c.gamma = Double(val()) ?? 2.2
        case "--normalize":  c.normalize = Double(val()) ?? 0
        case "--profile":    c.profile = val()
        case "--selftest":   c.selfTest = true
        case "--mic":        c.micLevel = Int(val()) ?? 128
        case "--mic-off":    c.micOff = true
        case "--step":       c.stepSeconds = Double(val())
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
            ambilight — stream screen colors to WLED

              --host <ip>          WLED IP address        (default 4.3.2.1)
              --port <n>           UDP port               (default 21324)
              --leds <n>           number of LEDs         (default 30)
              --fps <n>            target frame rate      (default 60)
              --display <n>        display index          (default 0)
              --region <0..1>      top fraction of screen (default 0.4, 1.0 = all)
              --smoothing <0..1>   higher = snappier      (default 0.35)
              --saturation <f>     color boost            (default 1.35)
              --gamma <f>          gamma correction       (default 2.2)
              --normalize <0..1>   lift dim screens to a usable brightness,
                                   keeping hue      (default 0, BLE mode 0.7)
              --brightness <0..1>  master brightness      (default 1.0)
              --profile <name>     feel preset: calm | balanced | punchy | movie
              --letterbox          ignore black bars, sample only the picture
              --no-letterbox       disable the above
              --test               cycle colors, no screen capture
              --preview            draw the computed LED colors in the terminal
              --audio              pulse intensity with system audio
              --audio-depth <0..1> how strongly        (default 0.6)

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
        let p: (Double, Double, Double, Double, Double, Int)
        switch name.lowercased() {
        case "calm":
            //  smoothing, saturation, normalize, brightness, rate, deadband
            p = (0.08, 1.40, 0.55, 0.75, 10, 6)
        case "balanced":
            p = (0.18, 1.70, 0.70, 1.00, 15, 4)
        case "punchy":
            p = (0.45, 2.20, 0.85, 1.00, 20, 2)
        case "movie":
            // Lower normalize than punchy on purpose: films use darkness
            // deliberately, and lifting every night scene to full brightness
            // fights the thing you are watching.
            p = (0.30, 1.90, 0.50, 0.90, 20, 3)
            if !c.explicit.contains("--letterbox") { c.letterbox = true }
        default:
            FileHandle.standardError.write(
                "unknown profile \"\(name)\" (calm | balanced | punchy)\n".data(using: .utf8)!)
            exit(64)
        }
        if !c.explicit.contains("--smoothing")    { c.smoothing = p.0 }
        if !c.explicit.contains("--saturation")   { c.saturation = p.1 }
        if !c.explicit.contains("--normalize")    { c.normalize = p.2 }
        if !c.explicit.contains("--brightness")   { c.brightness = p.3 }
        if !c.explicit.contains("--ble-rate")     { c.bleRate = p.4 }
        if !c.explicit.contains("--ble-deadband") { c.bleDeadband = p.5 }
    }
    return c
}

// MARK: - UDP sender

/// Anything that can accept a frame of LED colors.
protocol ColorSink: AnyObject {
    func send(_ colors: [UInt8])
    /// Go dark without tearing down the connection (system sleep).
    func suspend()
    func resume()
}

extension ColorSink {
    func suspend() {}
    func resume() {}
}

final class WLEDSender: ColorSink {
    private let fd: Int32
    private var addr: sockaddr_in
    private let ledCount: Int
    private var packet: [UInt8]

    init?(host: String, port: UInt16, ledCount: Int) {
        guard ledCount > 0, ledCount <= 490 else {
            FileHandle.standardError.write("led count must be 1...490 for DRGB\n".data(using: .utf8)!)
            return nil
        }
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }

        addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian

        // Accept either a literal IP or a hostname (e.g. "wled-a1b2c3.local"),
        // so you don't have to pin a DHCP lease just to run this.
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_DGRAM
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else {
                FileHandle.standardError.write("cannot resolve host: \(host)\n".data(using: .utf8)!)
                return nil
            }
            defer { freeaddrinfo(res) }
            guard let sa = first.pointee.ai_addr else { return nil }
            addr.sin_addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            FileHandle.standardError.write(
                "resolved \(host) -> \(String(cString: buf))\n".data(using: .utf8)!)
        }

        self.ledCount = ledCount
        // 2 header bytes + RGB triplets, reused every frame to avoid churn.
        packet = [UInt8](repeating: 0, count: 2 + ledCount * 3)
        packet[0] = 2   // DRGB
        packet[1] = 2   // revert to normal effects 2s after we stop sending
    }

    deinit { close(fd) }

    /// colors: ledCount RGB triplets, 0...255
    func send(_ colors: [UInt8]) {
        guard colors.count == ledCount * 3 else { return }
        for i in 0..<colors.count { packet[2 + i] = colors[i] }
        withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = packet.withUnsafeBytes { buf in
                    sendto(fd, buf.baseAddress, buf.count, 0,
                           sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}


// MARK: - BLE sink (LotusLampX / MELK "E1" protocol)

/// Drives a cheap BLE LED controller of the LotusLampX / MELK family.
///
/// The protocol is a fixed 9-byte frame with five payload slots and no
/// fragmentation, so it can only ever carry ONE solid color for the entire
/// strip -- there is no per-pixel command. We therefore collapse the whole
/// zone frame down to a single average color.
///
///   COLOR:  7E 07 05 03 RR GG BB 10 EF      (no checksum)
///   ON:     7E 07 04 FF 01 01 02 01 EF
final class BLESender: NSObject, ColorSink, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceUUID = CBUUID(string: "FFF0")
    private let writeUUID   = CBUUID(string: "FFF3")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?

    private let nameFilter: String
    private let minInterval: TimeInterval
    private let deadband: Int

    private let lock = NSLock()
    private var pending: (UInt8, UInt8, UInt8)?
    private var lastSent: (UInt8, UInt8, UInt8)?
    private var lastWrite = Date.distantPast
    private(set) var writes = 0
    private var suspended = false
    /// Longest the lamp may hold a stale color while the screen drifts.
    private let maxHold: TimeInterval = 1.0

    private let oneShot: [Data]
    var stepDelay: TimeInterval = 0.15

    init(nameFilter: String, rate: Double, deadband: Int, oneShot: [Data] = []) {
        self.oneShot = oneShot
        self.nameFilter = nameFilter
        self.minInterval = 1.0 / max(1.0, rate)
        self.deadband = deadband
        super.init()
        // Main queue, so RunLoop.main drives the BLE stack.
        central = CBCentralManager(delegate: self, queue: .main)

        // Report regardless of whether anything was written, so a silent link
        // is distinguishable from a quiet screen.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let c = self.lastSent
            let state = self.writeChar == nil ? "  (not connected)" : ""
            self.err(String(format: "ble: %.1f writes/s  rgb=%d,%d,%d%@\n",
                            Double(self.writes) / 5.0,
                            Int(c?.0 ?? 0), Int(c?.1 ?? 0), Int(c?.2 ?? 0), state))
            self.writes = 0
        }
    }

    private func err(_ m: String) {
        FileHandle.standardError.write(m.data(using: .utf8)!)
    }

    // MARK: ColorSink

    func send(_ colors: [UInt8]) {
        let n = colors.count / 3
        guard n > 0 else { return }
        var r = 0, g = 0, b = 0
        for i in 0..<n {
            r += Int(colors[i * 3]); g += Int(colors[i * 3 + 1]); b += Int(colors[i * 3 + 2])
        }
        let c = (UInt8(r / n), UInt8(g / n), UInt8(b / n))
        lock.lock(); pending = c; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    // MARK: writing

    private func colorFrame(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Data {
        Data([0x7E, 0x07, 0x05, 0x03, r, g, b, 0x10, 0xEF])
    }

    func suspend() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.suspended else { return }
            self.suspended = true
            guard let p = self.peripheral, let ch = self.writeChar else { return }
            // Live connection already in hand -- go dark immediately rather
            // than reconnecting while the machine is shutting down.
            p.writeValue(Data([0x7E, 0x07, 0x04, 0x00, 0x01, 0x00, 0x02, 0x01, 0xEF]),
                         for: ch, type: .withoutResponse)
            self.err("ble: suspended (lamp off)\n")
        }
    }

    func resume() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.suspended else { return }
            self.suspended = false
            self.lastSent = nil          // force the next color through
            guard let p = self.peripheral, let ch = self.writeChar else { return }
            p.writeValue(Data([0x7E, 0x07, 0x04, 0xFF, 0x01, 0x01, 0x02, 0x01, 0xEF]),
                         for: ch, type: .withoutResponse)
            self.err("ble: resumed\n")
        }
    }

    private func flush() {
        guard !suspended else { return }
        guard let p = peripheral, let ch = writeChar else { return }
        lock.lock(); let want = pending; lock.unlock()
        guard let c = want else { return }

        // Rate ceiling: these controllers have no flow control on
        // write-without-response, so overrunning them just drops frames.
        guard Date().timeIntervalSince(lastWrite) >= minInterval else { return }

        // Deadband, so a still screen stops generating radio traffic -- but
        // bounded by maxHold, otherwise a color that drifts one count at a
        // time never clears the threshold and the lamp freezes while the
        // screen changes completely.
        if let l = lastSent {
            let delta = max(abs(Int(c.0) - Int(l.0)),
                            abs(Int(c.1) - Int(l.1)),
                            abs(Int(c.2) - Int(l.2)))
            if delta == 0 { return }
            let stale = Date().timeIntervalSince(lastWrite) >= maxHold
            if delta < deadband && !stale { return }
        }

        guard p.canSendWriteWithoutResponse else { return }

        p.writeValue(colorFrame(c.0, c.1, c.2), for: ch, type: .withoutResponse)
        lastSent = c
        lastWrite = Date()
        writes += 1
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { flush() }

    // MARK: central delegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            err("ble: scanning for \"\(nameFilter)\"...\n")
            c.scanForPeripherals(withServices: nil, options: nil)
        case .unauthorized:
            err("""
            !! Bluetooth permission denied for this process.
               System Settings > Privacy & Security > Bluetooth -> enable for
               the app running this (Terminal, iTerm, or Claude Code).

            """)
            exit(2)
        case .poweredOff:
            err("!! Bluetooth is off.\n"); exit(3)
        case .unsupported:
            err("!! Bluetooth unsupported on this machine.\n"); exit(4)
        default:
            break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let advertisesService =
            (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(serviceUUID) ?? false
        let matches = nameFilter.isEmpty
            ? advertisesService
            : name.lowercased().contains(nameFilter.lowercased())
        guard matches else { return }

        err("ble: found \"\(name)\" rssi=\(RSSI) -- connecting\n")
        c.stopScan()
        peripheral = p
        p.delegate = self
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        err("ble: connected, discovering FFF0\n")
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        err("ble: connect failed (\(error?.localizedDescription ?? "unknown")), retrying\n")
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                        error: Error?) {
        err("ble: disconnected, reconnecting\n")
        writeChar = nil
        c.connect(p, options: nil)
    }

    // MARK: peripheral delegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svcs = p.services, !svcs.isEmpty else {
            err("ble: service FFF0 not found -- is this really a LotusLampX device?\n")
            return
        }
        for s in svcs where s.uuid == serviceUUID {
            p.discoverCharacteristics([writeUUID], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService,
                    error: Error?) {
        for ch in s.characteristics ?? [] where ch.uuid == writeUUID {
            guard ch.properties.contains(.writeWithoutResponse) else {
                err("ble: FFF3 lacks write-without-response\n"); continue
            }
            writeChar = ch
            err("ble: ready (FFF3)\n")
            // Make sure the lamp is actually on before we start sending colors.
            p.writeValue(Data([0x7E, 0x07, 0x04, 0xFF, 0x01, 0x01, 0x02, 0x01, 0xEF]),
                         for: ch, type: .withoutResponse)

            // One-shot command mode: space the writes out, since
            // write-without-response has no flow control, then quit.
            if !oneShot.isEmpty {
                for (i, frame) in oneShot.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + stepDelay * Double(i + 1)) {
                        self.err("ble: -> " + frame.map { String(format: "%02X", $0) }
                                                   .joined(separator: " ") + "\n")
                        p.writeValue(frame, for: ch, type: .withoutResponse)
                    }
                }
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + stepDelay * Double(oneShot.count + 2)) {
                    print("done")
                    exit(0)
                }
            }
        }
    }
}

// MARK: - Color pipeline

struct ColorPipeline {
    let cfg: Config
    private var smoothed: [Double]
    private let gammaLUT: [UInt8]

    init(cfg: Config) {
        self.cfg = cfg
        smoothed = [Double](repeating: 0, count: cfg.ledCount * 3)
        // Precompute gamma + brightness so the hot path is a table lookup.
        gammaLUT = (0...255).map { i in
            let v = pow(Double(i) / 255.0, cfg.gamma) * cfg.brightness
            return UInt8(max(0, min(255, (v * 255.0).rounded())))
        }
    }

    /// raw: ledCount linear RGB triplets in 0...1
    mutating func process(_ raw: [Double]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cfg.ledCount * 3)
        let a = cfg.smoothing

        for led in 0..<cfg.ledCount {
            let o = led * 3
            var r = raw[o], g = raw[o + 1], b = raw[o + 2]

            // Saturation boost around luma — screen averages are washed out
            // because averaging pulls everything toward grey.
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            if luma < cfg.blackPoint {
                r = 0; g = 0; b = 0
            } else {
                r = max(0, min(1, luma + (r - luma) * cfg.saturation))
                g = max(0, min(1, luma + (g - luma) * cfg.saturation))
                b = max(0, min(1, luma + (b - luma) * cfg.saturation))
            }

            // Scale the color up until its brightest channel saturates,
            // then blend back toward the original by `normalize`. Hue and
            // relative channel ratios are preserved; only level changes.
            if cfg.normalize > 0 {
                let peak = max(r, max(g, b))
                if peak > 0.02 {
                    let k = 1.0 / peak
                    r += (r * k - r) * cfg.normalize
                    g += (g * k - g) * cfg.normalize
                    b += (b * k - b) * cfg.normalize
                }
            }

            smoothed[o]     += (r - smoothed[o])     * a
            smoothed[o + 1] += (g - smoothed[o + 1]) * a
            smoothed[o + 2] += (b - smoothed[o + 2]) * a

            out[o]     = gammaLUT[Int(max(0, min(255, (smoothed[o]     * 255).rounded())))]
            out[o + 1] = gammaLUT[Int(max(0, min(255, (smoothed[o + 1] * 255).rounded())))]
            out[o + 2] = gammaLUT[Int(max(0, min(255, (smoothed[o + 2] * 255).rounded())))]
        }
        return out
    }
}

// MARK: - Capture

final class FrameHandler: NSObject, SCStreamOutput {
    private let cfg: Config
    private let sink: ColorSink
    private var pipeline: ColorPipeline
    private var frames = 0
    private var lastReport = Date()

    // Audio level, written on the audio queue and read on the video queue.
    private let audioLock = NSLock()
    private var audioLevel = 0.0
    private var audioPeak = 0.02

    /// Stable picture bounds. They expand instantly and contract slowly, so a
    /// dark scene is never mistaken for a wider black bar -- bars are
    /// permanent, dark scenes are not.
    private var sTop = 0.0, sBot = 0.0, sLeft = 0.0, sRight = 0.0
    private var boundsReady = false
    private let barLevel = 12      // channel value still counted as "black bar"
    private let contract = 0.005   // ~3s to give picture area back

    /// Horizontal samples per LED. More than 1 smooths out single-pixel noise.
    private let samplesPerLED = 4

    var captureWidth: Int { min(960, cfg.ledCount * samplesPerLED) }

    /// Set once the display is known. The capture MUST match the display's
    /// aspect ratio: ScreenCaptureKit letterboxes a mismatched frame, and those
    /// black bars land on the first and last zones, leaving both ends of the
    /// strip permanently dark.
    var captureHeight: Int = 32

    init(cfg: Config, sink: ColorSink) {
        self.cfg = cfg
        self.sink = sink
        self.pipeline = ColorPipeline(cfg: cfg)
    }


    /// True when every sampled pixel in the row is dark enough to be a bar.
    private func rowIsBar(_ b: UnsafePointer<UInt8>, _ y: Int, _ w: Int, _ st: Int) -> Bool {
        let row = b + y * st
        var x = 0
        while x < w {
            let p = row + x * 4
            if Int(p[0]) > barLevel || Int(p[1]) > barLevel || Int(p[2]) > barLevel {
                return false
            }
            x += 2
        }
        return true
    }

    private func colIsBar(_ b: UnsafePointer<UInt8>, _ x: Int, _ h: Int, _ st: Int) -> Bool {
        var y = 0
        while y < h {
            let p = b + y * st + x * 4
            if Int(p[0]) > barLevel || Int(p[1]) > barLevel || Int(p[2]) > barLevel {
                return false
            }
            y += 2
        }
        return true
    }

    /// Picture bounds for this frame, inset past any black bars.
    func detectBars(_ b: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ st: Int)
        -> (Int, Int, Int, Int) {
        var top = 0, bot = h - 1, left = 0, right = w - 1
        while top < h / 2 && rowIsBar(b, top, w, st) { top += 1 }
        while bot > h / 2 && rowIsBar(b, bot, w, st) { bot -= 1 }
        while left < w / 2 && colIsBar(b, left, h, st) { left += 1 }
        while right > w / 2 && colIsBar(b, right, h, st) { right -= 1 }
        return (top, bot, left, right)
    }


    /// RMS of a system-audio block, normalised against a slowly decaying peak
    /// so quiet passages still modulate rather than sitting at zero.
    private func handleAudio(_ sb: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sb) else { return }
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &block)
        guard status == noErr else { return }

        var sum = 0.0
        var count = 0
        for buf in UnsafeMutableAudioBufferListPointer(&abl) {
            guard let data = buf.mData else { continue }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
            let p = data.assumingMemoryBound(to: Float32.self)
            var i = 0
            while i < n {
                let v = Double(p[i])
                sum += v * v
                i += 2            // every other sample is plenty for an envelope
                count += 1
            }
        }
        guard count > 0 else { return }
        let rms = (sum / Double(count)).squareRoot()

        audioLock.lock()
        audioPeak = max(rms, audioPeak * 0.9992)          // slow decay
        let lvl = min(1.0, rms / max(audioPeak, 0.004))
        // Attack fast, release slow -- a light that drops instantly on every
        // gap between words reads as flicker.
        let a = lvl > audioLevel ? 0.5 : 0.08
        audioLevel += (lvl - audioLevel) * a
        audioLock.unlock()
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if type == .audio {
            handleAudio(sampleBuffer)
            return
        }
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(px) else { return }
        let w = CVPixelBufferGetWidth(px)
        let h = CVPixelBufferGetHeight(px)
        let stride = CVPixelBufferGetBytesPerRow(px)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        // Picture area: the whole frame, or just the part inside the bars.
        var top = 0, bot = h - 1, left = 0, right = w - 1
        if cfg.letterbox {
            let (dt, db, dl, dr) = detectBars(bytes, w, h, stride)
            // A frame that is almost entirely dark is a dark scene, not a bar
            // layout -- ignore it and keep whatever bounds we had.
            let plausible = (db - dt) > h / 5 && (dr - dl) > w / 5
            if !boundsReady {
                (sTop, sBot, sLeft, sRight) = (Double(dt), Double(db), Double(dl), Double(dr))
                boundsReady = true
            } else if plausible {
                // Grow at once, give area back slowly.
                sTop   = dt <= Int(sTop)   ? Double(dt) : sTop + (Double(dt) - sTop) * contract
                sBot   = db >= Int(sBot)   ? Double(db) : sBot + (Double(db) - sBot) * contract
                sLeft  = dl <= Int(sLeft)  ? Double(dl) : sLeft + (Double(dl) - sLeft) * contract
                sRight = dr >= Int(sRight) ? Double(dr) : sRight + (Double(dr) - sRight) * contract
            }
            top = max(0, Int(sTop)); bot = min(h - 1, Int(sBot))
            left = max(0, Int(sLeft)); right = min(w - 1, Int(sRight))
            if bot <= top { top = 0; bot = h - 1 }
            if right <= left { left = 0; right = w - 1 }
        }

        let contentH = bot - top + 1
        let contentW = right - left + 1

        // Only the top `regionHeight` slice of the picture drives the LEDs.
        let rows = max(1, Int(Double(contentH) * cfg.regionHeight))
        var raw = [Double](repeating: 0, count: cfg.ledCount * 3)

        for led in 0..<cfg.ledCount {
            let x0 = left + led * contentW / cfg.ledCount
            let x1 = max(x0 + 1, left + (led + 1) * contentW / cfg.ledCount)
            var rs = 0.0, gs = 0.0, bs = 0.0
            var n = 0

            for y in top..<min(top + rows, h) {
                let row = bytes + y * stride
                for x in x0..<min(x1, w) {
                    let p = row + x * 4          // BGRA
                    bs += Double(p[0])
                    gs += Double(p[1])
                    rs += Double(p[2])
                    n += 1
                }
            }
            guard n > 0 else { continue }
            let d = Double(n) * 255.0
            let o = led * 3
            raw[o] = rs / d; raw[o + 1] = gs / d; raw[o + 2] = bs / d
        }

        var out = pipeline.process(raw)

        if cfg.audio {
            audioLock.lock(); let lvl = audioLevel; audioLock.unlock()
            // Floor at (1 - depth) so the lamp never goes fully dark in silence.
            let k = (1 - cfg.audioDepth) + cfg.audioDepth * lvl
            for i in 0..<out.count { out[i] = UInt8(Double(out[i]) * k) }
        }

        sink.send(out)

        if cfg.preview && frames % max(1, cfg.fps / 12) == 0 {
            var bar = "\r"
            for i in 0..<cfg.ledCount {
                bar += "\u{1B}[48;2;\(out[i*3]);\(out[i*3+1]);\(out[i*3+2])m "
            }
            bar += "\u{1B}[0m"
            FileHandle.standardError.write(bar.data(using: .utf8)!)
        }

        frames += 1
        if Date().timeIntervalSince(lastReport) >= 5 {
            let fps = Double(frames) / Date().timeIntervalSince(lastReport)
            FileHandle.standardError.write(
                String(format: "%@  %.1f fps%@\n", cfg.preview ? "\n" : "", fps,
                       cfg.letterbox ? "  picture \(contentW)x\(contentH) of \(w)x\(h)" : "").data(using: .utf8)!)
            frames = 0
            lastReport = Date()
        }
    }
}

// MARK: - Main

let cfg = parseArgs()

// One-shot controller commands: connect, send, exit. No capture involved.
if cfg.micLevel != nil || cfg.micOff || !cfg.rawFrames.isEmpty {
    guard let bleName = cfg.bleName else {
        FileHandle.standardError.write("--mic needs --ble <name>\n".data(using: .utf8)!)
        exit(64)
    }
    var frames: [Data] = cfg.rawFrames
    if let lv = cfg.micLevel {
        let level = UInt8(max(0, min(255, lv)))
        frames.append(Data([0x7E, 0x07, 0x07, 0x01, 0xFF, 0xFF, 0xFF, 0x00, 0xEF]))   // mic on
        frames.append(Data([0x7E, 0x07, 0x06, level, 0xFF, 0xFF, 0xFF, 0x00, 0xEF])) // sensitivity
        print("enabling sound-reactive mode, sensitivity \(level)")
    } else if cfg.micOff {
        frames.append(Data([0x7E, 0x07, 0x07, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xEF]))   // mic off
        print("disabling sound-reactive mode")
    }
    let probe = BLESender(nameFilter: bleName, rate: 10, deadband: 0, oneShot: frames)
    if !cfg.rawFrames.isEmpty { probe.stepDelay = cfg.stepSeconds ?? 1.5 }
    RunLoop.main.run()
    exit(0)
}

let sink: ColorSink
if let bleName = cfg.bleName {
    sink = BLESender(nameFilter: bleName, rate: cfg.bleRate, deadband: cfg.bleDeadband)
} else {
    guard let w = WLEDSender(host: cfg.host, port: cfg.port, ledCount: cfg.ledCount) else {
        exit(1)
    }
    sink = w
}

signal(SIGINT) { _ in
    print("\nstopping")
    exit(0)
}

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
    @objc private func willSleep() { sink.suspend() }
    @objc private func didWake()   { sink.resume() }
}

/// Paints a synthetic BGRA frame with black bars and checks that the shipped
/// detector finds the picture area.
func checkBars(_ label: String, w: Int, h: Int,
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

if cfg.selfTest {
    print("letterbox detection:")
    var ok = true
    // 2.35:1 film inside a 16:9 frame -> horizontal bars
    ok = checkBars("letterbox 2.35:1", w: 120, h: 68, top: 12, bot: 55, left: 0, right: 119) && ok
    // 4:3 content on a 16:9 screen -> vertical bars
    ok = checkBars("pillarbox 4:3", w: 120, h: 68, top: 0, bot: 67, left: 15, right: 104) && ok
    // windowed player -> bars on all four sides
    ok = checkBars("windowed", w: 120, h: 68, top: 8, bot: 59, left: 10, right: 109) && ok
    // no bars at all
    ok = checkBars("fullscreen", w: 120, h: 68, top: 0, bot: 67, left: 0, right: 119) && ok

    // an almost-black frame must NOT be treated as a bar layout
    let stride = 120 * 4
    var dark = [UInt8](repeating: 0, count: stride * 68)
    let o = 34 * stride + 60 * 4
    dark[o] = 200; dark[o + 1] = 200; dark[o + 2] = 200      // one lit pixel
    let fh = FrameHandler(cfg: cfg, sink: NullSink())
    let got = dark.withUnsafeBufferPointer { fh.detectBars($0.baseAddress!, 120, 68, stride) }
    let tiny = (got.1 - got.0) <= 68 / 5 || (got.3 - got.2) <= 120 / 5
    print("  \(tiny ? "PASS" : "FAIL")  dark scene rejected: got \(got) -> implausible=\(tiny)")
    ok = ok && tiny

    print(ok ? "all passed" : "FAILURES")
    exit(ok ? 0 : 1)
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

if cfg.testMode {
    // Confirms the link end to end without needing Screen Recording.
    let spread = cfg.bleName == nil ? 1.0 : 0.0
    let dest = cfg.bleName.map { "ble:\($0)" } ?? "\(cfg.host):\(cfg.port)"
    print("test mode -> \(dest), \(cfg.ledCount) LEDs. ctrl-c to stop.")

    var phase = 0.0
    Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
        sink.send(hueRamp(count: cfg.ledCount, phase: phase, spread: spread))
        phase += 0.004
    }
    RunLoop.main.run()
    exit(0)
}

let sleepWatcher = SleepWatcher(sink: sink)
_ = sleepWatcher

let handler = FrameHandler(cfg: cfg, sink: sink)
var activeStream: SCStream?

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard cfg.displayIndex < content.displays.count else {
            print("display \(cfg.displayIndex) not found (\(content.displays.count) available)")
            exit(1)
        }
        let display = content.displays[cfg.displayIndex]

        let aspect = Double(display.height) / Double(display.width)
        let h = Int((Double(handler.captureWidth) * aspect).rounded())
        handler.captureHeight = max(8, (h / 2) * 2)   // keep it even

        let sc = SCStreamConfiguration()
        sc.width = handler.captureWidth
        sc.height = handler.captureHeight
        sc.pixelFormat = kCVPixelFormatType_32BGRA
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cfg.fps))
        sc.queueDepth = 3
        sc.showsCursor = false
        sc.scalesToFit = true
        if cfg.audio {
            sc.capturesAudio = true
            sc.sampleRate = 48000
            sc.channelCount = 2
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: sc, delegate: nil)
        try stream.addStreamOutput(handler, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "capture"))
        if cfg.audio {
            try stream.addStreamOutput(handler, type: .audio,
                                       sampleHandlerQueue: DispatchQueue(label: "audio"))
        }
        try await stream.startCapture()
        activeStream = stream

        print("""
        ambilight running
          display   \(cfg.displayIndex) (\(display.width)x\(display.height))
          target    \(cfg.bleName.map { "ble:" + $0 } ?? "\(cfg.host):\(cfg.port)")
          leds      \(cfg.ledCount)
          region    top \(Int(cfg.regionHeight * 100))%
          capture   \(handler.captureWidth)x\(handler.captureHeight) @ \(cfg.fps)fps
          feel      \(cfg.profile ?? "default")  smoothing=\(cfg.smoothing) sat=\(cfg.saturation) norm=\(cfg.normalize) bright=\(cfg.brightness)
        ctrl-c to stop.
        """)
    } catch {
        print("capture failed: \(error)")
        print("If this is a permission error, grant Screen Recording in")
        print("System Settings > Privacy & Security > Screen Recording.")
        exit(1)
    }
}

RunLoop.main.run()
