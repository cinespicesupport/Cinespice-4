package app.cinespice.android;

final class DownloadStatus {
    static String reconcile(String previous, boolean complete, boolean exists, boolean active) {
        if (complete && exists) return "Downloaded";
        if (previous.equals("Cancelled") || previous.equals("Paused")) return previous;
        if (active && (previous.equals("Downloading") || previous.equals("Preparing"))) return "Downloading";
        return "Retry download";
    }
}
