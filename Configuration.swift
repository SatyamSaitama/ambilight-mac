import Foundation
import CoreGraphics

struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Validate before allocating buffers, starting capture, or opening a connection.
func validatedConfig(_ cfg: Config) throws -> Config {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ConfigurationError(message) }
    }
    func inRange(_ value: Double, _ range: ClosedRange<Double>) -> Bool { value.isFinite && range.contains(value) }
    try require((1...490).contains(cfg.ledCount), "LED count must be between 1 and 490")
    try require((1...120).contains(cfg.fps), "Capture rate must be between 1 and 120 fps")
    try require((64...960).contains(cfg.analysisWidth), "Analysis width must be between 64 and 960 pixels")
    try require(cfg.displayIndex >= 0, "Display index cannot be negative")
    try require(cfg.port > 0, "UDP port cannot be zero")
    try require(inRange(cfg.brightness, 0...1), "Brightness must be between 0 and 1")
    try require(inRange(cfg.saturation, 0...3), "Saturation must be between 0 and 3")
    try require(inRange(cfg.gamma, 0.5...3), "Gamma must be between 0.5 and 3")
    try require(inRange(cfg.normalize, 0...1), "Dark-scene lift must be between 0 and 1")
    try require(inRange(cfg.vividness, 0...1), "Colour weighting must be between 0 and 1")
    try require(inRange(cfg.blackPoint, 0...0.2), "Black threshold must be between 0 and 0.2")
    try require(inRange(cfg.cutThreshold, 0...1), "Cut threshold must be between 0 and 1")
    try require(inRange(cfg.smoothing, 0...1), "Smoothing must be between 0 and 1")
    try require(inRange(cfg.regionHeight, 0.01...1), "Region height must be between 0.01 and 1")
    try require(inRange(cfg.edgeDepth, 0.05...0.5), "Edge depth must be between 0.05 and 0.5")
    try require(inRange(cfg.responseTime, 0...2), "Response time must be between 0 and 2000 milliseconds")
    try require(inRange(cfg.audioDepth, 0...1), "Audio response must be between 0 and 1")
    try require(inRange(cfg.bleRate, 1...30), "Bluetooth write rate must be between 1 and 30 per second")
    try require((0...255).contains(cfg.bleDeadband), "Bluetooth deadband must be between 0 and 255")
    if let delay = cfg.stepSeconds {
        try require(inRange(delay, 0...3600), "Controller command delay must be between 0 and 3600 seconds")
    }
    for gains in [cfg.leftGain, cfg.rightGain] {
        try require(gains.count == 3 && gains.allSatisfy { inRange($0, 0...2) }, "Calibration requires three finite RGB gains between 0 and 2")
    }
    if let crop = cfg.cropRect {
        try require([crop.origin.x, crop.origin.y, crop.width, crop.height].allSatisfy { $0.isFinite }, "Crop values must be finite")
        try require(crop.origin.x >= 0 && crop.origin.y >= 0 && crop.width > 0 && crop.height > 0 && crop.maxX <= 1.000001 && crop.maxY <= 1.000001,
                    "Crop must fit inside the picture: x,y ≥ 0; width,height > 0; x+width,y+height ≤ 1")
    }
    if cfg.bleName != nil {
        if let right = cfg.bleRightID {
            try require(cfg.bleID != nil && cfg.bleID != right, "Two-bar Bluetooth mode needs two different controller IDs")
            try require(cfg.layout == .sides, "Two Bluetooth controllers support Left + right layout; sections require an addressable backend")
        } else {
            try require(cfg.layout == .whole || cfg.layout == .perimeter,
                        "Your shared Bluetooth controller supports one colour. Use Whole picture or Perimeter; four sections require addressable hardware.")
        }
    } else {
        try require(!cfg.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Enter a WLED host or IP address")
        if cfg.layout == .sides { try require(cfg.ledCount >= 2, "Left + right needs at least two LEDs") }
        if cfg.layout == .four { try require(cfg.ledCount >= 4, "Four sections needs at least four LEDs") }
    }
    return cfg
}
