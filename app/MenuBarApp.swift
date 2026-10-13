import AppKit
import ScreenCaptureKit

enum Mode: String, CaseIterable, Codable {
    case movie, ambient, reading, sound, off
    var title: String {
        switch self {
        case .movie: return "Movie"
        case .ambient: return "Ambient"
        case .reading: return "Reading"
        case .sound: return "Sound + Movie"
        case .off: return "Off"
        }
    }
    var detail: String {
        switch self {
        case .movie: return "Follow the picture with gentle transitions"
        case .ambient: return "Slow, muted colour for working"
        case .reading: return "Steady warm white"
        case .sound: return "Picture colour with subtle system audio"
        case .off: return "Turn the lights off"
        }
    }
    var icon: String {
        switch self {
        case .movie: return "film"
        case .ambient: return "sun.min"
        case .reading: return "book"
        case .sound: return "waveform"
        case .off: return "power"
        }
    }
    var isStreaming: Bool { self == .movie || self == .ambient || self == .sound }
}

private enum LightOutput: String, CaseIterable, Codable {
    case shared, dual, wled
    var title: String {
        switch self {
        case .shared: return "Shared BLE controller · Xergy / LotusLamp X"
        case .dual: return "Two independent BLE controllers"
        case .wled: return "WLED over Wi-Fi"
        }
    }
}

/// The UI owns a versioned, persistent recipe; Config stays the engine contract.
private struct AppSettings: Codable {
    var mode: Mode = .movie
    var output: LightOutput = .shared
    var deviceName = "MELK"
    var leftID = ""
    var rightID = ""
    var host = "4.3.2.1"
    var ledCount = 30
    // Whole picture: a flash in mid-frame -- a sword strike -- must register,
    // and edge sampling can miss it.
    var layout = "whole"
    var displayIndex = 0
    var displayID: UInt32?
    var windowID: UInt32?
    var useCrop = false
    var crop = [0.0, 0.0, 1.0, 1.0]
    var brightness = 1.0
    var saturation = 1.5
    var darkLift = 0.20
    var response = 0.25
    /// How long brightness takes to fall after a flash. Optional so settings
    /// saved by v1.1 still decode.
    var afterglow: Double? = 0.8
    /// Master brightness applied by the lamp instead of in software.
    var lampDimming: Bool? = true
    /// Favour the scene's dominant hue family over a muddy average.
    var dominantColour: Bool? = true
    /// Calm in quiet scenes, quick in action. Flashes stay instant either way.
    var sceneAware: Bool? = true
    var gamma = 1.6
    var audioDepth = 0.15
    var edgeDepth = 0.20
    // Optional so settings saved by an earlier v1 preview remain readable.
    var bleRate: Double? = 15
    var excludeSubtitles = true
    var letterbox = true
    var leftGain = [1.0, 1.0, 1.0]
    var rightGain = [1.0, 1.0, 1.0]
    var reverseLeft = false
    var reverseRight = false
    var swapSides = false

    static let key = "cinemaSettings.v1"
    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Self.self, from: data) {
            if saved.crop.count == 4, saved.leftGain.count == 3, saved.rightGain.count == 3,
               (try? validatedConfig(saved.configuration())) != nil { return saved }
        }
        var result = AppSettings()
        result.deviceName = defaults.string(forKey: "device") ?? "MELK"
        result.displayIndex = defaults.object(forKey: "display") as? Int ?? 0
        result.mode = defaults.string(forKey: "mode").flatMap(Mode.init(rawValue:)) ?? .movie
        return result
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
        UserDefaults.standard.set(mode.rawValue, forKey: "mode")
    }
    func configuration() -> Config {
        var c = parseArgs(["--profile", mode == .ambient ? "calm" : "movie"])
        c.bleName = output == .wled ? nil : deviceName
        c.bleID = output == .wled ? nil : UUID(uuidString: leftID)
        c.bleRightID = output == .dual ? UUID(uuidString: rightID) : nil
        c.host = host; c.ledCount = ledCount
        c.displayIndex = displayIndex; c.displayID = displayID; c.windowID = windowID
        c.cropRect = useCrop ? CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3]) : nil
        c.layout = LightLayout(rawValue: layout) ?? .perimeter
        c.brightness = brightness; c.saturation = saturation; c.normalize = darkLift
        c.responseTime = mode == .ambient ? max(0.5, response) : response
        // Brightness rises fast enough that a flash on screen lights the room
        // at once, and falls over the afterglow. Ambient stays gentle both ways.
        c.attackTime = mode == .ambient ? max(0.5, response) : min(response, 0.05)
        c.releaseTime = mode == .ambient ? max(1.5, afterglow ?? 0.8) : (afterglow ?? 0.8)
        c.hardwareBrightness = lampDimming ?? true
        c.dominantColour = dominantColour ?? true
        c.sceneAware = sceneAware ?? true
        c.gamma = gamma; c.audioDepth = audioDepth; c.audio = mode == .sound
        c.edgeDepth = edgeDepth; c.excludeSubtitles = excludeSubtitles; c.letterbox = letterbox
        c.bleRate = bleRate ?? 15
        c.leftGain = leftGain; c.rightGain = rightGain
        c.reverseLeft = reverseLeft; c.reverseRight = reverseRight; c.swapSides = swapSides
        return c
    }
}

private struct SourceChoice {
    let title: String
    let displayID: UInt32?
    let windowID: UInt32?
}

/// Drawn locally: preview never retains or exposes a captured screen image.
private final class ZonePreview: NSView {
    var colors: [UInt8] = [] { didSet { needsDisplay = true } }
    var labels: [String] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let count = max(1, min(labels.count, 8))
        let gap: CGFloat = 10
        let width = (bounds.width - CGFloat(count - 1) * gap) / CGFloat(count)
        for i in 0..<count {
            let x = CGFloat(i) * (width + gap)
            let rect = NSRect(x: x, y: 0, width: width, height: 51)
            let offset = i * 3
            let hasColor = colors.count >= offset + 3
            let color = hasColor ? NSColor(srgbRed: CGFloat(colors[offset]) / 255,
                                           green: CGFloat(colors[offset + 1]) / 255,
                                           blue: CGFloat(colors[offset + 2]) / 255, alpha: 1) : NSColor.controlBackgroundColor
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9).stroke()
            let label = labels.indices.contains(i) ? labels[i] : "Waiting for a picture"
            (label as NSString).draw(in: NSRect(x: x, y: 59, width: width, height: 17),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor])
            let rgb = hasColor ? String(format: "#%02X%02X%02X", colors[offset], colors[offset + 1], colors[offset + 2]) : "—"
            (rgb as NSString).draw(in: NSRect(x: x, y: 77, width: width, height: 16),
                                   withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let runner = Runner()
    private let discovery = BLEDiscovery()
    private var settings = AppSettings.load()
    private let previewOnly = CommandLine.arguments.contains("--ui-preview")
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var shuttingDown = false
    private var lastError: String?
    private var connectionText = "Idle"
    private var discovered: [DiscoveredLight] = []
    private var sourceChoices: [SourceChoice] = []
    private var scanGeneration = 0
    private var launchGeneration = 0

    private var modePicker = NSPopUpButton()
    private var outputPicker = NSPopUpButton()
    private var layoutPicker = NSPopUpButton()
    private let ratePicker = NSPopUpButton()
    private var sourcePicker = NSPopUpButton()
    private var leftPicker = NSPopUpButton()
    private var rightPicker = NSPopUpButton()
    private var nameField = NSTextField()
    private var leftIDField = NSTextField()
    private var rightIDField = NSTextField()
    private var hostField = NSTextField()
    private var countField = NSTextField()
    private var cropToggle = NSButton(checkboxWithTitle: "Use a custom picture crop", target: nil, action: nil)
    private var cropFields: [NSTextField] = []
    private var subtitleToggle = NSButton(checkboxWithTitle: "Reduce subtitle influence near the bottom", target: nil, action: nil)
    private var letterboxToggle = NSButton(checkboxWithTitle: "Detect letterbox and pillarbox borders", target: nil, action: nil)
    private var lampDimmingToggle = NSButton(checkboxWithTitle: "Let the lamp do the dimming (finer steps in dark scenes)", target: nil, action: nil)
    private var dominantToggle = NSButton(checkboxWithTitle: "Pick the dominant colour (keeps sunsets warm, avoids muddy mixes)", target: nil, action: nil)
    private var sceneAwareToggle = NSButton(checkboxWithTitle: "Adapt to the scene (calm in quiet moments, quick in action)", target: nil, action: nil)
    private var reverseLeftToggle = NSButton(checkboxWithTitle: "Reverse left bar", target: nil, action: nil)
    private var reverseRightToggle = NSButton(checkboxWithTitle: "Reverse right bar", target: nil, action: nil)
    private var swapToggle = NSButton(checkboxWithTitle: "Swap left and right outputs", target: nil, action: nil)
    private var gainFields: [[NSTextField]] = []
    private var sliders: [String: NSSlider] = [:]
    private var sliderLabels: [String: NSTextField] = [:]
    private let statusLabel = NSTextField(wrappingLabelWithString: "Idle")
    private let metricsLabel = NSTextField(labelWithString: "No capture running")
    private let sourceNote = NSTextField(wrappingLabelWithString: "Refresh sources to list available displays and windows. macOS may request Screen Recording access.")
    private let hardwareNote = NSTextField(wrappingLabelWithString: "")
    private let resultLabel = NSTextField(wrappingLabelWithString: "Changes take effect when you choose Apply.")
    private let scanNote = NSTextField(wrappingLabelWithString: "Select a discovered light or enter its UUID. Close LotusLamp X before connecting.")
    private let preview = ZonePreview()

    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Ambilight.log")
    private static let logHandle: FileHandle? = {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        let file = try? FileHandle(forWritingTo: url)
        _ = try? file?.seekToEnd()
        return file
    }()
    private func log(_ message: String) {
        AppDelegate.logHandle?.write("[\(Date().formatted())] \(message)\n".data(using: .utf8)!)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Standard shortcuts also work while the settings window has focus.
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Ambilight")
        let preferences = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self; applicationMenu.addItem(preferences)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ambilight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared; applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu; mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem(); editItem.title = "Edit"
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu; mainMenu.addItem(editItem)
        NSApplication.shared.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        runner.onStarted = { [weak self] message in
            self?.log("Started: \(message)"); self?.lastError = nil; self?.buildMenu()
        }
        runner.onError = { [weak self] message in
            self?.log("Error: \(message)"); self?.lastError = message
            self?.statusLabel.stringValue = message; self?.statusLabel.textColor = .systemOrange
            self?.buildMenu()
        }
        runner.onOutputStatus = { [weak self] status in
            guard let self else { return }
            self.connectionText = status.state
            self.statusLabel.stringValue = "\(status.state) · \(status.detail) · \(String(format: "%.1f", status.writesPerSecond)) writes/s"
            self.statusLabel.textColor = status.connected ? .systemGreen : .secondaryLabelColor
            self.buildMenu()
        }
        runner.onPreview = { [weak self] frame in
            guard let self else { return }
            self.preview.colors = frame.colors; self.preview.labels = frame.labels
            self.metricsLabel.stringValue = self.settings.mode.isStreaming ? String(format: "%.1f capture fps · %.2f ms processing · picture %.0f%% × %.0f%%", frame.captureFPS, frame.processingMS, frame.pictureRect.width * 100, frame.pictureRect.height * 100) : "Static output · no capture"
        }
        runner.onDeviceIdentified = { [weak self] id in
            guard let self, self.settings.output == .shared, self.settings.leftID.isEmpty, !self.previewOnly else { return }
            self.settings.leftID = id.uuidString; self.settings.save()
            if self.leftIDField.stringValue.isEmpty { self.leftIDField.stringValue = id.uuidString }
        }
        discovery.onDevices = { [weak self] lights in
            DispatchQueue.main.async { self?.discovered = lights; self?.updateDiscoveredPickers() }
        }
        buildMenu()
        if previewOnly {
            connectionText = "UI preview · hardware inactive"
            showSettings()
            statusLabel.stringValue = "UI preview · screen capture and light output are inactive"
            preview.labels = ["Left", "Right"]
            preview.colors = [31, 117, 180, 205, 89, 45]
            metricsLabel.stringValue = "Illustrative swatches · no live capture"
            buildMenu()
        } else {
            activate(settings.mode, persist: false)
            if CommandLine.arguments.contains("--settings") { showSettings() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shuttingDown { return .terminateLater }
        shuttingDown = true; launchGeneration += 1; discovery.stop()
        if previewOnly { return .terminateNow }
        runner.shutdown { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }

    private func buildMenu() {
        statusItem.button?.image = NSImage(systemSymbolName: settings.mode.icon, accessibilityDescription: "Ambilight")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu()
        let title = NSMenuItem(title: previewOnly ? "Ambilight · UI preview" : "Ambilight", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        for (index, mode) in Mode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(pickMode(_:)), keyEquivalent: mode == .off ? "0" : "\(index + 1)")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self; item.representedObject = mode.rawValue
            item.state = settings.mode == mode ? .on : .off
            item.image = NSImage(systemSymbolName: mode.icon, accessibilityDescription: nil)
            item.toolTip = mode.detail; menu.addItem(item)
        }
        menu.addItem(.separator())
        let state = NSMenuItem(title: String((lastError ?? connectionText).prefix(95)), action: nil, keyEquivalent: "")
        state.isEnabled = false; menu.addItem(state)
        for (title, selector, key) in [("Settings…", #selector(showSettings), ","), ("Reconnect", #selector(restart), "r"), ("Open Log", #selector(openLog), "l")] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Ambilight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = Mode(rawValue: raw) else { return }
        activate(mode); modePicker.selectItem(at: Mode.allCases.firstIndex(of: mode) ?? 0)
    }
    @objc private func restart() { activate(settings.mode, persist: false) }
    @objc private func openLog() { NSWorkspace.shared.open(AppDelegate.logURL) }

    private func activate(_ mode: Mode, persist: Bool = true) {
        settings.mode = mode; lastError = nil
        if persist { settings.save() }
        buildMenu()
        guard !previewOnly else { return }
        launchGeneration += 1
        let generation = launchGeneration
        let config = settings.configuration()
        discovery.stop(); runner.stop()
        connectionText = "Preparing \(mode.title.lowercased())"
        statusLabel.stringValue = connectionText; statusLabel.textColor = .secondaryLabelColor
        metricsLabel.stringValue = mode.isStreaming ? "Waiting for capture" : "Static output · no capture"
        preview.colors = []; preview.labels = []
        // Release a previous controller connection before the next session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.launchGeneration == generation, !self.shuttingDown else { return }
            if mode.isStreaming { self.runner.start(config) }
            else { self.runner.setStatic(config, color: mode == .off ? [0, 0, 0] : [255, 169, 87], off: mode == .off) }
            self.buildMenu()
        }
    }

    // MARK: Native settings window

    @objc private func showSettings() {
        if settingsWindow == nil { makeSettingsWindow() }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makeSettingsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 770),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = previewOnly ? "Ambilight Settings · UI Preview" : "Ambilight Settings"
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        settingsWindow = window
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(root)
        guard let content = window.contentView else { return }
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                                     root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                                     root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                                     root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)])
        let heading = NSTextField(labelWithString: "Bring the picture into the room")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        root.addArrangedSubview(heading)
        let intro = note("Choose your screen and lights, then tune the colour around your picture.")
        root.addArrangedSubview(intro)
        modePicker.addItems(withTitles: Mode.allCases.map(\.title))
        modePicker.selectItem(at: Mode.allCases.firstIndex(of: settings.mode) ?? 0)
        root.addArrangedSubview(row("Mode", modePicker))
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium); statusLabel.stringValue = connectionText
        root.addArrangedSubview(statusLabel)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 96).isActive = true
        root.addArrangedSubview(preview)
        metricsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metricsLabel.textColor = .secondaryLabelColor; root.addArrangedSubview(metricsLabel)

        let tabs = NSTabView(); tabs.translatesAutoresizingMaskIntoConstraints = false
        for (title, pane) in [("Picture source", sourcePane()), ("Lights", lightsPane()), ("Movie tuning", tuningPane()), ("Calibration", calibrationPane())] {
            let item = NSTabViewItem(identifier: title); item.label = title; item.view = pane; tabs.addTabViewItem(item)
        }
        root.addArrangedSubview(tabs)
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 344).isActive = true
        resultLabel.font = .systemFont(ofSize: 11); resultLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(resultLabel)
        let reset = NSButton(title: "Reset movie tuning", target: self, action: #selector(resetTuning))
        let apply = NSButton(title: previewOnly ? "Save preview settings" : "Apply", target: self, action: #selector(applySettings))
        apply.bezelStyle = .rounded; apply.keyEquivalent = "\r"
        let footer = NSStackView(views: [reset, NSView(), apply]); footer.orientation = .horizontal
        root.addArrangedSubview(footer)
        for child in root.arrangedSubviews { child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        updateOutputControls(); updateCropControls()
    }

    private func pane(_ views: [NSView]) -> NSView {
        let container = NSView()
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
                                     stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
                                     stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
                                     stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -18)])
        for child in views { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return container
    }
    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 125).isActive = true
        let stack = NSStackView(views: [label, control]); stack.orientation = .horizontal; stack.spacing = 12; stack.alignment = .centerY
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }
    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor
        return field
    }
    private func textField(_ text: String, placeholder: String = "") -> NSTextField {
        let field = NSTextField(string: text); field.placeholderString = placeholder; field.font = .systemFont(ofSize: 12)
        return field
    }
    private func sourcePane() -> NSView {
        sourcePicker.target = self; sourcePicker.action = #selector(sourceChanged)
        populateSavedSource()
        let refresh = NSButton(title: "Refresh sources", target: self, action: #selector(refreshSources))
        let controls = NSStackView(views: [sourcePicker, refresh]); controls.orientation = .horizontal; controls.spacing = 8
        sourcePicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sourceNote.font = .systemFont(ofSize: 11); sourceNote.textColor = .secondaryLabelColor
        cropToggle.state = settings.useCrop ? .on : .off; cropToggle.target = self; cropToggle.action = #selector(cropChanged)
        cropFields = settings.crop.map { textField(String(format: "%.3f", $0)) }
        let cropRow = NSStackView(); cropRow.orientation = .horizontal; cropRow.spacing = 7
        for (index, title) in ["X", "Y", "Width", "Height"].enumerated() {
            cropRow.addArrangedSubview(NSTextField(labelWithString: title)); cropRow.addArrangedSubview(cropFields[index])
            cropFields[index].widthAnchor.constraint(equalToConstant: 72).isActive = true
        }
        letterboxToggle.state = settings.letterbox ? .on : .off
        subtitleToggle.state = settings.excludeSubtitles ? .on : .off
        return pane([row("Capture", controls), sourceNote, cropToggle, cropRow,
                     note("Crop uses fractions from 0 to 1, measured from the top-left of the selected source. The crop must fit inside it."),
                     letterboxToggle, subtitleToggle,
                     note("For movies, select the player window or a clean external display. Protected video may appear black to macOS screen capture.")])
    }
    private func lightsPane() -> NSView {
        outputPicker.addItems(withTitles: LightOutput.allCases.map(\.title))
        outputPicker.selectItem(at: LightOutput.allCases.firstIndex(of: settings.output) ?? 0)
        outputPicker.target = self; outputPicker.action = #selector(outputChanged)
        layoutPicker.target = self; layoutPicker.action = #selector(layoutChanged)
        ratePicker.addItems(withTitles: ["5 updates / second", "10 updates / second", "15 updates / second", "20 updates / second"])
        ratePicker.selectItem(at: [5.0, 10, 15, 20].firstIndex(of: settings.bleRate ?? 15) ?? 2)
        ratePicker.target = self; ratePicker.action = #selector(rateChanged)
        nameField = textField(settings.deviceName, placeholder: "MELK")
        leftIDField = textField(settings.leftID, placeholder: "Optional for shared BLE; required for two controllers")
        rightIDField = textField(settings.rightID, placeholder: "Second controller UUID")
        for picker in [leftPicker, rightPicker] { picker.target = self; picker.action = #selector(devicePicked(_:)) }
        updateDiscoveredPickers()
        let scan = NSButton(title: "Find lights", target: self, action: #selector(scanLights))
        let scanRow = NSStackView(views: [nameField, scan]); scanRow.orientation = .horizontal; scanRow.spacing = 8
        let leftRow = NSStackView(views: [leftPicker, leftIDField]); leftRow.orientation = .horizontal; leftRow.spacing = 8
        let rightRow = NSStackView(views: [rightPicker, rightIDField]); rightRow.orientation = .horizontal; rightRow.spacing = 8
        leftPicker.widthAnchor.constraint(equalToConstant: 155).isActive = true
        rightPicker.widthAnchor.constraint(equalToConstant: 155).isActive = true
        hostField = textField(settings.host, placeholder: "WLED IP address")
        countField = textField("\(settings.ledCount)"); countField.widthAnchor.constraint(equalToConstant: 65).isActive = true
        let wledRow = NSStackView(views: [hostField, NSTextField(labelWithString: "LEDs"), countField]); wledRow.orientation = .horizontal; wledRow.spacing = 10
        hardwareNote.font = .systemFont(ofSize: 11); hardwareNote.textColor = .secondaryLabelColor
        scanNote.font = .systemFont(ofSize: 11); scanNote.textColor = .secondaryLabelColor
        return pane([row("Output", outputPicker), row("Picture layout", layoutPicker), hardwareNote,
                     row("BLE name", scanRow), row("Shared / left", leftRow), row("Right controller", rightRow),
                     row("WLED address", wledRow), row("BLE rate ceiling", ratePicker), scanNote])
    }
    private func sliderRow(_ key: String, title: String, value: Double, range: ClosedRange<Double>) -> NSView {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(sliderMoved(_:)))
        slider.identifier = NSUserInterfaceItemIdentifier(key); slider.isContinuous = true
        let valueLabel = NSTextField(labelWithString: ""); valueLabel.alignment = .right; valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true
        sliders[key] = slider; sliderLabels[key] = valueLabel
        updateSliderLabel(key)
        let controls = NSStackView(views: [slider, valueLabel]); controls.orientation = .horizontal; controls.spacing = 12
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row(title, controls)
    }
    private func tuningPane() -> NSView {
        pane([sliderRow("brightness", title: "Brightness", value: settings.brightness, range: 0...1),
              sliderRow("saturation", title: "Saturation", value: settings.saturation, range: 0...2.5),
              sliderRow("darkLift", title: "Dark-scene lift", value: settings.darkLift, range: 0...0.6),
              sliderRow("response", title: "Response time", value: settings.response, range: 0.02...1.2),
              sliderRow("afterglow", title: "Afterglow", value: settings.afterglow ?? 0.8, range: 0.05...2),
              sliderRow("gamma", title: "Gamma", value: settings.gamma, range: 0.6...3),
              sliderRow("audioDepth", title: "Audio depth", value: settings.audioDepth, range: 0...1),
              sliderRow("edgeDepth", title: "Edge depth", value: settings.edgeDepth, range: 0.05...0.4),
              lampDimmingToggleConfigured(),
              configured(dominantToggle, on: settings.dominantColour ?? true),
              configured(sceneAwareToggle, on: settings.sceneAware ?? true),
              note("Start dim and increase to suit the room. Lower response time reacts faster. Afterglow sets how slowly the light fades after a bright moment; brightening stays instant. Audio depth applies to Sound + Movie; edge depth controls how far perimeter sampling reaches into the picture.")])
    }
    private func configured(_ toggle: NSButton, on: Bool) -> NSView {
        toggle.state = on ? .on : .off
        toggle.target = self; toggle.action = #selector(toggleChanged)
        return toggle
    }
    private func lampDimmingToggleConfigured() -> NSView {
        lampDimmingToggle.state = (settings.lampDimming ?? true) ? .on : .off
        lampDimmingToggle.target = self; lampDimmingToggle.action = #selector(toggleChanged)
        return lampDimmingToggle
    }
    private func calibrationPane() -> NSView {
        gainFields = [settings.leftGain, settings.rightGain].map { $0.map { textField(String(format: "%.2f", $0)) } }
        var views: [NSView] = [note("Tune channels on a neutral picture. Shared BLE uses the left gain for both bars. Independent outputs can be matched separately. A gain of 1 leaves a channel unchanged.")]
        for (index, title) in ["Left RGB gain", "Right RGB gain"].enumerated() {
            let gains = NSStackView(); gains.orientation = .horizontal; gains.spacing = 8
            for (channel, label) in ["R", "G", "B"].enumerated() {
                gains.addArrangedSubview(NSTextField(labelWithString: label)); gains.addArrangedSubview(gainFields[index][channel])
                gainFields[index][channel].widthAnchor.constraint(equalToConstant: 88).isActive = true
            }
            views.append(row(title, gains))
        }
        reverseLeftToggle.state = settings.reverseLeft ? .on : .off
        reverseRightToggle.state = settings.reverseRight ? .on : .off
        swapToggle.state = settings.swapSides ? .on : .off
        views += [swapToggle, reverseLeftToggle, reverseRightToggle,
                  note("Swapping changes which side receives each picture colour. Reverse controls apply to WLED bar direction. A shared BLE controller has one live colour for both bars.")]
        return pane(views)
    }

    // MARK: Source and device discovery

    private func populateSavedSource() {
        let title: String
        if let id = settings.windowID { title = "Saved window · \(id)" }
        else if let id = settings.displayID { title = "Saved display · \(id)" }
        else { title = "Display \(settings.displayIndex + 1) · refresh to identify" }
        sourceChoices = [SourceChoice(title: title, displayID: settings.displayID, windowID: settings.windowID)]
        sourcePicker.removeAllItems(); sourcePicker.addItem(withTitle: title)
    }
    @objc private func refreshSources() {
        guard !previewOnly else { sourceNote.stringValue = "Source discovery is disabled in UI preview. Open the app normally to choose a screen."; return }
        let selected = sourceChoices.indices.contains(sourcePicker.indexOfSelectedItem) ? sourceChoices[sourcePicker.indexOfSelectedItem] : nil
        sourceNote.stringValue = "Finding displays and windows…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                var choices = content.displays.enumerated().map { index, display in
                    SourceChoice(title: "Display \(index + 1) · \(display.width) × \(display.height) · ID \(display.displayID)", displayID: display.displayID, windowID: nil)
                }
                let windows = content.windows.filter { window in
                    window.frame.width > 100 && window.frame.height > 100 && window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                }.sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
                choices += windows.map { window in
                    let app = window.owningApplication?.applicationName ?? "Application"
                    let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled window"
                    return SourceChoice(title: "\(app) — \(String(title.prefix(62)))", displayID: nil, windowID: window.windowID)
                }
                var selection = choices.firstIndex { $0.displayID == selected?.displayID && $0.windowID == selected?.windowID }
                if selection == nil, let selected, selected.displayID != nil || selected.windowID != nil {
                    choices.insert(SourceChoice(title: selected.title + " · unavailable", displayID: selected.displayID, windowID: selected.windowID), at: 0)
                    selection = 0
                }
                self.sourceChoices = choices; self.sourcePicker.removeAllItems(); self.sourcePicker.addItems(withTitles: choices.map(\.title))
                if !choices.isEmpty { self.sourcePicker.selectItem(at: selection ?? min(self.settings.displayIndex, max(0, content.displays.count - 1))) }
                self.sourceNote.stringValue = "\(content.displays.count) displays and \(windows.count) windows. Choose a source, then Apply."
            } catch { self.sourceNote.stringValue = "Could not list sources: \(error.localizedDescription). Check macOS Screen Recording permission." }
        }
    }
    @objc private func sourceChanged() { markPending() }
    @objc private func scanLights() {
        guard !previewOnly else { scanNote.stringValue = "Bluetooth discovery is disabled in UI preview."; return }
        scanGeneration += 1; let generation = scanGeneration
        scanNote.stringValue = "Scanning for 12 seconds… Lights connected to LotusLamp X may not appear."
        discovery.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.scanGeneration == generation else { return }
            self.discovery.stop()
            self.scanNote.stringValue = self.discovered.isEmpty ? "No lights found. Power the controller, close LotusLamp X, then try again." : "Found \(self.discovered.count) lights. Select a controller, then Apply."
        }
    }
    private func updateDiscoveredPickers() {
        for picker in [leftPicker, rightPicker] {
            picker.removeAllItems(); picker.addItem(withTitle: "Choose discovered…")
            for light in discovered {
                picker.addItem(withTitle: "\(light.name) · \(light.rssi) dBm")
                picker.lastItem?.representedObject = light.id.uuidString
            }
        }
    }
    @objc private func devicePicked(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        (sender === leftPicker ? leftIDField : rightIDField).stringValue = id
        markPending()
    }
    @objc private func outputChanged() { updateOutputControls(); markPending() }
    @objc private func rateChanged() { markPending() }
    @objc private func layoutChanged() { updateOutputControls(preserveLayout: true); markPending() }
    private func updateOutputControls(preserveLayout: Bool = false) {
        let output = LightOutput.allCases[max(0, outputPicker.indexOfSelectedItem)]
        let previous = layoutPicker.selectedItem?.representedObject as? String ?? settings.layout
        let available: [LightLayout] = output == .shared ? [.whole, .perimeter] : output == .dual ? [.sides] : [.whole, .perimeter, .sides, .four]
        layoutPicker.removeAllItems()
        for layout in available {
            layoutPicker.addItem(withTitle: layout.title); layoutPicker.lastItem?.representedObject = layout.rawValue
        }
        var raw = previous
        if output != .shared && !preserveLayout && settings.output != output { raw = "sides" }
        let selected = available.firstIndex { $0.rawValue == raw } ?? min(1, available.count - 1)
        layoutPicker.selectItem(at: selected)
        let ble = output != .wled
        ratePicker.isEnabled = ble
        for control in [nameField, leftIDField] { control.isEnabled = ble }
        leftPicker.isEnabled = ble; rightPicker.isEnabled = output == .dual; rightIDField.isEnabled = output == .dual
        hostField.isEnabled = output == .wled; countField.isEnabled = output == .wled
        let split = output != .shared && ["sides", "four"].contains(available[selected].rawValue)
        if gainFields.count == 2 {
            gainFields[0].forEach { $0.isEnabled = true }
            gainFields[1].forEach { $0.isEnabled = output != .shared }
        }
        swapToggle.isEnabled = split
        reverseLeftToggle.isEnabled = output == .wled && split; reverseRightToggle.isEnabled = output == .wled && split
        switch output {
        case .shared: hardwareNote.stringValue = "The verified Xergy command sends one live screen colour to both bars. Independent screen sections are unverified. Start at 15 updates/s; compare 10 or 5 if the connection stutters."
        case .dual: hardwareNote.stringValue = "Two separate BLE controllers allow one colour per bar. Select a different UUID for each side; the existing paired bars alone do not create two controllers."
        case .wled: hardwareNote.stringValue = "WLED can receive independent zones: left/right or four corners. Configure the LED count and bar direction to match your wiring."
        }
    }
    @objc private func cropChanged() { updateCropControls(); markPending() }
    private func updateCropControls() { cropFields.forEach { $0.isEnabled = cropToggle.state == .on } }
    @objc private func toggleChanged() { markPending() }
    @objc private func sliderMoved(_ sender: NSSlider) {
        if let key = sender.identifier?.rawValue { updateSliderLabel(key) }; markPending()
    }
    private func updateSliderLabel(_ key: String) {
        guard let slider = sliders[key] else { return }
        switch key {
        case "response", "afterglow": sliderLabels[key]?.stringValue = String(format: "%.0f ms", slider.doubleValue * 1000)
        case "brightness", "darkLift", "audioDepth", "edgeDepth": sliderLabels[key]?.stringValue = String(format: "%.0f%%", slider.doubleValue * 100)
        default: sliderLabels[key]?.stringValue = String(format: "%.2f", slider.doubleValue)
        }
    }
    private func markPending() { resultLabel.stringValue = "Changes take effect when you choose Apply."; resultLabel.textColor = .secondaryLabelColor }
    @objc private func resetTuning() {
        let defaults = AppSettings()
        for (key, value) in [("brightness", defaults.brightness), ("saturation", defaults.saturation), ("darkLift", defaults.darkLift), ("response", defaults.response), ("afterglow", defaults.afterglow ?? 0.8), ("gamma", defaults.gamma), ("audioDepth", defaults.audioDepth), ("edgeDepth", defaults.edgeDepth)] {
            sliders[key]?.doubleValue = value; updateSliderLabel(key)
        }
        subtitleToggle.state = .on; letterboxToggle.state = .on; lampDimmingToggle.state = .on; dominantToggle.state = .on; sceneAwareToggle.state = .on; markPending()
    }

    // MARK: Validate and apply once

    @objc private func applySettings() {
        do {
            let next = try readSettings()
            _ = try validatedConfig(next.configuration())
            settings = next; settings.save()
            resultLabel.stringValue = previewOnly ? "Saved. UI preview keeps capture and hardware inactive." : "Applied. Connecting with these settings…"
            resultLabel.textColor = .systemGreen
            activate(settings.mode, persist: false)
        } catch {
            resultLabel.stringValue = error.localizedDescription; resultLabel.textColor = .systemRed
        }
    }
    private func readSettings() throws -> AppSettings {
        var next = settings
        next.mode = Mode.allCases[max(0, modePicker.indexOfSelectedItem)]
        next.output = LightOutput.allCases[max(0, outputPicker.indexOfSelectedItem)]
        next.layout = layoutPicker.selectedItem?.representedObject as? String ?? "perimeter"
        next.bleRate = [5.0, 10, 15, 20][max(0, ratePicker.indexOfSelectedItem)]
        next.deviceName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        next.leftID = leftIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        next.rightID = rightIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        func reject(_ message: String) -> NSError { NSError(domain: "AmbilightSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        if next.output != .wled {
            if next.leftID.isEmpty && next.deviceName.isEmpty { throw reject("Enter a BLE device name or choose a controller UUID.") }
            if !next.leftID.isEmpty && UUID(uuidString: next.leftID) == nil { throw reject("The shared / left controller UUID is not valid.") }
        }
        if next.output == .dual {
            guard let left = UUID(uuidString: next.leftID), let right = UUID(uuidString: next.rightID), left != right else {
                throw reject("Two-controller mode requires two different, valid controller UUIDs.")
            }
        }
        next.host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.output == .wled {
            guard !next.host.isEmpty, !next.host.contains("://"), !next.host.contains("/") else { throw reject("Enter a WLED host or IP address, without http:// or a path.") }
            guard let count = Int(countField.stringValue), (1...480).contains(count) else { throw reject("WLED LED count must be between 1 and 480.") }
            if next.layout == "four" && count < 4 { throw reject("Four-corner layout needs at least four LEDs.") }
            if next.layout == "sides" && count < 2 { throw reject("Left/right layout needs at least two LEDs.") }
            next.ledCount = count
        }
        if sourceChoices.indices.contains(sourcePicker.indexOfSelectedItem) {
            let choice = sourceChoices[sourcePicker.indexOfSelectedItem]
            next.displayID = choice.displayID; next.windowID = choice.windowID
        }
        next.useCrop = cropToggle.state == .on
        if next.useCrop {
            let values = cropFields.compactMap { Double($0.stringValue) }
            guard values.count == 4, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), values[2] > 0, values[3] > 0,
                  values[0] + values[2] <= 1.000001, values[1] + values[3] <= 1.000001 else {
                throw reject("Crop needs X/Y from 0 to 1 and positive width/height that fit inside the picture.")
            }
            next.crop = values
        }
        next.brightness = sliders["brightness"]!.doubleValue; next.saturation = sliders["saturation"]!.doubleValue
        next.darkLift = sliders["darkLift"]!.doubleValue; next.response = sliders["response"]!.doubleValue
        next.gamma = sliders["gamma"]!.doubleValue; next.audioDepth = sliders["audioDepth"]!.doubleValue
        next.edgeDepth = sliders["edgeDepth"]!.doubleValue
        next.afterglow = sliders["afterglow"]!.doubleValue
        next.lampDimming = lampDimmingToggle.state == .on
        next.dominantColour = dominantToggle.state == .on
        next.sceneAware = sceneAwareToggle.state == .on
        next.excludeSubtitles = subtitleToggle.state == .on; next.letterbox = letterboxToggle.state == .on
        for index in 0..<2 {
            let values = gainFields[index].compactMap { Double($0.stringValue) }
            guard values.count == 3, values.allSatisfy({ $0.isFinite && (0...2).contains($0) }) else { throw reject("Each RGB gain must be a number between 0 and 2.") }
            if index == 0 { next.leftGain = values } else { next.rightGain = values }
        }
        next.reverseLeft = reverseLeftToggle.state == .on; next.reverseRight = reverseRightToggle.state == .on; next.swapSides = swapToggle.state == .on
        return next
    }
}

@main enum AmbilightApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        // NSApplication.delegate is weak. Keep it alive through the run loop,
        // including optimized builds where the last local use ends early.
        withExtendedLifetime(delegate) { app.run() }
    }
}
