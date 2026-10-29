package app.cinespice.android;
import org.junit.Test;
import static org.junit.Assert.*;

public class PlaybackRecoveryTest {
    @Test public void timeoutProtectsSavedProgressUntilRetrySucceeds() {
        PlaybackRecovery recovery = new PlaybackRecovery();
        recovery.begin(120000, 100);
        assertTrue(recovery.protectsProgress());
        assertEquals(Long.valueOf(120000), recovery.issue(300000));
        assertNull(recovery.issue(300000));
        assertEquals(PlaybackRecovery.Result.TIMED_OUT, recovery.poll(4000, 60100));
        assertNull(recovery.target); assertEquals(Long.valueOf(120000), recovery.failedTarget);
        assertTrue(recovery.protectsProgress());
        assertEquals(PlaybackRecovery.Result.WAITING, recovery.poll(4000, 60101));
        recovery.begin(recovery.failedTarget, 60200); recovery.issue(300000);
        assertEquals(PlaybackRecovery.Result.REACHED, recovery.poll(119000, 60300));
        assertFalse(recovery.protectsProgress());
    }
    @Test public void unseekableResumeCannotOverwriteHistoryAndStartOverClearsItOnSuccess() {
        PlaybackRecovery recovery = new PlaybackRecovery(); recovery.begin(120000, 0);
        assertEquals(PlaybackRecovery.Result.WAITING, recovery.poll(120000, 100));
        assertEquals(PlaybackRecovery.Result.TIMED_OUT, recovery.poll(0, 60000));
        recovery.begin(0, 60001); assertTrue(recovery.protectsProgress()); recovery.issue(300000);
        assertEquals(PlaybackRecovery.Result.REACHED, recovery.poll(0, 60002));
        assertFalse(recovery.protectsProgress());
    }
    @Test public void manualSeekReplacesResumeAndClampsToDuration() {
        PlaybackRecovery recovery = new PlaybackRecovery(); recovery.begin(120000, 0); recovery.issue(300000);
        recovery.begin(600000, 100); assertEquals(Long.valueOf(300000), recovery.issue(300000));
        assertEquals(PlaybackRecovery.Result.REACHED, recovery.poll(300000, 200));
        assertNull(recovery.failedTarget);
    }
}
