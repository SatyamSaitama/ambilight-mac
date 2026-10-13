import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit
import AVFoundation

// MARK: - Spatial layout

enum LightLayout: String, CaseIterable {
    case whole, perimeter, sides, four, columns

    var title: String {
        switch self {
        case .whole: return "Whole picture"
        case .perimeter: return "Picture edges"
        case .sides: return "Left and right bars"
        case .four: return "Four bar segments"
        case .columns: return "Horizontal strip"
        }
    }
    var labels: [String] {
        switch self {
        case .whole: return ["Whole picture"]
        case .perimeter: return ["Picture edges"]
        case .sides: return ["Left", "Right"]
        case .four: return ["Left top", "Left bottom", "Right top", "Right bottom"]
        case .columns: return ["Columns"]
        }
    }
    func zoneCount(ledCount: Int) -> Int {
        switch self {
        case .whole, .perimeter: return 1
        case .sides: return 2
        case .four: return 4
        case .columns: return max(1, ledCount)
        }
    }
}

struct FramePreview {
    let colors: [UInt8]
    let labels: [String]
    let captureFPS: Double
    let processingMS: Double
    /// Active picture bounds within the selected capture source, normalized to 0...1.
    let pictureRect: CGRect
}

struct ZoneSamples {
    let colors: [Double]
    /// Unweighted luma preserves scene darkness even when chroma is emphasized.
    let luminances: [Double]
    let pictureRect: CGRect
    /// Coarse luma grid of the picture, for measuring how much it moves.
    /// Empty unless scene-aware response is on.
    var motion: [Double] = []
}

/// Grid used to measure scene activity: coarse enough to ignore grain and
/// compression noise, fine enough to see a fight move across the frame.
let motionColumns = 8, motionRows = 6
private let hueBins = 24

/// Hue bin of a pixel with nonzero chroma, 0..<hueBins.
@inline(__always)
private func hueBin(_ r: Double, _ g: Double, _ b: Double, max mx: Double, chroma: Double) -> Int {
    var h: Double
    if mx == r { h = (g - b) / chroma } else if mx == g { h = 2 + (b - r) / chroma } else { h = 4 + (r - g) / chroma }
    if h < 0 { h += 6 }
    return min(hueBins - 1, max(0, Int(h / 6 * Double(hueBins))))
}

private let fullPicture = CGRect(x: 0, y: 0, width: 1, height: 1)
private func unit(_ x: Double) -> Double { x.isFinite ? max(0, min(1, x)) : 0 }
private func luma(_ r: Double, _ g: Double, _ b: Double) -> Double {
    0.2126 * r + 0.7152 * g + 0.0722 * b
}
private func safePicture(_ rect: CGRect?) -> CGRect {
    guard let r = rect, !r.isNull, !r.isInfinite,
          r.origin.x.isFinite, r.origin.y.isFinite,
          r.width.isFinite, r.height.isFinite else { return fullPicture }
    let clipped = r.intersection(fullPicture)
    return clipped.isNull || clipped.width <= 0 || clipped.height <= 0 ? fullPicture : clipped
}

/// Array adapter for synthetic-image tests and offline analysis; capture uses the pointer overload.
func sampleLightZones(bgra: [UInt8], width: Int, height: Int,
                      bytesPerRow: Int? = nil, pictureRect: CGRect? = nil,
                      cfg: Config) -> ZoneSamples {
    let stride = bytesPerRow ?? max(0, width) * 4
    guard width > 0, height > 0, stride >= width * 4,
          bgra.count / stride >= height else {
        let count = cfg.layout.zoneCount(ledCount: cfg.ledCount)
        return ZoneSamples(colors: Array(repeating: 0, count: count * 3),
                           luminances: Array(repeating: 0, count: count), pictureRect: fullPicture)
    }
    return bgra.withUnsafeBufferPointer {
        sampleLightZones($0.baseAddress!, width: width, height: height,
                         bytesPerRow: stride, pictureRect: pictureRect ?? cfg.cropRect, cfg: cfg)
    }
}

private func sampleLightZones(_ bytes: UnsafePointer<UInt8>, width: Int, height: Int,
                              bytesPerRow: Int, pictureRect: CGRect?, cfg: Config) -> ZoneSamples {
    let rect = safePicture(pictureRect)
    let x0 = max(0, min(width - 1, Int((rect.minX * Double(width)).rounded())))
    let y0 = max(0, min(height - 1, Int((rect.minY * Double(height)).rounded())))
    let x1 = max(x0 + 1, min(width, Int((rect.maxX * Double(width)).rounded())))
    let y1 = max(y0 + 1, min(height, Int((rect.maxY * Double(height)).rounded())))
    let count = cfg.layout.zoneCount(ledCount: cfg.ledCount)
    var sums = [Double](repeating: 0, count: count * 3)
    var weights = [Double](repeating: 0, count: count)
    var brightness = [Double](repeating: 0, count: count)
    var pixels = [Int](repeating: 0, count: count)
    let depth = max(0.05, min(0.5, cfg.edgeDepth))

    /// Which zone a picture-relative point feeds, or nil if it is not sampled.
    func zoneAt(_ nx: Double, _ ny: Double) -> Int? {
        switch cfg.layout {
        case .whole: return 0
        case .perimeter:
            guard nx < depth || nx >= 1 - depth || ny < depth || ny >= 1 - depth else { return nil }
            return 0
        case .sides, .four:
            guard nx < depth || nx >= 1 - depth else { return nil }
            let side = nx < depth ? 0 : 1
            return cfg.layout == .four ? side * 2 + (ny < 0.5 ? 0 : 1) : side
        case .columns:
            guard ny <= max(0.01, min(1, cfg.regionHeight)) else { return nil }
            return min(count - 1, Int(nx * Double(count)))
        }
    }
    // A configurable geometric mask, not text recognition. Side edges remain sampled.
    func isSubtitleArea(_ nx: Double, _ ny: Double) -> Bool {
        cfg.excludeSubtitles && ny >= 0.80 && nx >= 0.20 && nx <= 0.80
    }
    // Below this chroma a pixel's hue is mostly noise, so it neither votes nor
    // is reweighted.
    let hueFloor = 0.08

    // Dominant colour, pass one: a hue histogram per zone, weighted by chroma
    // squared so vivid pixels vote and washed-out ones barely do.
    var popularity: [Double] = []
    if cfg.dominantColour {
        var hist = [Double](repeating: 0, count: count * hueBins)
        for y in y0..<y1 {
            let ny = (Double(y - y0) + 0.5) / Double(y1 - y0)
            for x in x0..<x1 {
                let nx = (Double(x - x0) + 0.5) / Double(x1 - x0)
                if isSubtitleArea(nx, ny) { continue }
                guard let zone = zoneAt(nx, ny) else { continue }
                let p = bytes + y * bytesPerRow + x * 4
                let r = Double(p[2]) / 255, g = Double(p[1]) / 255, b = Double(p[0]) / 255
                let mx = max(r, max(g, b)), chroma = mx - min(r, min(g, b))
                guard chroma > hueFloor else { continue }
                hist[zone * hueBins + hueBin(r, g, b, max: mx, chroma: chroma)] += chroma * chroma
            }
        }
        // Smooth around the colour wheel so a hue on a bin edge is not
        // penalized, then scale so the most popular hue family is 1.
        popularity = [Double](repeating: 1, count: count * hueBins)
        for z in 0..<count {
            var smoothed = [Double](repeating: 0, count: hueBins)
            for i in 0..<hueBins {
                let prev = hist[z * hueBins + (i + hueBins - 1) % hueBins]
                let next = hist[z * hueBins + (i + 1) % hueBins]
                smoothed[i] = 0.25 * prev + 0.5 * hist[z * hueBins + i] + 0.25 * next
            }
            let top = smoothed.max() ?? 0
            guard top > 0 else { continue }
            for i in 0..<hueBins { popularity[z * hueBins + i] = smoothed[i] / top }
        }
    }

    var motion = [Double](repeating: 0, count: cfg.sceneAware ? motionColumns * motionRows : 0)
    var motionCounts = [Int](repeating: 0, count: motion.count)

    for y in y0..<y1 {
        let ny = (Double(y - y0) + 0.5) / Double(y1 - y0)
        for x in x0..<x1 {
            let nx = (Double(x - x0) + 0.5) / Double(x1 - x0)
            if isSubtitleArea(nx, ny) { continue }
            let p = bytes + y * bytesPerRow + x * 4
            let r = Double(p[2]) / 255, g = Double(p[1]) / 255, b = Double(p[0]) / 255
            let l = luma(r, g, b)
            if !motion.isEmpty {
                let cell = min(motionRows - 1, Int(ny * Double(motionRows))) * motionColumns
                    + min(motionColumns - 1, Int(nx * Double(motionColumns)))
                motion[cell] += l; motionCounts[cell] += 1
            }
            guard let zone = zoneAt(nx, ny) else { continue }
            var weight = chromaWeight(r * 255, g * 255, b * 255, unit(cfg.vividness))
            if !popularity.isEmpty {
                // Dominant colour, pass two: hues that are common in this zone
                // keep their weight, rare ones fade. A sunset stays warm instead
                // of averaging orange sky and purple cloud into mauve. This is
                // continuous in the proportions, unlike picking the largest
                // cluster, which would flip between two near-equal hues and
                // make the lamp flicker.
                let mx = max(r, max(g, b)), chroma = mx - min(r, min(g, b))
                if chroma > hueFloor {
                    let pop = popularity[zone * hueBins + hueBin(r, g, b, max: mx, chroma: chroma)]
                    weight *= pop * pop * pop
                }
            }
            sums[zone * 3] += r * weight
            sums[zone * 3 + 1] += g * weight
            sums[zone * 3 + 2] += b * weight
            weights[zone] += weight
            brightness[zone] += l
            pixels[zone] += 1
        }
    }
    for i in motion.indices where motionCounts[i] > 0 { motion[i] /= Double(motionCounts[i]) }
    for z in 0..<count where pixels[z] > 0 {
        brightness[z] /= Double(pixels[z])
        for channel in 0..<3 { sums[z * 3 + channel] /= weights[z] }
        let weightedLuma = luma(sums[z * 3], sums[z * 3 + 1], sums[z * 3 + 2])
        // A tiny colorful highlight can choose the hue, but cannot illuminate a dark room.
        let limit = brightness[z] * 1.15
        if weightedLuma > limit && weightedLuma > 0 {
            for channel in 0..<3 { sums[z * 3 + channel] *= limit / weightedLuma }
        }
    }
    // A user can deliberately select a narrow crop or more strip LEDs than
    // analysis pixels. Interpolate missing column bins instead of inventing
    // black pixels between valid samples.
    if cfg.layout == .columns {
        let populated = (0..<count).filter { pixels[$0] > 0 }
        if !populated.isEmpty {
            var next = 0
            for z in 0..<count where pixels[z] == 0 {
                while next < populated.count - 1 && populated[next] < z { next += 1 }
                let right = populated[next]
                let left = right > z && next > 0 ? populated[next - 1] : right
                let blend = left == right ? 0 : unit(Double(z - left) / Double(right - left))
                for channel in 0..<3 {
                    sums[z * 3 + channel] = sums[left * 3 + channel] * (1 - blend)
                        + sums[right * 3 + channel] * blend
                }
                brightness[z] = brightness[left] * (1 - blend) + brightness[right] * blend
            }
        }
    }
    return ZoneSamples(colors: sums, luminances: brightness, pictureRect: rect, motion: motion)
}

private func orderedZones(_ colors: [UInt8], cfg: Config) -> [UInt8] {
    guard colors.count >= cfg.layout.zoneCount(ledCount: cfg.ledCount) * 3 else { return [] }
    var order = Array(0..<(colors.count / 3))
    if cfg.layout == .sides {
        if cfg.swapSides { order = [1, 0] }
    } else if cfg.layout == .four {
        order = cfg.swapSides ? [2, 3, 0, 1] : [0, 1, 2, 3]
        if cfg.reverseLeft { order.swapAt(0, 1) }
        if cfg.reverseRight { order.swapAt(2, 3) }
    }
    return order.flatMap { Array(colors[($0 * 3)..<($0 * 3 + 3)]) }
}

private func calibrated(_ rgb: ArraySlice<UInt8>, gain: [Double]) -> [UInt8] {
    rgb.enumerated().map { channel, byte in
        let g = gain.indices.contains(channel) && gain[channel].isFinite ? max(0, gain[channel]) : 1
        return UInt8(max(0, min(255, (Double(byte) * g).rounded())))
    }
}

func previewZones(_ colors: [UInt8], cfg: Config) -> [UInt8] {
    let ordered = orderedZones(colors, cfg: cfg)
    var result = [UInt8]()
    let n = ordered.count / 3
    for z in 0..<n {
        let right = (cfg.layout == .sides && z == 1) || (cfg.layout == .four && z >= 2)
            || (cfg.layout == .columns && z >= (n + 1) / 2)
        result += calibrated(ordered[z * 3..<z * 3 + 3], gain: right ? cfg.rightGain : cfg.leftGain)
    }
    return result
}

/// Physical layout: left bar first, then right, each top-to-bottom. Odd counts give
/// the left bar the extra LED; an odd bar gives its upper segment the extra LED.
/// BLE receives one/two logical colors; its validated transport never averages them.
func expandLightZones(_ colors: [UInt8], cfg: Config) -> [UInt8] {
    let zones = orderedZones(colors, cfg: cfg)
    guard !zones.isEmpty else { return [] }
    if cfg.bleName != nil { return previewZones(colors, cfg: cfg) }
    let n = max(1, cfg.ledCount), leftCount = (n + 1) / 2
    var result = [UInt8]()
    result.reserveCapacity(n * 3)
    for pixel in 0..<n {
        let right = pixel >= leftCount
        let count = right ? n - leftCount : leftCount
        let local = right ? pixel - leftCount : pixel
        // Reverse the physical LED order, rather than swapping equal-size halves.
        let reverse = right ? cfg.reverseRight : cfg.reverseLeft
        let position = reverse ? count - 1 - local : local
        let zone: Int
        switch cfg.layout {
        case .whole, .perimeter: zone = 0
        case .sides: zone = right ? 1 : 0
        case .four:
            // orderedZones applied reversals for previews; use the unreversed source here
            // so a 3-pixel bar reverses [top,top,bottom] to [bottom,top,top].
            let sourceSide = cfg.swapSides ? (right ? 0 : 1) : (right ? 1 : 0)
            let sourceZone = sourceSide * 2 + (position < (count + 1) / 2 ? 0 : 1)
            result += calibrated(colors[sourceZone * 3..<sourceZone * 3 + 3],
                                 gain: right ? cfg.rightGain : cfg.leftGain)
            continue
        case .columns: zone = min(pixel, zones.count / 3 - 1)
        }
        result += calibrated(zones[zone * 3..<zone * 3 + 3], gain: right ? cfg.rightGain : cfg.leftGain)
    }
    return result
}

// MARK: - Scene activity

/// How much the picture is moving, as mean luma change per second on the
/// motion grid. Drives scene-aware response: calm while a scene is still,
/// quick while it is busy.
struct SceneActivity {
    /// Luma change per second treated as fully still and fully busy. A static
    /// shot with grain sits near 0.05, dialogue around 0.1-0.2, a walking
    /// shot or pan around 0.5, a fight above 1.
    static let quietRate = 0.15, busyRate = 0.9
    private(set) var rate = 0.0
    private var previous: [Double]?

    /// Feed one motion grid. Cuts are not action: a cut changes every cell at
    /// once, so it is skipped rather than counted as a burst of motion.
    mutating func update(grid: [Double], deltaTime dt: Double, cut: Bool) {
        defer { previous = grid }
        guard let prev = previous, prev.count == grid.count, !grid.isEmpty, !cut, dt > 0 else { return }
        let change = zip(prev, grid).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(grid.count)
        let observed = change / max(1.0 / 240, dt)
        // Notice action quickly; settle back to calm slowly, so a pause inside
        // a fight does not drop straight into slow mode.
        decay(toward: observed, deltaTime: dt, rise: 0.25, fall: 1.5)
    }

    /// No new frame arrived: a still screen is calm.
    mutating func idle(deltaTime dt: Double) { decay(toward: 0, deltaTime: dt, rise: 0.25, fall: 1.5) }

    private mutating func decay(toward target: Double, deltaTime dt: Double, rise: Double, fall: Double) {
        let tau = target > rate ? rise : fall
        rate += (target - rate) * (1 - exp(-dt / tau))
    }

    /// 0 when still, 1 when busy.
    var busy: Double { unit((rate - Self.quietRate) / (Self.busyRate - Self.quietRate)) }

    /// Multipliers on the colour response and the afterglow. Quiet scenes drift
    /// gently and glow longer; busy ones track fast and let go quickly.
    /// Brightness attack is never slowed -- a flash must still land at once.
    var pace: (colour: Double, release: Double) { (1.8 - 1.3 * busy, 1.3 - 0.7 * busy) }
}

// MARK: - Time-based cinematic color processing

struct ColorPipeline {
    let cfg: Config
    /// Chroma: each zone's colour with brightness factored out, scaled so its
    /// brightest channel is 1.
    private var chroma: [Double] = []
    /// Brightness envelope per zone, in luma.
    private var level: [Double] = []
    private var dark: [Bool] = []

    init(cfg: Config) { self.cfg = cfg }

    /// Samples are normalized capture RGB, not assumed linear-light values. Gamma
    /// is a calibrated output transfer; chroma reduction happens before this stage.
    ///
    /// Colour and brightness are smoothed separately. Colour follows
    /// `responseTime` so the lamp keeps up with the picture. Brightness rises
    /// with `attackTime` and falls with `releaseTime`: a flash lights the room
    /// at once and then fades out as an afterglow, rather than blinking off as
    /// fast as it came on.
    ///
    /// - `snap`: settle everything at once (static colours).
    /// - `cut`: a scene cut. Colour snaps; brightness keeps its envelope, so a
    ///   cut to a darker shot eases down instead of blinking.
    mutating func process(_ raw: [Double], luminances: [Double]? = nil,
                          deltaTime: Double = 1.0 / 60.0, snap: Bool = false,
                          cut: Bool = false,
                          pace: (colour: Double, release: Double) = (1, 1)) -> [UInt8] {
        let n = raw.count / 3
        guard n > 0 else { return [] }
        if chroma.count != n * 3 {
            chroma = Array(repeating: 1, count: n * 3)     // neutral until a hue arrives
            level = Array(repeating: 0, count: n)
            dark = Array(repeating: false, count: n)
        }
        let dt = deltaTime.isFinite ? max(0, min(2, deltaTime)) : 1.0 / 60.0
        var tau = max(0.001, cfg.responseTime)
        // Preserve the meaning of explicit legacy smoothing at a 60 Hz reference.
        if cfg.explicit.contains("--smoothing") {
            let alpha = max(0.0001, min(0.9999, cfg.smoothing))
            tau = -(1.0 / 60.0) / log(1 - alpha)
        }
        tau *= max(0.1, pace.colour)
        let zeroResponse = cfg.responseTime == 0 && !cfg.explicit.contains("--smoothing")
        let alpha = snap || cut || zeroResponse ? 1 : 1 - exp(-dt / tau)
        func envelope(_ t: Double) -> Double { snap || t <= 0 ? 1 : 1 - exp(-dt / t) }
        // Brightness never rises slower than colour moves, so a zero response
        // time still means immediate.
        let attack = envelope(zeroResponse ? 0 : min(cfg.attackTime, tau))
        let release = envelope(cfg.releaseTime * max(0.1, pace.release))

        // With lamp-side dimming the master brightness is applied by the
        // controller, so colour goes out at full range. WLED has no such
        // setting, so it is always scaled here.
        let gain = cfg.hardwareBrightness && cfg.bleName != nil ? 1 : unit(cfg.brightness)
        let gamma = max(0.1, min(4, cfg.gamma))
        let black = unit(cfg.blackPoint)
        var output = [UInt8](repeating: 0, count: n * 3)
        for z in 0..<n {
            let o = z * 3
            var r = unit(raw[o]), g = unit(raw[o + 1]), b = unit(raw[o + 2])
            let colorLuma = luma(r, g, b)
            let sceneLuma = luminances?.indices.contains(z) == true ? unit(luminances![z]) : colorLuma
            // Separate enter/exit thresholds prevent flicker around black.
            if dark[z] {
                if sceneLuma > black * 1.15 { dark[z] = false }
            } else if sceneLuma <= black * 0.65 { dark[z] = true }
            if dark[z] {
                r = 0; g = 0; b = 0
            } else {
                let sat = max(0, min(3, cfg.saturation))
                r = unit(colorLuma + (r - colorLuma) * sat)
                g = unit(colorLuma + (g - colorLuma) * sat)
                b = unit(colorLuma + (b - colorLuma) * sat)
                // Bounded gain fades away in dark scenes. No normalization to full scale.
                let t = unit((sceneLuma - black) / max(0.01, 0.35 - black))
                let lift = 1 + unit(cfg.normalize) * 1.5 * t * t * (3 - 2 * t)
                r = unit(r * lift); g = unit(g * lift); b = unit(b * lift)
            }

            // A black target has no hue, so keep the last one: the afterglow
            // fades in the colour of the flash instead of drifting to grey.
            let peak = max(r, max(g, b))
            if peak > 0.002 {
                let target = [r / peak, g / peak, b / peak]
                // Out of near-darkness there is no visible hue to blend from,
                // so a flash lands in its own colour at once rather than
                // passing through a whitish tint.
                let a = level[z] < 0.02 ? 1 : alpha
                for c in 0..<3 { chroma[o + c] += (target[c] - chroma[o + c]) * a }
            }
            let targetLevel = luma(r, g, b)
            level[z] += (targetLevel - level[z]) * (targetLevel > level[z] ? attack : release)

            // Recombine so the colour's luma equals the envelope. At rest this
            // reproduces the target exactly; only transitions change.
            let chromaLuma = luma(chroma[o], chroma[o + 1], chroma[o + 2])
            let scale = chromaLuma > 0.0001 ? level[z] / chromaLuma : 0
            for c in 0..<3 {
                let value = pow(unit(chroma[o + c] * scale), gamma) * gain
                output[o + c] = UInt8((unit(value) * 255).rounded())
            }
            // An exponential release never quite arrives. Once a fade toward
            // black is below one 8-bit step, finish it, so the lamp is really
            // off rather than lingering at an invisible 1/255 for seconds.
            if targetLevel == 0, output[o..<o + 3].allSatisfy({ $0 <= 1 }) {
                level[z] = 0
                output[o] = 0; output[o + 1] = 0; output[o + 2] = 0
            }
        }
        return output
    }
}

// MARK: - Picture-bound stability

/// Retain useful bounds through dark fades. New crops must persist; revealing
/// more image expands immediately. Dark startup retains the full source.
struct PictureBoundsTracker {
    private(set) var rect = fullPicture
    private var candidate = fullPicture
    private var candidateSeconds = 0.0

    mutating func update(detected: CGRect, frameLuma: Double, deltaTime: Double) -> CGRect {
        let d = safePicture(detected)
        guard frameLuma > 0.025, d.width >= 0.35, d.height >= 0.35 else { return rect }
        // Automatic bars are expected to be approximately centered. An arbitrary
        // off-center player should use the source/window selector instead.
        guard abs(d.minX - (1 - d.maxX)) <= 0.05,
              abs(d.minY - (1 - d.maxY)) <= 0.05 else { return rect }
        let grown = CGRect(x: min(rect.minX, d.minX), y: min(rect.minY, d.minY),
                           width: max(rect.maxX, d.maxX) - min(rect.minX, d.minX),
                           height: max(rect.maxY, d.maxY) - min(rect.minY, d.minY))
        rect = grown
        let change = abs(d.minX - candidate.minX) + abs(d.minY - candidate.minY)
            + abs(d.maxX - candidate.maxX) + abs(d.maxY - candidate.maxY)
        if change < 0.025 {
            candidateSeconds += max(0, min(0.2, deltaTime))
        } else {
            candidate = d
            candidateSeconds = 0
        }
        if candidateSeconds >= 0.7 { rect = d }
        return rect
    }
}

// MARK: - Capture

final class FrameHandler: NSObject, SCStreamOutput {
    /// Pixel callbacks, audio callbacks, and output ticks share this queue.
    let sampleQueue = DispatchQueue(label: "ambilight.frames")
    private let cfg: Config
    private let sink: ColorSink
    private var pipeline: ColorPipeline
    private var bounds = PictureBoundsTracker()
    private var prevRaw: [Double]?
    private var lastFrameTime: Double?
    private var lastOutputTime: Double?
    private var latestSamples: ZoneSamples?
    private var pendingCut = false
    private var activity = SceneActivity()
    private var lastMotionTime: Double?
    private var samplingMS = 0.0
    private var outputTimer: DispatchSourceTimer?
    private var stopped = false
    private var lastPreviewTime = 0.0
    private var reportTime = ProcessInfo.processInfo.systemUptime
    private var reportFrames = 0
    private var measuredFPS = 0.0
    private let audioLock = NSLock()
    private var audioLevel = 0.0
    private var audioPeak = 0.02
    private var audioFails = 0
    private var lastAudioTime = 0.0
    var onPreview: ((FramePreview) -> Void)?

    var captureWidth: Int { max(64, min(960, cfg.analysisWidth)) }
    var captureHeight: Int = 108

    init(cfg: Config, sink: ColorSink) {
        self.cfg = cfg
        self.sink = sink
        self.pipeline = ColorPipeline(cfg: cfg)
    }

    deinit { outputTimer?.cancel() }

    /// Continue the response and audio envelope even when capture reports no
    /// changed pixels. Capturing a static frame is not a reason to freeze halfway
    /// through a fade or leave a previous shot's color glowing on a black screen.
    func start() {
        sampleQueue.async { [weak self] in
            guard let self, !self.stopped, self.outputTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.sampleQueue)
            let interval = 1.0 / Double(max(1, self.cfg.fps))
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.emitLatest() }
            self.outputTimer = timer
            timer.resume()
        }
    }

    func stop() {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.outputTimer?.cancel()
            self.outputTimer = nil
            self.latestSamples = nil
        }
    }

    /// Feed already-reduced samples from an offline or synthetic source. This
    /// follows the same serialized output path as a captured video frame.
    func submitSamples(_ samples: ZoneSamples) {
        sampleQueue.async { [weak self] in self?.acceptSamples(samples) }
    }

    private func acceptSamples(_ samples: ZoneSamples) {
        guard !stopped, !samples.colors.isEmpty else { return }
        if let previous = prevRaw, previous.count == samples.colors.count {
            let difference = zip(previous, samples.colors).reduce(0.0) { $0 + abs($1.0 - $1.1) }
            pendingCut = pendingCut || difference / Double(previous.count) > cfg.cutThreshold
        }
        prevRaw = samples.colors
        if cfg.sceneAware && !samples.motion.isEmpty {
            let now = ProcessInfo.processInfo.systemUptime
            activity.update(grid: samples.motion,
                            deltaTime: lastMotionTime.map { now - $0 } ?? 0, cut: pendingCut)
            lastMotionTime = now
        }
        latestSamples = samples
    }

    /// Literal candidate detector, kept separately from temporal acceptance so
    /// synthetic tests can distinguish a dark scene from genuine letterboxing.
    func detectBars(_ b: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ st: Int)
        -> (Int, Int, Int, Int) {
        guard w > 0, h > 0 else { return (0, 0, 0, 0) }
        func isBarRow(_ y: Int) -> Bool {
            var bright = 0, count = 0
            for x in stride(from: 0, to: w, by: 2) {
                // Ignore central subtitle glyphs while measuring lower black bars.
                if cfg.excludeSubtitles && y >= h * 4 / 5 && x >= w / 5 && x <= w * 4 / 5 { continue }
                let p = b + y * st + x * 4
                if max(p[0], max(p[1], p[2])) > 12 { bright += 1 }
                count += 1
            }
            return count > 0 && Double(bright) / Double(count) <= 0.015
        }
        func isBarColumn(_ x: Int) -> Bool {
            var bright = 0, count = 0
            for y in stride(from: 0, to: h, by: 2) {
                let p = b + y * st + x * 4
                if max(p[0], max(p[1], p[2])) > 12 { bright += 1 }
                count += 1
            }
            return count > 0 && Double(bright) / Double(count) <= 0.015
        }
        var top = 0, bottom = h - 1, left = 0, right = w - 1
        while top < h / 2 && isBarRow(top) { top += 1 }
        while bottom > h / 2 && isBarRow(bottom) { bottom -= 1 }
        while left < w / 2 && isBarColumn(left) { left += 1 }
        while right > w / 2 && isBarColumn(right) { right -= 1 }
        return (top, bottom, left, right)
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sb),
              let description = CMSampleBufferGetFormatDescription(sb),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.pointee.mBitsPerChannel == 32 else { return }
        var sizeNeeded = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: sizeNeeded)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else {
            audioLock.lock(); audioFails += 1; audioLock.unlock(); return
        }
        var sum = 0.0, count = 0
        for buffer in UnsafeMutableAudioBufferListPointer(abl) {
            guard let data = buffer.mData else { continue }
            let values = data.assumingMemoryBound(to: Float32.self)
            for i in stride(from: 0, to: Int(buffer.mDataByteSize) / 4, by: 2) {
                let value = Double(values[i])
                if value.isFinite { sum += value * value; count += 1 }
            }
        }
        guard count > 0 else { return }
        let rms = (sum / Double(count)).squareRoot()
        let now = ProcessInfo.processInfo.systemUptime
        audioLock.lock()
        let dt = lastAudioTime > 0 ? max(0, min(0.5, now - lastAudioTime)) : 0.01
        audioPeak = max(rms, audioPeak * exp(-dt / 12))
        let level = min(1, rms / max(audioPeak, 0.004))
        audioLevel += (level - audioLevel) * (1 - exp(-dt / (level > audioLevel ? 0.03 : 0.25)))
        lastAudioTime = now
        audioLock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard !stopped else { return }
        if type == .audio { handleAudio(sampleBuffer); return }
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let status = attachments.first?[.status] as? Int,
           status != SCFrameStatus.complete.rawValue { return }
        let started = ProcessInfo.processInfo.systemUptime
        let dt = lastFrameTime.map { max(0, started - $0) } ?? 1.0 / Double(max(1, cfg.fps))
        lastFrameTime = started
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        let rowBytes = CVPixelBufferGetBytesPerRow(px)
        guard w > 0, h > 0 else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let crop = safePicture(cfg.cropRect)
        let cropX = max(0, min(w - 1, Int(crop.minX * Double(w))))
        let cropY = max(0, min(h - 1, Int(crop.minY * Double(h))))
        let cropW = max(1, min(w - cropX, Int(crop.width * Double(w))))
        let cropH = max(1, min(h - cropY, Int(crop.height * Double(h))))
        let sourceRect = CGRect(x: Double(cropX) / Double(w), y: Double(cropY) / Double(h),
                                width: Double(cropW) / Double(w), height: Double(cropH) / Double(h))
        let croppedBytes = bytes + cropY * rowBytes + cropX * 4
        var localPicture = fullPicture
        if cfg.letterbox {
            let (t, b, l, r) = detectBars(croppedBytes, cropW, cropH, rowBytes)
            let candidate = CGRect(x: Double(l) / Double(cropW), y: Double(t) / Double(cropH),
                                   width: Double(r - l + 1) / Double(cropW), height: Double(b - t + 1) / Double(cropH))
            var frameLuma = 0.0, count = 0
            for y in stride(from: 0, to: cropH, by: 4) {
                for x in stride(from: 0, to: cropW, by: 4) {
                    let p = croppedBytes + y * rowBytes + x * 4
                    frameLuma += luma(Double(p[2]), Double(p[1]), Double(p[0])) / 255
                    count += 1
                }
            }
            localPicture = bounds.update(detected: candidate, frameLuma: frameLuma / Double(max(1, count)), deltaTime: dt)
        }
        let picture = CGRect(x: sourceRect.minX + localPicture.minX * sourceRect.width,
                             y: sourceRect.minY + localPicture.minY * sourceRect.height,
                             width: localPicture.width * sourceRect.width,
                             height: localPicture.height * sourceRect.height)
        let samples = sampleLightZones(bytes, width: w, height: h, bytesPerRow: rowBytes,
                                       pictureRect: picture, cfg: cfg)
        acceptSamples(samples)
        samplingMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        reportFrames += 1
    }

    private func emitLatest() {
        guard !stopped, let samples = latestSamples else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let dt = lastOutputTime.map { max(0, started - $0) } ?? 1.0 / Double(max(1, cfg.fps))
        lastOutputTime = started
        var pace: (colour: Double, release: Double) = (1, 1)
        if cfg.sceneAware {
            // Capture delivers nothing while the screen is still, so let a
            // quiet stretch read as calm instead of freezing the last estimate.
            if let t = lastMotionTime, started - t > 0.25 { activity.idle(deltaTime: dt) }
            pace = activity.pace
        }
        var colors = pipeline.process(samples.colors, luminances: samples.luminances,
                                      deltaTime: dt, cut: pendingCut, pace: pace)
        pendingCut = false
        if cfg.audio {
            audioLock.lock()
            let level = audioLevel, fresh = started - lastAudioTime < 1
            audioLock.unlock()
            // If audio capture stops, retain picture lighting instead of getting stuck dim.
            let scale = fresh ? (1 - unit(cfg.audioDepth)) + unit(cfg.audioDepth) * level.squareRoot() : 1
            for i in colors.indices { colors[i] = UInt8(Double(colors[i]) * scale) }
        }
        sink.send(expandLightZones(colors, cfg: cfg))
        if started - reportTime >= 0.5 {
            measuredFPS = Double(reportFrames) / (started - reportTime)
            reportFrames = 0; reportTime = started
        }
        if started - lastPreviewTime >= 0.1 {
            lastPreviewTime = started
            let visible = previewZones(colors, cfg: cfg)
            if cfg.preview {
                var line = "\r"
                for z in 0..<visible.count / 3 {
                    line += "\u{1B}[48;2;\(visible[z * 3]);\(visible[z * 3 + 1]);\(visible[z * 3 + 2])m  "
                }
                FileHandle.standardError.write((line + "\u{1B}[0m").data(using: .utf8)!)
            }
            if let callback = onPreview {
                let labels = cfg.layout == .columns ? (1...max(1, cfg.ledCount)).map { "LED \($0)" } : cfg.layout.labels
                let preview = FramePreview(colors: visible, labels: labels, captureFPS: measuredFPS,
                                           processingMS: samplingMS + (ProcessInfo.processInfo.systemUptime - started) * 1000,
                                           pictureRect: samples.pictureRect)
                DispatchQueue.main.async { callback(preview) }
            }
        }
    }
}
