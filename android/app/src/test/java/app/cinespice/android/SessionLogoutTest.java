package app.cinespice.android;

import org.junit.Test;
import org.junit.Rule;
import org.junit.rules.TemporaryFolder;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import static org.junit.Assert.*;

public class SessionLogoutTest {
    @Rule public TemporaryFolder temporary = new TemporaryFolder();
    private static final class Storage implements SessionLogout.Storage {
        boolean pending, failCleanup, failMarker;
        int cleanups;
        public boolean isPending() { return pending; }
        public void setPending(boolean value) throws IOException {
            if (failMarker) throw new IOException("Unavailable storage");
            pending = value;
        }
        public void clearSession() throws IOException {
            if (failCleanup) throw new IOException("Unavailable session");
            cleanups++;
        }
    }
    @Test public void requestAcknowledgementDoesNotClearSessionBeforeClientCloses() throws Exception {
        Storage storage = new Storage();
        SessionLogout logout = new SessionLogout(storage);
        logout.begin();
        int[] requests = {0};
        logout.request(() -> requests[0]++);
        logout.request(() -> requests[0]++);
        assertEquals(1, requests[0]);
        assertTrue(logout.isPending());
        assertTrue(storage.pending);
        assertEquals(0, storage.cleanups);
        logout.closed();
        assertFalse(logout.isPending());
        assertFalse(storage.pending);
        assertEquals(1, storage.cleanups);
    }
    @Test public void interruptedSignOutRemainsPendingAndCanRevokeAfterRestart() throws Exception {
        Storage storage = new Storage();
        SessionLogout original = new SessionLogout(storage);
        original.begin();
        original.request(() -> {});
        SessionLogout restored = new SessionLogout(storage);
        assertTrue(restored.isPending());
        assertTrue(restored.blocksAuthorization("authorizationStateReady"));
        assertTrue(restored.blocksAuthorization("authorizationStateWaitPassword"));
        assertTrue(restored.blocksAuthorization("authorizationStateWaitPhoneNumber"));
        // Initialization and closure must keep flowing so revocation can finish.
        for (String state : new String[]{"authorizationStateWaitTdlibParameters", "authorizationStateLoggingOut",
                "authorizationStateClosing", "authorizationStateClosed"}) assertFalse(restored.blocksAuthorization(state));
        int[] requests = {0};
        restored.request(() -> requests[0]++);
        assertEquals(1, requests[0]);
        restored.closed();
        assertFalse(new SessionLogout(storage).isPending());
        assertFalse(restored.blocksAuthorization("authorizationStateReady"));
    }
    @Test public void failedRevocationCanBeRetriedWithoutRestoringTheAccount() throws Exception {
        SessionLogout logout = new SessionLogout(new Storage());
        logout.begin();
        assertThrows(IOException.class, () -> logout.request(() -> { throw new IOException("Offline"); }));
        assertTrue(logout.isPending());
        int[] requests = {0};
        logout.request(() -> requests[0]++);
        assertEquals(1, requests[0]);
        logout.closed();
        assertFalse(logout.isPending());
    }
    @Test public void failedCleanupRemainsPendingUntilRetrySucceeds() throws Exception {
        Storage storage = new Storage();
        SessionLogout logout = new SessionLogout(storage);
        logout.begin();
        storage.failCleanup = true;
        assertThrows(IOException.class, logout::closed);
        assertTrue(logout.isPending());
        assertTrue(new SessionLogout(storage).isPending());
        storage.failCleanup = false;
        logout.closed();
        assertFalse(logout.isPending());
    }
    @Test public void durableIntentMustBeSavedBeforeSignOutCanBegin() {
        Storage storage = new Storage(); storage.failMarker = true;
        SessionLogout logout = new SessionLogout(storage);
        assertThrows(IOException.class, logout::begin);
        assertFalse(logout.isPending());
        assertEquals(0, storage.cleanups);
    }
    @Test public void ordinaryClientClosurePreservesSession() throws Exception {
        Storage storage = new Storage();
        SessionLogout logout = new SessionLogout(storage);
        logout.closed();
        assertFalse(logout.isPending());
        assertEquals(0, storage.cleanups);
    }
    @Test public void failedMarkerRemovalStillBlocksSessionRestore() throws Exception {
        Storage storage = new Storage();
        SessionLogout logout = new SessionLogout(storage);
        logout.begin();
        storage.failMarker = true;
        assertThrows(IOException.class, logout::closed);
        assertTrue(logout.isPending());
        assertTrue(new SessionLogout(storage).isPending());
        storage.failMarker = false;
        logout.closed();
        assertFalse(logout.isPending());
    }
    @Test public void deletesOnlySessionFilesAndPreservesAccountLibrary() throws Exception {
        File session = temporary.newFolder("telegram");
        File files = new File(session, "files"); assertTrue(files.mkdir());
        Files.write(new File(files, "video.mp4").toPath(), new byte[]{1, 2});
        Files.write(new File(session, "db.sqlite").toPath(), new byte[]{3});
        File library = temporary.newFile("library_123.db");
        Files.write(library.toPath(), new byte[]{4, 5});
        SessionLogout.deleteSession(session);
        SessionLogout.deleteSession(session); // Cleanup is safe to retry after partial completion.
        assertFalse(session.exists());
        assertArrayEquals(new byte[]{4, 5}, Files.readAllBytes(library.toPath()));
    }
}
