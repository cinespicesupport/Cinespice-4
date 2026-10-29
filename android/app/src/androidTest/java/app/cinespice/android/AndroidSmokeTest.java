package app.cinespice.android;

import android.app.Instrumentation;
import android.content.*;
import android.os.SystemClock;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import io.github.up9cloud.td.JsonClient;
import org.json.JSONObject;
import org.junit.*;
import org.junit.runner.RunWith;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public class AndroidSmokeTest {
    private final Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
    private final Context context = instrumentation.getTargetContext();
    @Test public void secureStoreRoundTripAndAccountIsolation() throws Exception {
        SecureStore secure = new SecureStore(context);
        secure.put("synthetic-test", "synthetic-only"); assertEquals("synthetic-only", secure.get("synthetic-test"));
        String ciphertext = context.getSharedPreferences("secure", 0).getString("synthetic-test", ""); assertFalse(ciphertext.contains("synthetic-only"));
        Library first = new Library(context, -91), second = new Library(context, -92);
        first.chat(-10, "Synthetic channel", true, 1); first.select(-10, true);
        Video video = new Video(Json.obj("chatId", -10, "messageId", 11, "fileId", 111, "name", "film.mp4"));
        first.save(video); first.progress(video, 10000, 30000, false);
        assertEquals(1, first.videos(-10, "", false, 10).size()); assertEquals(10000, first.position(video.key()));
        assertEquals(0, second.videos(0, "", false, 10).size()); assertEquals(0, second.position(video.key()));
        first.select(-10, false); assertEquals(0, first.videos(0, "", false, 10).size());
        context.getSharedPreferences("secure", 0).edit().remove("synthetic-test").commit();
        context.deleteDatabase("library_-91.db"); context.deleteDatabase("library_-92.db");
    }
    @Test public void nativeTdlibLoadsAndExecutesWithoutCredentials() throws Exception {
        JSONObject result = new JSONObject(JsonClient.td_execute(Json.obj("@type", "getOption", "name", "version").toString()));
        assertEquals("optionValueString", Json.type(result)); assertTrue(result.optString("value").startsWith("1.8."));
    }
    @Test public void rangeBridgeTransfersActualBytesAndRejectsWrongToken() throws Exception {
        Telegram telegram = ((CinespiceApp) context.getApplicationContext()).telegram;
        String originalStage = telegram.stage; Library originalLibrary = telegram.library; long[] previousAccess = SyntheticAccess.grant(telegram);
        File fixture = new File(context.getCacheDir(), "range-fixture.bin");
        byte[] expected = "0123456789abcdefghijklmnopqrstuvwxyz".getBytes(StandardCharsets.US_ASCII);
        try (FileOutputStream output = new FileOutputStream(fixture)) { output.write(expected); }
        telegram.stage = "ready";
        Video video = new Video(Json.obj("chatId", -1, "messageId", 1, "fileId", 9999, "size", expected.length, "name", "fixture.mp4"));
        telegram.files.put(video.fileId, Json.obj("id", video.fileId, "local", Json.obj("path", fixture.getAbsolutePath(), "is_downloading_completed", true)));
        try (RangeServer server = new RangeServer(telegram, video)) {
            HttpURLConnection connection = (HttpURLConnection) new URL(server.url()).openConnection();
            connection.setRequestProperty("Range", "bytes=10-19"); assertEquals(206, connection.getResponseCode());
            assertEquals("bytes 10-19/36", connection.getHeaderField("Content-Range"));
            ByteArrayOutputStream received = new ByteArrayOutputStream();
            try (InputStream input = connection.getInputStream()) { byte[] buffer = new byte[64]; int count; while ((count = input.read(buffer)) != -1) received.write(buffer, 0, count); }
            assertArrayEquals(java.util.Arrays.copyOfRange(expected, 10, 20), received.toByteArray()); connection.disconnect();
            HttpURLConnection invalid = (HttpURLConnection) new URL(server.url() + "wrong").openConnection(); assertEquals(404, invalid.getResponseCode()); invalid.disconnect();
        } finally { SyntheticAccess.restore(telegram, previousAccess); telegram.stage = originalStage; telegram.library = originalLibrary; telegram.files.remove(video.fileId); fixture.delete(); }
    }
    private static boolean containsText(android.view.View view, String fragment) {
        if (view instanceof android.widget.TextView text && text.getText().toString().contains(fragment)) return true;
        if (view instanceof android.view.ViewGroup group) for (int i = 0; i < group.getChildCount(); i++) if (containsText(group.getChildAt(i), fragment)) return true;
        return false;
    }
    private static android.view.View find(android.view.View view, String label) {
        if (label.contentEquals(view.getContentDescription() == null ? "" : view.getContentDescription())) return view;
        if (view instanceof android.widget.TextView text && text.getText().toString().equals(label)) return view;
        if (view instanceof android.view.ViewGroup group) for (int i = 0; i < group.getChildCount(); i++) { android.view.View found = find(group.getChildAt(i), label); if (found != null) return found; }
        return null;
    }
    private void verifyPanel(PlayerActivity activity, boolean landscape) {
        instrumentation.runOnMainSync(() -> { android.view.View more = find(activity.getWindow().getDecorView(), "More options"); assertNotNull(more); more.performClick(); android.view.View speed = find(activity.getWindow().getDecorView(), "Playback speed"); assertNotNull(speed); speed.performClick(); });
        instrumentation.waitForIdleSync();
        instrumentation.runOnMainSync(() -> {
            android.view.ViewGroup overlay = (android.view.ViewGroup) find(activity.getWindow().getDecorView(), "Player options"); assertNotNull(overlay);
            android.view.View panel = overlay.getChildAt(0); float density = activity.getResources().getDisplayMetrics().density;
            assertTrue("Compact panel width", panel.getWidth() <= (landscape ? 340 : 420) * density + 1);
            assertTrue("Scrollable options height", panel.getHeight() <= overlay.getHeight() * (landscape ? .60 : .32) + 130 * density);
            android.view.View close = find(overlay, "Close player options"); assertNotNull(close); close.performClick();
            assertNull(find(activity.getWindow().getDecorView(), "Player options"));
        });
    }
    @Test public void invalidMediaErrorRemainsVisible() throws Exception {
        Telegram telegram = ((CinespiceApp) context.getApplicationContext()).telegram;
        String originalStage = telegram.stage; Library originalLibrary = telegram.library; long[] previousAccess = SyntheticAccess.grant(telegram);
        File fixture = new File(context.getCacheDir(), "invalid-fixture.mp4");
        try (FileOutputStream out = new FileOutputStream(fixture)) { out.write("not a media file".getBytes(StandardCharsets.US_ASCII)); }
        telegram.stage = "ready"; telegram.library = new Library(context, -94);
        Video video = new Video(Json.obj("chatId", -1, "messageId", 3, "fileId", 9997, "size", fixture.length(), "name", "Invalid.mp4"));
        telegram.files.put(video.fileId, Json.obj("id", video.fileId, "local", Json.obj("path", fixture.getAbsolutePath(), "is_downloading_completed", true)));
        PlayerActivity activity = null;
        try {
            activity = (PlayerActivity) instrumentation.startActivitySync(new Intent(context, PlayerActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("video", video.data.toString()).putExtra("generation", telegram.generation));
            PlayerActivity current = activity; java.util.concurrent.atomic.AtomicBoolean visible = new java.util.concurrent.atomic.AtomicBoolean();
            long deadline = SystemClock.elapsedRealtime() + 20000;
            while (SystemClock.elapsedRealtime() < deadline) {
                instrumentation.runOnMainSync(() -> visible.set(containsText(current.getWindow().getDecorView(), "VLC could not play")));
                if (visible.get()) break; SystemClock.sleep(250);
            }
            assertTrue("VLC error must be presented", visible.get()); SystemClock.sleep(1500);
            instrumentation.runOnMainSync(() -> visible.set(containsText(current.getWindow().getDecorView(), "VLC could not play")));
            assertTrue("Progress ticks must retain the error", visible.get());
        } finally {
            if (activity != null) { PlayerActivity close = activity; instrumentation.runOnMainSync(close::finish); instrumentation.waitForIdleSync(); }
            SyntheticAccess.restore(telegram, previousAccess); telegram.stage = originalStage; telegram.library = originalLibrary; telegram.files.remove(video.fileId); fixture.delete(); context.deleteDatabase("library_-94.db");
        }
    }
    @Test public void localVlcPlaybackPersistsProgress() throws Exception {
        Telegram telegram = ((CinespiceApp) context.getApplicationContext()).telegram;
        String originalStage = telegram.stage; Library originalLibrary = telegram.library; long[] previousAccess = SyntheticAccess.grant(telegram);
        File fixture = new File(context.getCacheDir(), "player-fixture.mp4");
        try (InputStream input = instrumentation.getContext().getAssets().open("playback.mp4"); OutputStream out = new FileOutputStream(fixture)) {
            byte[] bytes = new byte[8192]; int n; while ((n = input.read(bytes)) != -1) out.write(bytes, 0, n);
        }
        telegram.stage = "ready"; telegram.library = new Library(context, -93);
        Video video = new Video(Json.obj("chatId", -1, "messageId", 2, "fileId", 9998, "size", fixture.length(), "name", "Synthetic playback.mp4", "duration", 18));
        telegram.files.put(video.fileId, Json.obj("id", video.fileId, "local", Json.obj("path", fixture.getAbsolutePath(), "is_downloading_completed", true)));
        PlayerActivity activity = null;
        try {
            Intent intent = new Intent(context, PlayerActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("video", video.data.toString()).putExtra("generation", telegram.generation).putExtra("resume", false);
            activity = (PlayerActivity) instrumentation.startActivitySync(intent);
            long deadline = SystemClock.elapsedRealtime() + 45000;
            while (SystemClock.elapsedRealtime() < deadline && telegram.library.position(video.key()) < 5000) SystemClock.sleep(500);
            assertTrue("VLC must decode the fixture and persist at least 5 seconds of progress", telegram.library.position(video.key()) >= 5000);
            verifyPanel(activity, false);
            PlayerActivity current = activity;
            instrumentation.runOnMainSync(() -> find(current.getWindow().getDecorView(), "Rotate").performClick());
            SystemClock.sleep(1500); instrumentation.waitForIdleSync(); verifyPanel(activity, true);
        } finally {
            if (activity != null) { PlayerActivity close = activity; instrumentation.runOnMainSync(close::finish); instrumentation.waitForIdleSync(); }
            SyntheticAccess.restore(telegram, previousAccess); telegram.stage = originalStage; telegram.library = originalLibrary; telegram.files.remove(video.fileId); fixture.delete(); context.deleteDatabase("library_-93.db");
        }
    }
}
