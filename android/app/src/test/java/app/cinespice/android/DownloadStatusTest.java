package app.cinespice.android;
import org.junit.Test;
import static org.junit.Assert.*;

public class DownloadStatusTest {
    @Test public void activeDownloadSurvivesReconciliation() {
        assertEquals("Downloading", DownloadStatus.reconcile("Downloading", false, false, true));
        assertEquals("Downloading", DownloadStatus.reconcile("Preparing", false, true, true));
    }
    @Test public void missingOrInterruptedFileOffersRetry() {
        assertEquals("Retry download", DownloadStatus.reconcile("Downloading", false, true, false));
        assertEquals("Retry download", DownloadStatus.reconcile("Downloaded", true, false, false));
    }
    @Test public void streamingDoesNotResurrectCancelledFullDownload() {
        assertEquals("Cancelled", DownloadStatus.reconcile("Cancelled", false, true, true));
        assertEquals("Retry download", DownloadStatus.reconcile("Retry download", false, true, true));
        assertEquals("Downloaded", DownloadStatus.reconcile("Preparing", true, true, false));
    }
    @Test public void pausedIntentSurvivesStreamingAndMissingCache() {
        for (boolean active : new boolean[]{false, true}) {
            assertEquals("Paused", DownloadStatus.reconcile("Paused", false, true, active));
            assertEquals("Paused", DownloadStatus.reconcile("Paused", false, false, active));
        }
        assertEquals("Paused", DownloadStatus.reconcile("Paused", true, false, false));
        assertEquals("Downloaded", DownloadStatus.reconcile("Paused", true, true, false));
        assertEquals("Retry download", DownloadStatus.reconcile("Pausing", false, true, false));
    }
}
