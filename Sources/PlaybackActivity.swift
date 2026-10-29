import Foundation

/// VLC can report buffering while decoding continues. Show a spinner only when
/// playback has actually stopped advancing for a sustained interval.
struct PlaybackActivity {
    private var lastTime: Double?
    private var lastAdvance: Date?
    mutating func stalled(time: Double, waiting: Bool, paused: Bool, now: Date = Date()) -> Bool {
        if lastTime == nil || abs(time - (lastTime ?? time)) > 0.05 || paused {
            lastAdvance = now
        }
        lastTime = time
        return waiting && !paused && now.timeIntervalSince(lastAdvance ?? now) >= 2
    }
}

/// A failed/unfinished seek must never replace a known-good resume position.
struct PlaybackRecovery {
    enum Result { case waiting, reached, timedOut }
    private(set) var target: Double?
    private(set) var failedTarget: Double?
    private(set) var issued = false
    private var began = Date()
    private var resuming = false
    var protectsProgress: Bool { target != nil || failedTarget != nil }
    mutating func begin(_ position: Double, resuming: Bool = false, now: Date = Date()) {
        target = max(0, position); failedTarget = nil; issued = false; began = now; self.resuming = resuming
    }
    mutating func issue(duration: Double) -> Double? {
        guard let target, !issued else { return nil }
        let value = duration > 0 ? min(target, max(0, duration - (resuming ? 5 : 0))) : target
        self.target = value; issued = true
        return value
    }
    mutating func poll(position: Double, now: Date = Date()) -> Result {
        guard let target else { return .waiting }
        if issued && abs(position - target) < 3 {
            self.target = nil; failedTarget = nil; issued = false; return .reached
        }
        if now.timeIntervalSince(began) >= 60 {
            failedTarget = target; self.target = nil; issued = false; return .timedOut
        }
        return .waiting
    }
}
