package app.cinespice.android;

import java.io.File;
import java.io.IOException;

/** Keeps an interrupted sign-out from restoring an authorized account on restart. */
final class SessionLogout {
    interface Storage {
        boolean isPending();
        void setPending(boolean pending) throws Exception;
        void clearSession() throws Exception;
    }
    interface Action { void run() throws Exception; }
    private final Storage storage;
    private volatile boolean pending;
    private boolean requested;

    SessionLogout(Storage storage) {
        this.storage = storage;
        pending = storage.isPending();
    }
    boolean isPending() { return pending; }
    boolean blocksAuthorization(String type) {
        return pending && !type.equals("authorizationStateWaitTdlibParameters") &&
            !type.equals("authorizationStateLoggingOut") && !type.equals("authorizationStateClosing") &&
            !type.equals("authorizationStateClosed");
    }
    synchronized void begin() throws Exception {
        storage.setPending(true);
        pending = true;
    }
    // Called only on the serial authorization queue. An OK response is not completion:
    // TDLib must report Closed before its files can safely be removed.
    void request(Action logout) throws Exception {
        if (!pending || requested) return;
        requested = true;
        try { logout.run(); }
        catch (Exception e) { requested = false; throw e; }
    }
    void closed() throws Exception {
        if (pending) {
            storage.clearSession();
            storage.setPending(false);
            pending = false;
        }
        requested = false;
    }
    static void deleteSession(File directory) throws IOException {
        if (!directory.exists()) return;
        if (directory.isDirectory()) {
            File[] children = directory.listFiles();
            if (children == null) throw new IOException("Could not read local session storage");
            for (File child : children) deleteSession(child);
        }
        if (!directory.delete()) throw new IOException("Could not clear local session storage");
    }
}
