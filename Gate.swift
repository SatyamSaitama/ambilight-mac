import AppKit
import ScreenCaptureKit

// MARK: - Capture gate
//
// Decides when screen capture may run. Two reasons it should not always run:
//
// - Remote desktops (Citrix and similar) carry screen-capture protection. They
//   react to an *active* capture, not to the permission: while any app is
//   capturing, Citrix blanks its own session. Apps that merely hold Screen
//   Recording permission (Teams, WhatsApp, ...) do not trigger it. So the fix
//   is simply not to capture while one is visible.
// - Movie lighting is only meaningful while a film is on screen. Capturing a
//   spreadsheet all day costs CPU and keeps the recording indicator lit.
//
// The gate reads the window list only. It never captures, so it cannot trip a
// remote desktop's protection itself.

/// Which on-screen windows are allowed to make capture run.
enum GatePolicy: String {
    /// Capture unconditionally -- the original behaviour.
    case always
    /// Capture only while a video player is the top window on the movie display.
    case players
    /// Capture everything, except while a remote desktop is visible.
    case exceptRemote = "except-remote"
}

/// What the lamp shows while the gate is not capturing.
enum IdleBehaviour: String, CaseIterable {
    case warm, off, hold

    var title: String {
        switch self {
        case .warm: return "Dim warm glow"
        case .off:  return "Lamp off"
        case .hold: return "Keep the last colour"
        }
    }

    /// The resting colour, or nil to leave the lamp as it is.
    var color: [UInt8]? {
        switch self {
        case .warm: return [60, 38, 18]
        case .off:  return [0, 0, 0]
        case .hold: return nil
        }
    }
}

/// A window as the gate sees it. Lists are front-to-back.
struct GateWindow {
    var id: UInt32 = 0
    let bundleID: String
    let owner: String
    let title: String
    let bounds: CGRect
}

enum GateDecision: Equatable {
    case capture(String)    // what is being followed
    case blocked(String)    // a remote desktop is visible
    case protected(String)  // DRM video is visible
    case idle               // nothing worth following

    var summary: String {
        switch self {
        case .capture(let r):   return r == "screen" ? "Following the screen" : "Following \(r)"
        case .blocked(let r):   return "Paused · \(r) is on screen"
        case .protected(let r): return "Protected video · \(r) can't be followed"
        case .idle:             return "Waiting for a video player"
        }
    }
}

struct GateRules {
    /// Apps whose windows are always worth following.
    var players: Set<String> = [
        "com.westbridge.stremio5-mac", "com.colliderli.iina", "org.videolan.vlc",
        "com.apple.QuickTimePlayerX", "com.apple.TV", "com.firecore.infuse",
        "tv.plex.desktop", "com.plexapp.plexmediaplayer",
    ]
    /// Browsers count only when the window title names a video site.
    var browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
    ]
    /// Video sites without DRM, which capture can actually see.
    var titleKeywords: [String] = ["YouTube", "Twitch", "Vimeo", "Stremio"]

    /// DRM video. Capture cannot see it -- Safari shows it to you but black to
    /// capture -- and Chrome goes further and blacks it out *for you* while
    /// any app is capturing the screen. So capturing it is useless at best
    /// and breaks playback at worst. Measured on Crunchyroll in Safari: the
    /// picture read 0-3 out of 255 to capture throughout playback.
    var protectedKeywords: [String] = [
        "Netflix", "Prime Video", "Disney+", "Hotstar", "JioCinema",
        "SonyLIV", "ZEE5", "Crunchyroll", "Apple TV+",
    ]
    var protectedApps: Set<String> = ["com.apple.TV"]
    /// Remote-desktop clients with screen-capture protection.
    var remotePrefixes: [String] = [
        "com.citrix.", "com.microsoft.rdc.", "com.vmware.horizon",
        "com.omnissa.horizon", "com.amazon.workspaces",
    ]

    func isRemote(_ id: String) -> Bool { remotePrefixes.contains { id.hasPrefix($0) } }

    /// A label for the window if it shows DRM-protected video, else nil.
    func protectedLabel(_ w: GateWindow) -> String? {
        if protectedApps.contains(w.bundleID) { return w.owner }
        if browsers.contains(w.bundleID),
           let k = protectedKeywords.first(where: { w.title.localizedCaseInsensitiveContains($0) }) {
            return "\(k) in \(w.owner)"
        }
        return nil
    }

    /// A label for the window if it is a video player, else nil.
    func playerLabel(_ w: GateWindow) -> String? {
        if players.contains(w.bundleID) { return w.owner }
        if browsers.contains(w.bundleID),
           let k = titleKeywords.first(where: { w.title.localizedCaseInsensitiveContains($0) }) {
            return "\(k) in \(w.owner)"
        }
        return nil
    }

    /// Defaults plus any additions saved in user defaults, e.g.
    ///   defaults write local.ambilight.menubar extraPlayers -array com.example.player
    static func withUserAdditions(_ defaults: UserDefaults = .standard) -> GateRules {
        var r = GateRules()
        r.players.formUnion(defaults.stringArray(forKey: "extraPlayers") ?? [])
        r.titleKeywords += defaults.stringArray(forKey: "extraTitleKeywords") ?? []
        r.remotePrefixes += defaults.stringArray(forKey: "extraRemotePrefixes") ?? []
        r.protectedKeywords += defaults.stringArray(forKey: "extraProtectedKeywords") ?? []
        return r
    }
}

/// Pure decision, so it can be tested without a screen.
/// `windows` are on-screen normal-layer windows, front to back; `display` is
/// the bounds of the movie display in the same global coordinates. When the
/// user picked a specific player window as the source, `windowID` names it.
func gateDecision(policy: GatePolicy, rules: GateRules, windows: [GateWindow],
                  display: CGRect, windowID: UInt32? = nil) -> GateDecision {
    if policy == .always { return .capture("screen") }

    // A visible remote desktop wins over everything, whichever display it is
    // on: capture is system-wide, so it would still blank. Tiny helper windows
    // are not something a person is looking at.
    if let r = windows.first(where: {
        rules.isRemote($0.bundleID) && $0.bounds.width >= 120 && $0.bounds.height >= 80
    }) {
        return .blocked(r.owner)
    }
    // Visible DRM video also stops capture, wherever it is: Chrome blanks it
    // for the viewer while any capture runs, not only when it is the source.
    if let p = windows.first(where: {
        $0.bounds.width >= 400 && $0.bounds.height >= 300 && rules.protectedLabel($0) != nil
    }), let label = rules.protectedLabel(p) {
        return .protected(label)
    }
    if policy == .exceptRemote { return .capture("screen") }

    // A chosen player window: follow it whenever it is on screen.
    if let id = windowID {
        if let w = windows.first(where: { $0.id == id }) { return .capture(w.owner) }
        return .idle
    }

    // Otherwise follow only when the TOP sizeable window on the movie display
    // is a player. "Frontmost app" would be wrong: the film is often
    // fullscreen on the monitor while you type on the laptop. Windows under a
    // fifth of the display are ignored, so a notification or a small window
    // over a film does not stop it.
    let area = display.width * display.height
    let onDisplay = windows.filter { w in
        let i = w.bounds.intersection(display)
        return !i.isNull && i.width * i.height >= 0.2 * area
    }
    if let top = onDisplay.first, let label = rules.playerLabel(top) { return .capture(label) }
    return .idle
}

/// On-screen, normal-layer windows, front to back. Window titles need Screen
/// Recording permission; without it browsers never match but dedicated players
/// still do.
func currentWindows() -> [GateWindow] {
    guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
    var ids: [pid_t: String] = [:]
    var out: [GateWindow] = []
    for w in info {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary)
        else { continue }
        // Invisible and tiny helper windows must not block or win anything.
        if let a = w[kCGWindowAlpha as String] as? Double, a <= 0 { continue }
        if rect.width < 50 || rect.height < 50 { continue }
        let id = ids[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        ids[pid] = id
        out.append(GateWindow(id: (w[kCGWindowNumber as String] as? UInt32) ?? 0,
                              bundleID: id,
                              owner: w[kCGWindowOwnerName as String] as? String ?? "",
                              title: w[kCGWindowName as String] as? String ?? "",
                              bounds: rect))
    }
    return out
}

/// Polls the window list once a second and pauses or resumes capture to match
/// the policy, holding a resting colour in between. The lamp connection stays
/// up throughout, so resuming does not wait for Bluetooth.
final class GateController {
    private let runner: Runner
    private(set) var policy: GatePolicy = .always
    var rules = GateRules()
    var idle: IdleBehaviour = .warm
    var onChange: ((GateDecision) -> Void)?
    private(set) var current: GateDecision?

    private var timer: Timer?
    private var display: CGRect?
    private var displayID: UInt32?
    private var displayIndex = 0
    private var windowID: UInt32?
    private var candidate: GateDecision?
    private var candidateTicks = 0
    private var lastResolve = Date.distantPast

    init(runner: Runner) { self.runner = runner }

    func enable(policy: GatePolicy, displayID: UInt32?, displayIndex: Int, windowID: UInt32?) {
        disable()
        self.policy = policy
        self.displayID = displayID
        self.displayIndex = displayIndex
        self.windowID = windowID
        resolveDisplay()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func disable() {
        timer?.invalidate(); timer = nil
        current = nil; candidate = nil; candidateTicks = 0
    }

    private func resolveDisplay() {
        lastResolve = Date()
        let id = displayID, idx = displayIndex
        // A shareable-content query, not a capture.
        Task { @MainActor [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true) else { return }
            let found = id.flatMap { want in content.displays.first { $0.displayID == want } }
                ?? (idx < content.displays.count ? content.displays[idx] : nil)
            guard let d = found else { return }
            self?.display = CGDisplayBounds(d.displayID)
        }
    }

    private func tick() {
        if Date().timeIntervalSince(lastResolve) > 60 { resolveDisplay() }
        guard let display else { return }          // first resolve still pending
        let d = gateDecision(policy: policy, rules: rules, windows: currentWindows(),
                             display: display, windowID: windowID)

        // Hysteresis: a change must hold for two ticks, so flicking between
        // apps does not stop and restart capture. The first decision applies
        // at once.
        if d == candidate { candidateTicks += 1 } else { candidate = d; candidateTicks = 1 }
        if d != current && (current == nil || candidateTicks >= 2) {
            current = d
            onChange?(d)
        }

        // Re-assert the wanted state every tick: the lamp connection may still
        // be coming up, and a resting colour sent too early is dropped.
        if case .capture = current {
            runner.resumeCapture()
        } else {
            runner.pauseCapture()
            if let c = idle.color { runner.hold(c) }
        }
    }
}
