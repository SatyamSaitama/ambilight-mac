// Ambilight menu bar app.
//
// Runs the capture engine IN-PROCESS. An earlier version spawned the CLI as a
// child process, which macOS refuses to grant screen recording to: TCC
// attributes a capture request to the binary that makes it, and a bare helper
// executable inside an app bundle has no grantable identity of its own. Linking
// the engine directly means there is exactly one identity -- this app -- for
// the user to allow.

import AppKit
import ScreenCaptureKit

enum Mode: String, CaseIterable {
    case movie, ambient, reading, sound, off

    var title: String {
        switch self {
        case .movie: return "Movie";      case .ambient: return "Ambient"
        case .reading: return "Reading";  case .sound: return "Sound + Movie"
        case .off: return "Off"
        }
    }

    var detail: String {
        switch self {
        case .movie:   return "Follows the picture, ignores black bars"
        case .ambient: return "Slow and muted, for working"
        case .reading: return "Steady warm white, no screen tracking"
        case .sound:   return "Picture colour, pulsed by system audio"
        case .off:     return "Lamp off"
        }
    }

    var key: String {
        switch self {
        case .movie: return "1";   case .ambient: return "2"
        case .reading: return "3"; case .sound: return "4"; case .off: return "0"
        }
    }

    var icon: String {
        switch self {
        case .movie: return "film";    case .ambient: return "sun.min"
        case .reading: return "book";  case .sound: return "waveform"
        case .off: return "power"
        }
    }

    /// Streaming modes hold a capture session; the others are single commands.
    var isStreaming: Bool {
        switch self {
        case .movie, .ambient, .sound: return true
        case .reading, .off: return false
        }
    }

    func args(device: String, display: Int) -> [String] {
        let base = ["--ble", device, "--display", "\(display)"]
        switch self {
        case .movie:   return base + ["--profile", "movie"]
        case .ambient: return base + ["--profile", "calm"]
        case .sound:   return base + ["--profile", "movie", "--audio"]
        // ~2700K warm white, held statically. No capture, no CPU.
        case .reading: return ["--ble", device, "--send", "7E070503FFA95710EF"]
        case .off:     return ["--ble", device, "--send", "7E07040001000201EF"]
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let runner = Runner()
    private var mode: Mode = .off
    private var lastError: String?

    private let device = UserDefaults.standard.string(forKey: "device") ?? "MELK"
    private let display = UserDefaults.standard.object(forKey: "display") as? Int ?? 0

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Ambilight.log")

    private static let logHandle: FileHandle? = {
        let u = logURL
        try? FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: u.path) {
            FileManager.default.createFile(atPath: u.path, contents: nil)
        }
        let fh = try? FileHandle(forWritingTo: u)
        _ = try? fh?.seekToEnd()
        return fh
    }()

    private func log(_ s: String) {
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(s)\n"
        AppDelegate.logHandle?.write(line.data(using: .utf8)!)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("lightbulb")

        runner.onStarted = { [weak self] info in
            self?.log("started:\n\(info)")
            DispatchQueue.main.async { self?.lastError = nil; self?.buildMenu() }
        }
        runner.onError = { [weak self] msg in
            self?.log("ERROR: \(msg)")
            DispatchQueue.main.async { self?.lastError = msg; self?.buildMenu() }
        }

        buildMenu()
        let restored = UserDefaults.standard.string(forKey: "mode").flatMap(Mode.init(rawValue:))
        select(restored ?? .movie)
    }

    func applicationWillTerminate(_ n: Notification) {
        runner.stop()
        // Leave the lamp off rather than frozen on the last frame.
        let sem = DispatchSemaphore(value: 0)
        runner.send(device: device,
                    frames: [Data([0x7E, 0x07, 0x04, 0x00, 0x01, 0x00, 0x02, 0x01, 0xEF])]) {
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2.5)
    }

    private func setIcon(_ name: String) {
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Ambilight")
        statusItem.button?.image?.isTemplate = true
    }

    private func buildMenu() {
        let menu = NSMenu()
        for m in Mode.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(pick(_:)), keyEquivalent: m.key)
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
            item.representedObject = m.rawValue
            item.state = (m == mode) ? .on : .off
            item.image = NSImage(systemSymbolName: m.icon, accessibilityDescription: nil)
            let t = NSMutableAttributedString(string: m.title + "\n")
            t.append(NSAttributedString(string: m.detail,
                attributes: [.font: NSFont.systemFont(ofSize: 10),
                             .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = t
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let state = NSMenuItem(
            title: lastError.map { "Error: " + $0.prefix(60) } ?? (runner.isRunning ? "Running" : "Idle"),
            action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)

        let restart = NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)

        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "l")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Ambilight",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = Mode(rawValue: raw) else { return }
        select(m)
    }

    @objc private func restart() { select(mode) }
    @objc private func openLog() { NSWorkspace.shared.open(AppDelegate.logURL) }

    private func select(_ m: Mode) {
        mode = m
        lastError = nil
        UserDefaults.standard.set(m.rawValue, forKey: "mode")
        setIcon(m.icon)

        let argv = m.args(device: device, display: display)
        let cfg = parseArgs(argv)
        log("mode \(m.rawValue): \(argv.joined(separator: " "))")

        runner.stop()
        // The controller accepts one BLE connection, so let the old one drop
        // before opening the next.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.mode == m else { return }
            if m.isStreaming {
                self.runner.start(cfg)
            } else {
                self.runner.send(device: self.device, frames: cfg.rawFrames) {
                    self.log("\(m.rawValue) command sent")
                }
            }
            self.buildMenu()
        }
        buildMenu()
    }
}

@main
enum AmbilightApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        app.run()
    }
}
