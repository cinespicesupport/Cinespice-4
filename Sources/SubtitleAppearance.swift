import Foundation

/// UI sizes use iOS points (logical pixels). VLCKit exposes a relative font divisor,
/// so calibrate it against the displayed picture instead of treating it as a size.
struct SubtitleSize: Equatable {
    static let range = 6...18
    static let standard = SubtitleSize(12)
    let points: Int
    init(_ value: Int) { points = min(Self.range.upperBound, max(Self.range.lowerBound, value)) }
    var title: String { "\(points) pt" }
    static func restored(_ value: Int, legacy: Int = 0) -> Self {
        if range.contains(value) { return Self(value) }
        // The old values were divisors: a smaller value meant a larger font.
        let migrated = [20: 6, 18: 8, 16: 12, 12: 15, 6: 18]
        return migrated[legacy].map(Self.init) ?? .standard
    }
    func rendererDivisor(pictureHeight: Double) -> Int? {
        guard pictureHeight.isFinite, pictureHeight > 0 else { return nil }
        return Int(min(4096, max(1, (pictureHeight / Double(points)).rounded())))
    }
}

/// Track discovery is asynchronous. Do not treat a temporary empty list as a
/// user's Off choice, and never undo an explicit Off while discovery continues.
struct SubtitleSelection {
    private var userChoice: Int32?
    mutating func select(_ id: Int32) { userChoice = id }
    mutating func imported() { userChoice = nil }
    func desired(available: [Int32], current: Int32) -> Int32? {
        if let choice = userChoice {
            guard choice == -1 || available.contains(choice) else { return nil }
            return current == choice ? nil : choice
        }
        guard current < 0 else { return nil }
        return available.first(where: { $0 >= 0 })
    }
}

/// VobSub is an IDX index with a companion SUB bitmap file. Copy both, but give
/// VLC only the index; standalone text SUB files still load normally.
enum SubtitleAttachments {
    static func tracks(in files: [URL]) -> [URL] {
        let indexes = Set(files.filter { $0.pathExtension.lowercased() == "idx" }.map { $0.deletingPathExtension().path })
        return files.filter { $0.pathExtension.lowercased() != "sub" || !indexes.contains($0.deletingPathExtension().path) }
    }
}
