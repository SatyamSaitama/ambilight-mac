import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit
import AVFoundation

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
    mutating func process(_ raw: [Double], snap: Bool = false) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cfg.ledCount * 3)
        let a = snap ? 1.0 : cfg.smoothing

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
    private var prevRaw: [Double]?
    private let audioLock = NSLock()
    private var audioLevel = 0.0
    private var audioPeak = 0.02
    private var audioBuffers = 0
    private var audioFails = 0
    private var audioSamples = 0
    private var audioRawMax = 0.0
    private var audioStatus = 0
    private var audioNeeded = 0

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
        guard CMSampleBufferIsValid(sb) else { audioFails += 1; return }
        audioBuffers += 1

        // Two-call pattern: ask how big the list needs to be, then allocate
        // exactly that. Guessing the size fails with ArrayTooSmall (-12737),
        // and every sample is then silently discarded.
        var sizeNeeded = 0
        var probe = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil)
        audioNeeded = sizeNeeded
        guard probe == noErr, sizeNeeded > 0 else {
            audioStatus = Int(probe); audioFails += 1; return
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: sizeNeeded)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var block: CMBlockBuffer?
        probe = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block)
        let status = probe
        audioStatus = Int(status)
        guard status == noErr else { audioFails += 1; return }

        var sum = 0.0
        var count = 0
        for buf in UnsafeMutableAudioBufferListPointer(ablPtr) {
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
        guard count > 0 else { audioFails += 1; return }
        let rms = (sum / Double(count)).squareRoot()
        audioSamples = count
        if rms > audioRawMax { audioRawMax = rms }

        audioLock.lock()
        audioPeak = max(rms, audioPeak * 0.9992)          // slow decay
        let lvl = min(1.0, rms / max(audioPeak, 0.004))
        // Attack fast, release slow -- a light that drops instantly on every
        // gap between words reads as flicker.
        let a = lvl > audioLevel ? 0.5 : 0.04
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
            var wsum = 0.0

            for y in top..<min(top + rows, h) {
                let row = bytes + y * stride
                for x in x0..<min(x1, w) {
                    let p = row + x * 4          // BGRA
                    let b = Double(p[0]), g = Double(p[1]), r = Double(p[2])

                    // Weight each pixel by how colourful it is. A flat mean is
                    // dominated by grey UI and dark background, which is what
                    // makes averaged screen colour look muddy; this lets the
                    // few saturated pixels that define a shot actually carry it.
                    let wgt = chromaWeight(r, g, b, cfg.vividness)

                    rs += r * wgt; gs += g * wgt; bs += b * wgt
                    wsum += wgt
                }
            }
            guard wsum > 0 else { continue }
            let d = wsum * 255.0
            let o = led * 3
            raw[o] = rs / d; raw[o + 1] = gs / d; raw[o + 2] = bs / d
        }

        // A hard cut moves every zone at once. Sliding into the new colour
        // would spend half a second showing a blend that appears in neither
        // shot, so on a cut we snap and let smoothing resume after.
        var cut = false
        if let prev = prevRaw, prev.count == raw.count {
            var diff = 0.0
            for i in 0..<raw.count { diff += abs(raw[i] - prev[i]) }
            if diff / Double(raw.count) > cfg.cutThreshold { cut = true }
        }
        prevRaw = raw

        var out = pipeline.process(raw, snap: cut)

        if cfg.audio {
            audioLock.lock(); let lvl = audioLevel; audioLock.unlock()
            // sqrt curve: moderate audio should already read near full
            // brightness, so the lamp pulses rather than sitting dim. A linear
            // map spends most of a film in the bottom half of its range.
            let k = (1 - cfg.audioDepth) + cfg.audioDepth * lvl.squareRoot()
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
                String(format: "%@  %.1f fps%@%@%@\n", cfg.preview ? "\n" : "", fps,
                       cfg.letterbox ? "  picture \(contentW)x\(contentH) of \(w)x\(h)" : "",
                       cut ? "  [cut]" : "",
                       cfg.audio ? String(format: "  audio %.2f%@", audioLevel,
                                               audioFails > 0
                                                 ? " EXTRACT-FAIL=\(audioFails) st=\(audioStatus)"
                                                 : "") : "").data(using: .utf8)!)
            frames = 0
            lastReport = Date()
        }
    }
}

