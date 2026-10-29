package app.cinespice.android;

/** Deliver available cache data promptly, bounded by the HTTP range. */
final class StreamReadPolicy {
    static int readyCount(long available, int requested) {
        if (requested <= 0 || available < Math.min(requested, 64 * 1024)) return 0;
        return (int) Math.min(available, requested);
    }
}
