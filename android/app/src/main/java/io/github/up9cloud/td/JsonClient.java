// JNI package/signatures must match the pinned up9cloud TDLib build.
package io.github.up9cloud.td;
public final class JsonClient {
    static { System.loadLibrary("tdjson"); }
    private JsonClient() {}
    public static native int td_create_client_id();
    public static native void td_send(int clientId, String request);
    public static native String td_receive(double timeout);
    public static native String td_execute(String request);
}
