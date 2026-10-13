// CLI front end. The engine itself lives in Engine.swift, which the menu bar
// app links directly rather than spawning this binary.

import Foundation
import AppKit
import ScreenCaptureKit

let cfg: Config
do {
    cfg = try validatedConfig(parseArgs())
} catch {
    FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
    exit(64)
}

// CoreBluetooth and capture callbacks need the main queue to stay free while
// the final dark frame drains. A POSIX signal handler must not call those APIs.
var shutdownAction: (() -> Void)?
var isStopping = false
func handleTermination() {
    guard !isStopping else { return }
    isStopping = true
    print("\nstopping")
    if let shutdown = shutdownAction { shutdown() } else { exit(0) }
}
let terminationSignals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler(handler: handleTermination)
    source.resume()
    return source
}

// MARK: - source discovery (no lighting output)

if cfg.listSources {
    Task { @MainActor in
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            print("Displays (--display uses the index):")
            for (index, display) in content.displays.enumerated() {
                print("  \(index): id=\(display.displayID), \(display.width)x\(display.height)")
            }
            print("Windows (--window uses the window ID):")
            for window in content.windows.sorted(by: { $0.windowID < $1.windowID }) {
                guard window.frame.width > 1, window.frame.height > 1 else { continue }
                print("  \(window.windowID): \(window.owningApplication?.applicationName ?? "Application") — \(window.title ?? "Untitled")")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write("Cannot list capture sources: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    RunLoop.main.run()
}

if cfg.listDevices {
    let discovery = BLEDiscovery()
    var printed = Set<UUID>()
    discovery.onDevices = { devices in
        for device in devices where printed.insert(device.id).inserted {
            print("\(device.id.uuidString)  \(device.name)  \(device.rssi) dBm")
        }
    }
    shutdownAction = { discovery.stop(); exit(0) }
    print("Scanning for nearby light controllers for 8 seconds; no commands are sent.")
    discovery.start()
    Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
        discovery.stop()
        if printed.isEmpty { print("No matching light controllers found.") }
        exit(0)
    }
    RunLoop.main.run()
}

// MARK: - self test

if cfg.selfTest {
    print("letterbox detection:")
    var ok = true
    ok = checkBars(cfg, "letterbox 2.35:1", w: 120, h: 68,
                   top: 12, bot: 55, left: 0, right: 119) && ok
    ok = checkBars(cfg, "pillarbox 4:3", w: 120, h: 68,
                   top: 0, bot: 67, left: 15, right: 104) && ok
    ok = checkBars(cfg, "windowed", w: 120, h: 68,
                   top: 8, bot: 59, left: 10, right: 109) && ok
    ok = checkBars(cfg, "fullscreen", w: 120, h: 68,
                   top: 0, bot: 67, left: 0, right: 119) && ok

    // An almost-black frame must not be read as a bar layout.
    let stride = 120 * 4
    var dark = [UInt8](repeating: 0, count: stride * 68)
    let o = 34 * stride + 60 * 4
    dark[o] = 200; dark[o + 1] = 200; dark[o + 2] = 200
    let fh = FrameHandler(cfg: cfg, sink: NullSink())
    let got = dark.withUnsafeBufferPointer { fh.detectBars($0.baseAddress!, 120, 68, stride) }
    let tiny = (got.1 - got.0) <= 68 / 5 || (got.3 - got.2) <= 120 / 5
    print("  \(tiny ? "PASS" : "FAIL")  dark scene rejected: got \(got) -> implausible=\(tiny)")
    ok = ok && tiny

    // Vividness: a mostly-grey frame with a small saturated patch should read
    // as that colour, not as grey. 90 grey pixels + 10 pure red.
    var px = [UInt8]()
    for _ in 0..<90 { px += [128, 128, 128, 255] }          // BGRA grey
    for _ in 0..<10 { px += [0, 0, 255, 255] }              // BGRA red
    let flat = weightedMean(px, vividness: 0)
    let vivid = weightedMean(px, vividness: 0.75)
    let flatOK = abs(flat.0 - 141) <= 1 && abs(flat.1 - 115) <= 1
    let vividOK = vivid.0 > 200 && vivid.1 < 60
    print("  \(flatOK ? "PASS" : "FAIL")  flat mean: \(flat) (expect ~141,115,115)")
    print("  \(vividOK ? "PASS" : "FAIL")  weighted:  \(vivid) (expect strongly red)")
    ok = ok && flatOK && vividOK

    ok = runImmersionTests() && ok

    print(ok ? "all passed" : "FAILURES")
    exit(ok ? 0 : 1)
}

// MARK: - one-shot controller commands

if cfg.micLevel != nil || cfg.micOff || !cfg.rawFrames.isEmpty {
    guard let device = cfg.bleName ?? (cfg.dryRun ? "dry" : nil) else {
        FileHandle.standardError.write("needs --ble <name>\n".data(using: .utf8)!)
        exit(64)
    }
    var frames = cfg.rawFrames
    if let lv = cfg.micLevel {
        let level = UInt8(max(0, min(255, lv)))
        frames.append(Data([0x7E, 0x07, 0x07, 0x01, 0xFF, 0xFF, 0xFF, 0x00, 0xEF]))
        frames.append(Data([0x7E, 0x07, 0x06, level, 0xFF, 0xFF, 0xFF, 0x00, 0xEF]))
        print("enabling sound-reactive mode, sensitivity \(level)")
    } else if cfg.micOff {
        frames.append(Data([0x7E, 0x07, 0x07, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xEF]))
        print("disabling sound-reactive mode")
    }

    if cfg.dryRun {
        for f in frames {
            print(f.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        exit(0)
    }

    let runner = Runner()
    shutdownAction = { runner.shutdown { exit(0) } }
    runner.onError = { message in
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
        runner.shutdown { exit(1) }
    }
    runner.send(device: device, deviceID: cfg.bleID, frames: frames,
                step: cfg.stepSeconds ?? (cfg.rawFrames.isEmpty ? 0.15 : 1.5)) {
        print("done")
        exit(0)
    }
    RunLoop.main.run()
}

// MARK: - link test (no screen capture)

if cfg.testMode {
    let sink: ColorSink
    do {
        sink = try makeColorSink(cfg)
    } catch {
        FileHandle.standardError.write("Cannot create output: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    let dest = cfg.bleName.map { "ble:\($0)" } ?? "\(cfg.host):\(cfg.port)"
    print("static layout test -> \(dest), \(cfg.layout.title). ctrl-c to turn off and stop.")
    let colors: [UInt8]
    switch cfg.layout {
    case .whole, .perimeter: colors = [64, 16, 0]
    case .sides: colors = [64, 0, 0, 0, 0, 64]
    case .four: colors = [64, 0, 0, 0, 64, 0, 0, 0, 64, 64, 64, 0]
    case .columns: colors = hueRamp(count: cfg.ledCount, phase: 0, spread: 1).map { $0 / 4 }
    }
    let frame = expandLightZones(colors, cfg: cfg)
    sink.send(frame)
    // The sink holds static output itself; this also exercises WLED's heartbeat.
    shutdownAction = { sink.shutdown { exit(0) } }
    RunLoop.main.run()
    exit(0)
}

// MARK: - normal operation

let runner = Runner()
shutdownAction = { runner.shutdown { exit(0) } }
runner.onStarted = { info in
    print("ambilight running")
    print(info)
    print("ctrl-c to stop.")
}
runner.onError = { msg in
    print("capture failed: \(msg)")
    print("If this is a permission error, grant Screen Recording in")
    print("System Settings > Privacy & Security > Screen Recording.")
    runner.shutdown { exit(1) }
}
runner.start(cfg)

RunLoop.main.run()
