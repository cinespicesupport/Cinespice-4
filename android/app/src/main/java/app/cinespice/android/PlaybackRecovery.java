package app.cinespice.android;

final class PlaybackRecovery {
    enum Result { WAITING, REACHED, TIMED_OUT }
    Long target, failedTarget;
    private boolean issued;
    private long began;
    boolean protectsProgress() { return target != null || failedTarget != null; }
    void begin(long position, long now) { target = Math.max(0, position); failedTarget = null; issued = false; began = now; }
    Long issue(long duration) {
        if (target == null || issued) return null;
        if (duration > 0) target = Math.min(target, Math.max(0, duration));
        issued = true; return target;
    }
    Result poll(long position, long now) {
        if (target == null) return Result.WAITING;
        if (issued && Math.abs(position - target) < 3000) { target = failedTarget = null; issued = false; return Result.REACHED; }
        if (now - began >= 60000) { failedTarget = target; target = null; issued = false; return Result.TIMED_OUT; }
        return Result.WAITING;
    }
}
