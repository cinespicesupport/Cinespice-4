import Foundation

enum PlayerAspect: String, CaseIterable, Identifiable {
    case fit = "Fit", fill = "Fill", wide = "16:9", classic = "4:3", cinema = "21:9"
    var id: String { rawValue }
    var override: String? {
        switch self { case .fit, .fill: return nil; default: return rawValue }
    }
    private var forcedRatio: Double? {
        switch self { case .wide: return 16.0/9; case .classic: return 4.0/3; case .cinema: return 21.0/9; default: return nil }
    }
    func layout(width: Double, height: Double, videoWidth: Double, videoHeight: Double, displayScale: Double) -> PlayerPictureLayout? {
        guard [width,height,videoWidth,videoHeight,displayScale].allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let ratio = forcedRatio ?? videoWidth / videoHeight
        guard ratio.isFinite, ratio > 0 else { return nil }
        let pictureHeight = self == .fill ? max(height, width / ratio) : min(height, width / ratio)
        // VLCKit's scale is physical screen pixels / decoded video pixels.
        let scale = self == .fill ? max(width / videoWidth, height / videoHeight) * displayScale : 0
        guard pictureHeight.isFinite, pictureHeight > 0, scale.isFinite, scale <= Double(Float.greatestFiniteMagnitude) else { return nil }
        return PlayerPictureLayout(scale: Float(scale), aspect: override, pictureHeight: pictureHeight)
    }
}

struct PlayerPictureLayout: Equatable {
    let scale: Float
    let aspect: String?
    let pictureHeight: Double
}

struct PlayerControlLock {
    private(set) var locked = false
    private(set) var unlockVisible = false
    mutating func lock() { locked = true; unlockVisible = false }
    mutating func reveal() { if locked { unlockVisible = true } }
    mutating func hideUnlock() { unlockVisible = false }
    mutating func unlock() { locked = false; unlockVisible = false }
}
