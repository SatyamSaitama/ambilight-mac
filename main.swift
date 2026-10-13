// CLI front end. The engine itself lives in Engine.swift, which the menu bar
// app links directly rather than spawning this binary.

import Foundation
import AppKit
import ScreenCaptureKit

let cfg = parseArgs()

signal(SIGINT) { _ in
    print("\nstopping")
    exit(0)
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
    runner.send(device: device, frames: frames,
                step: cfg.stepSeconds ?? (cfg.rawFrames.isEmpty ? 0.15 : 1.5)) {
        print("done")
        exit(0)
    }
    RunLoop.main.run()
}

// MARK: - link test (no screen capture)

if cfg.testMode {
    let sink: ColorSink
    if let bleName = cfg.bleName {
        sink = BLESender(nameFilter: bleName, rate: cfg.bleRate, deadband: cfg.bleDeadband)
    } else {
        guard let w = WLEDSender(host: cfg.host, port: cfg.port, ledCount: cfg.ledCount) else {
            exit(1)
        }
        sink = w
    }
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

// MARK: - normal operation

let runner = Runner()
runner.onStarted = { info in
    print("ambilight running")
    print(info)
    print("ctrl-c to stop.")
}
runner.onError = { msg in
    print("capture failed: \(msg)")
    print("If this is a permission error, grant Screen Recording in")
    print("System Settings > Privacy & Security > Screen Recording.")
    exit(1)
}
runner.start(cfg)

RunLoop.main.run()
