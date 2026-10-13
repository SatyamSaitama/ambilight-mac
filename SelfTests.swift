import Foundation

/// Synthetic picture tests exercise the same sampler and colour pipeline as
/// capture. They never request capture permission or construct a BLE sink.
func runImmersionTests() -> Bool {
    var passed = true
    func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        print("  \(condition ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : ": " + detail)")
        passed = condition && passed
    }
    func frame(width: Int = 80, height: Int = 60,
               color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let (r, g, b) = color(x, y), o = (y * width + x) * 4
            bytes[o] = b; bytes[o + 1] = g; bytes[o + 2] = r
        } }
        return bytes
    }
    func approximately(_ a: [Double], _ b: [Double], tolerance: Double = 0.02) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }
    func pixels(_ bytes: [UInt8]) -> [[UInt8]] {
        stride(from: 0, to: bytes.count - bytes.count % 3, by: 3).map {
            Array(bytes[$0..<($0 + 3)])
        }
    }

    var cfg = Config()
    cfg.bleName = nil
    cfg.ledCount = 7
    cfg.gamma = 1; cfg.brightness = 1; cfg.saturation = 1
    cfg.normalize = 0; cfg.blackPoint = 0; cfg.vividness = 0
    cfg.excludeSubtitles = false
    cfg.regionHeight = 1
    cfg.letterbox = false
    cfg.leftGain = [1, 1, 1]; cfg.rightGain = [1, 1, 1]

    print("cinematic sampling and mapping:")
    let split = frame { x, _ in x < 40 ? (255, 0, 0) : (0, 0, 255) }
    cfg.layout = .sides
    let sides = sampleLightZones(bgra: split, width: 80, height: 60, cfg: cfg)
    check("left/right edges keep independent colours",
          approximately(sides.colors, [1, 0, 0, 0, 0, 1]))

    let quadrants = frame { x, y in
        if x < 40 { return y < 30 ? (255, 0, 0) : (0, 255, 0) }
        return y < 30 ? (0, 0, 255) : (255, 255, 0)
    }
    cfg.layout = .four
    let four = sampleLightZones(bgra: quadrants, width: 80, height: 60, cfg: cfg)
    check("four regions ordered left top/bottom, right top/bottom",
          approximately(four.colors, [1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0]))
    let fourColors: [UInt8] = [80, 0, 0, 0, 80, 0, 0, 0, 80, 80, 80, 0]
    let red: [UInt8] = [80, 0, 0], green: [UInt8] = [0, 80, 0]
    let blue: [UInt8] = [0, 0, 80], yellow: [UInt8] = [80, 80, 0]
    check("odd LED count preserves all seven pixels",
          pixels(expandLightZones(fourColors, cfg: cfg)) == [red, red, green, green, blue, blue, yellow])
    cfg.reverseLeft = true; cfg.reverseRight = true
    check("bar reversal preserves each bar's colour assignment",
          pixels(expandLightZones(fourColors, cfg: cfg)) == [green, green, red, red, yellow, blue, blue])
    cfg.reverseLeft = false; cfg.reverseRight = false; cfg.swapSides = true
    check("swap routes complete side pairs before pixel expansion",
          pixels(expandLightZones(fourColors, cfg: cfg)) == [blue, blue, yellow, yellow, red, red, green])
    cfg.swapSides = false

    cfg.layout = .perimeter
    let center = frame { x, y in
        (x >= 28 && x < 52 && y >= 18 && y < 42) ? (255, 255, 255) : (0, 0, 50)
    }
    let perimeter = sampleLightZones(bgra: center, width: 80, height: 60, cfg: cfg)
    check("perimeter ignores a bright centre patch",
          approximately(perimeter.colors, [0, 0, 50.0 / 255]))

    cfg.layout = .whole
    cfg.bleName = "synthetic-test-only"
    cfg.gamma = 2
    let halfWhite = frame { x, _ in x < 40 ? (255, 255, 255) : (0, 0, 0) }
    let global = sampleLightZones(bgra: halfWhite, width: 80, height: 60, cfg: cfg)
    var globalPipeline = ColorPipeline(cfg: cfg)
    let globalOut = globalPipeline.process(global.colors, luminances: global.luminances, snap: true)
    check("shared BLE reduces picture before nonlinear correction",
          global.colors.count == 3 && globalOut.count == 3 && globalOut.allSatisfy { abs(Int($0) - 64) <= 2 },
          "RGB \(globalOut), expected about 64 rather than 128")

    cfg.gamma = 1
    cfg.excludeSubtitles = true
    let dark = frame { _, _ in (5, 8, 12) }
    let subtitles = frame { x, y in
        (x >= 24 && x < 56 && y >= 54 && y < 57) ? (255, 255, 255) : (5, 8, 12)
    }
    let withoutText = sampleLightZones(bgra: dark, width: 80, height: 60, cfg: cfg)
    let withText = sampleLightZones(bgra: subtitles, width: 80, height: 60, cfg: cfg)
    check("lower central subtitle mask preserves the dark picture colour",
          approximately(withText.colors, withoutText.colors, tolerance: 0.005))

    cfg.excludeSubtitles = false
    cfg.vividness = 1
    let tinyHighlight = frame { x, y in
        (x >= 38 && x < 42 && y >= 25 && y < 30) ? (255, 0, 0) : (0, 0, 0)
    }
    let highlighted = sampleLightZones(bgra: tinyHighlight, width: 80, height: 60, cfg: cfg)
    check("dark-scene luminance is not amplified by chroma weighting",
          highlighted.luminances.count == 1 && highlighted.luminances[0] < 0.005)
    cfg.normalize = 0.25; cfg.blackPoint = 0.015
    var highlightPipeline = ColorPipeline(cfg: cfg)
    let highlightedOut = highlightPipeline.process(highlighted.colors,
                                                  luminances: highlighted.luminances, snap: true)
    check("a tiny highlight cannot brighten the whole room",
          (highlightedOut.max() ?? 0) < 25, "RGB \(highlightedOut)")

    print("temporal response and darkness:")
    cfg.normalize = 0; cfg.blackPoint = 0; cfg.gamma = 1; cfg.vividness = 0
    cfg.responseTime = 0.15
    var at30 = ColorPipeline(cfg: cfg), at60 = ColorPipeline(cfg: cfg)
    var output30: [UInt8] = [], output60: [UInt8] = []
    for _ in 0..<15 { output30 = at30.process([0.6, 0.2, 0.1], luminances: [0.28], deltaTime: 1.0 / 30) }
    for _ in 0..<30 { output60 = at60.process([0.6, 0.2, 0.1], luminances: [0.28], deltaTime: 1.0 / 60) }
    check("equal elapsed time has equal smoothing at 30 and 60 fps",
          output30.count == output60.count && zip(output30, output60).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
          "\(output30) / \(output60)")
    var fading = ColorPipeline(cfg: cfg)
    _ = fading.process([0.8, 0.4, 0.2], luminances: [0.5], snap: true)
    var previous = 256, monotonic = true, faded: [UInt8] = []
    // Four seconds: the brightness release is a deliberate afterglow, and at
    // gamma 1 its tail reaches the last 8-bit step after about three.
    for _ in 0..<240 {
        faded = fading.process([0, 0, 0], luminances: [0], deltaTime: 1.0 / 60)
        let peak = Int(faded.max() ?? 0)
        monotonic = monotonic && peak <= previous; previous = peak
    }
    check("black frames fade monotonically to darkness", monotonic && previous <= 1)

    final class RecordingSink: ColorSink {
        private let lock = NSLock()
        private var frames = [[UInt8]]()
        func send(_ colors: [UInt8]) { lock.lock(); frames.append(colors); lock.unlock() }
        func snapshot() -> [[UInt8]] { lock.lock(); defer { lock.unlock() }; return frames }
    }
    var timed = cfg
    timed.layout = .whole; timed.bleName = "offline-test"
    timed.responseTime = 0.04; timed.cutThreshold = 1; timed.fps = 60
    // This checks the output clock, not the afterglow: keep the release fast.
    timed.attackTime = 0.04; timed.releaseTime = 0.04
    let recorder = RecordingSink()
    let handler = FrameHandler(cfg: timed, sink: recorder)
    handler.start()
    handler.submitSamples(ZoneSamples(colors: [0.8, 0.4, 0.2], luminances: [0.5],
                                      pictureRect: CGRect(x: 0, y: 0, width: 1, height: 1)))
    Thread.sleep(forTimeInterval: 0.18)
    let brightFrames = recorder.snapshot()
    check("a single static image continues settling on the output clock",
          brightFrames.count >= 3 && (brightFrames.last?.first ?? 0) > (brightFrames.first?.first ?? 255))
    handler.submitSamples(ZoneSamples(colors: [0, 0, 0], luminances: [0],
                                      pictureRect: CGRect(x: 0, y: 0, width: 1, height: 1)))
    Thread.sleep(forTimeInterval: 0.32)
    check("one black frame finishes fading without further capture frames",
          (recorder.snapshot().last?.max() ?? 255) <= 1)
    handler.stop()
    handler.sampleQueue.sync {}
    let stoppedCount = recorder.snapshot().count
    Thread.sleep(forTimeInterval: 0.05)
    check("stopping a handler cancels subsequent output ticks", recorder.snapshot().count == stoppedCount)

    print("brightness envelope:")
    var env = Config()
    env.bleName = nil; env.gamma = 1; env.brightness = 1; env.saturation = 1
    env.normalize = 0; env.blackPoint = 0; env.vividness = 0
    env.responseTime = 0.12; env.attackTime = 0.05; env.releaseTime = 0.6
    let warm = [0.8, 0.4, 0.2], dim = [0.08, 0.04, 0.02]
    func settled(_ c: Config, _ rgb: [Double], _ lum: Double) -> [UInt8] {
        var p = ColorPipeline(cfg: c); return p.process(rgb, luminances: [lum], snap: true)
    }
    check("a settled colour is unchanged by the envelope",
          settled(env, warm, 0.47) == [204, 102, 51], "\(settled(env, warm, 0.47))")

    var rise = ColorPipeline(cfg: env)
    _ = rise.process([0, 0, 0], luminances: [0], snap: true)
    var risen: [UInt8] = []
    for _ in 0..<9 { risen = rise.process(warm, luminances: [0.47], deltaTime: 1.0 / 60) }
    check("a flash reaches most of its brightness within 150 ms",
          Double(risen[0]) >= 0.85 * 204, "\(risen)")

    var glow = ColorPipeline(cfg: env)
    _ = glow.process(warm, luminances: [0.47], snap: true)
    var after: [UInt8] = []
    for _ in 0..<18 { after = glow.process(dim, luminances: [0.047], deltaTime: 1.0 / 60) }
    let dimSettled = settled(env, dim, 0.047)
    check("after a flash the light lingers as an afterglow",
          Double(after[0]) > 2.5 * Double(dimSettled[0]), "\(after) vs settled \(dimSettled)")

    var hue = ColorPipeline(cfg: env)
    _ = hue.process([0.9, 0.1, 0.1], luminances: [0.25], snap: true)
    var fadingRed: [UInt8] = []
    for _ in 0..<30 { fadingRed = hue.process([0, 0, 0], luminances: [0], deltaTime: 1.0 / 60) }
    check("the afterglow fades in the colour of the flash, not grey",
          fadingRed[0] > 0 && Int(fadingRed[0]) >= 4 * Int(max(fadingRed[1], fadingRed[2])), "\(fadingRed)")

    var cutP = ColorPipeline(cfg: env)
    _ = cutP.process([0.9, 0.2, 0.1], luminances: [0.35], snap: true)
    let dimBlue = [0.02, 0.04, 0.3]
    let afterCut = cutP.process(dimBlue, luminances: [0.05], deltaTime: 1.0 / 60, cut: true)
    let blueSettled = settled(env, dimBlue, 0.05)
    check("a cut switches colour at once but eases brightness down",
          afterCut[2] > afterCut[0] && Int(afterCut[2]) > Int(blueSettled[2]) + 10,
          "\(afterCut) vs settled \(blueSettled)")

    var lamp = env; lamp.bleName = "test"; lamp.brightness = 0.35; lamp.hardwareBrightness = true
    var software = lamp; software.hardwareBrightness = false
    let byLamp = settled(lamp, [1, 1, 1], 1), bySoftware = settled(software, [1, 1, 1], 1)
    check("lamp-side dimming sends colour at full range",
          byLamp == [255, 255, 255] && bySoftware == [89, 89, 89], "\(byLamp) / \(bySoftware)")
    var wled = lamp; wled.bleName = nil
    check("WLED is always dimmed in software", settled(wled, [1, 1, 1], 1) == [89, 89, 89])

    print("crop, calibration and picture bounds:")
    cfg.layout = .whole; cfg.bleName = nil; cfg.vividness = 0; cfg.excludeSubtitles = false
    cfg.cropRect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
    let cropped = sampleLightZones(bgra: split, width: 80, height: 60, cfg: cfg)
    check("manual crop samples only the selected source region", approximately(cropped.colors, [0, 0, 1]))
    cfg.cropRect = nil; cfg.layout = .sides; cfg.swapSides = true
    cfg.leftGain = [1, 1, 0.5]; cfg.rightGain = [0.25, 1, 1]
    let calibrated = pixels(expandLightZones([80, 0, 0, 0, 0, 80], cfg: cfg))
    check("physical channel gains follow the bar after side swapping",
          calibrated == [[0, 0, 40], [0, 0, 40], [0, 0, 40], [0, 0, 40], [20, 0, 0], [20, 0, 0], [20, 0, 0]])
    cfg.swapSides = false; cfg.leftGain = [1, 1, 1]; cfg.rightGain = [1, 1, 1]
    cfg.responseTime = 0
    var immediate = ColorPipeline(cfg: cfg)
    check("zero response time updates immediately", immediate.process([1, 0, 0], deltaTime: 0.0001) == [255, 0, 0])
    var tracker = PictureBoundsTracker()
    let letterbox = CGRect(x: 0, y: 0.15, width: 1, height: 0.7)
    for _ in 0..<60 { _ = tracker.update(detected: letterbox, frameLuma: 0.2, deltaTime: 1.0 / 60) }
    let retained = tracker.update(detected: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), frameLuma: 0.001, deltaTime: 1)
    check("dark shot retains established letterbox bounds", abs(retained.minY - 0.15) < 0.001 && abs(retained.height - 0.7) < 0.001)
    let expanded = tracker.update(detected: CGRect(x: 0, y: 0, width: 1, height: 1), frameLuma: 0.2, deltaTime: 1.0 / 60)
    check("revealed picture expands bounds immediately", expanded == CGRect(x: 0, y: 0, width: 1, height: 1))

    cfg.layout = .columns; cfg.ledCount = 100; cfg.regionHeight = 1
    let narrow = frame(width: 64, height: 16) { _, _ in (255, 255, 255) }
    let denseStrip = sampleLightZones(bgra: narrow, width: 64, height: 16, cfg: cfg)
    check("more LED columns than source pixels never create black holes",
          denseStrip.colors.count == 300 && denseStrip.colors.allSatisfy { abs($0 - 1) < 0.001 })
    let croppedStrip = sampleLightZones(bgra: narrow, width: 64, height: 16,
                                       pictureRect: CGRect(x: 0.45, y: 0, width: 0.1, height: 1), cfg: cfg)
    check("narrow cropped strips also interpolate missing columns",
          croppedStrip.colors.count == 300 && croppedStrip.colors.allSatisfy { abs($0 - 1) < 0.001 })
    check("CLI presets retain distinct response times",
          parseArgs(["--profile", "calm"]).responseTime == 0.5
            && parseArgs(["--profile", "punchy"]).responseTime == 0.04
            && parseArgs(["--profile", "calm", "--response-ms", "200"]).responseTime == 0.2)

    print("configuration bounds:")
    var valid = Config()
    valid.bleName = "synthetic-test-only"
    valid.layout = .perimeter
    check("default shared-controller cinema config is valid", (try? validatedConfig(valid)) != nil)
    valid.ledCount = 0
    check("zero LEDs rejected before capture/output", (try? validatedConfig(valid)) == nil)
    valid.ledCount = 30; valid.brightness = .nan
    check("non-finite brightness rejected", (try? validatedConfig(valid)) == nil)
    valid.brightness = 0.35; valid.responseTime = -1
    check("negative response time rejected", (try? validatedConfig(valid)) == nil)
    valid.responseTime = 0.12; valid.layout = .four
    check("shared BLE rejects unsupported four-section output", (try? validatedConfig(valid)) == nil)
    valid.layout = .sides; valid.bleID = UUID(); valid.bleRightID = valid.bleID
    check("dual BLE rejects the same controller on both sides", (try? validatedConfig(valid)) == nil)
    valid.bleRightID = UUID()
    check("two distinct BLE IDs allow side routing", (try? validatedConfig(valid)) != nil)
    valid.cropRect = CGRect(x: 0.8, y: 0, width: 0.5, height: 1)
    check("out-of-bounds crop rejected", (try? validatedConfig(valid)) == nil)
    valid.cropRect = nil; valid.leftGain = [1, .infinity, 1]
    check("invalid calibration rejected", (try? validatedConfig(valid)) == nil)
    valid.leftGain = [1, 1, 1]; valid.stepSeconds = .nan
    check("non-finite controller command delay rejected", (try? validatedConfig(valid)) == nil)
    return passed
}
