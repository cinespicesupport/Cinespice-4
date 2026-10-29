package app.cinespice.android;
import org.json.JSONObject;
import org.junit.Test;
import static org.junit.Assert.*;

public class VideoTest {
    private JSONObject message(String kind, String name, String mime) {
        return Json.obj("id", 1125899906842625L, "chat_id", -1001234567890L, "date", 123,
            "content", Json.obj("@type", kind.equals("video") ? "messageVideo" : "messageDocument",
                kind, Json.obj("file_name", name, "mime_type", mime, "duration", 60,
                    kind, Json.obj("id", 7, "size", 5000000000L)), "caption", Json.obj("text", "A title")));
    }
    @Test public void cleansDisplayTitleWithoutChangingOriginalMetadata() {
        String raw = "Tg @StreamersHub Demon_Slayer - Kimetsu no Yaiba Infinity C.mkv MKV";
        Video video = Video.fromMessage(message("video", raw, "video/x-matroska"));
        assertEquals("Demon Slayer - Kimetsu no Yaiba Infinity C", video.displayTitle);
        assertEquals(raw, video.name);
        assertEquals(raw, new Video(video.data).name);
    }
    @Test public void decodesLargeIdentifiersAndFilesWithoutTruncation() {
        Video video = Video.fromMessage(message("video", "film.mp4", "video/mp4"));
        assertNotNull(video); assertEquals(5000000000L, video.size); assertEquals(-1001234567890L, video.chatId);
        assertEquals("-1001234567890_1125899906842625", video.key()); assertEquals("A title", video.caption);
        assertEquals(video.key(), new Video(video.data).key());
    }
    @Test public void includesVideoDocumentsByExtensionOrMime() {
        assertNotNull(Video.fromMessage(message("document", "FILM.MKV", "application/octet-stream")));
        assertNotNull(Video.fromMessage(message("document", "clip", "video/webm")));
        assertNotNull(Video.fromMessage(message("video", "", "video/mp4")));
    }
    @Test public void excludesAudioImagesTextAndBrokenFiles() {
        assertNull(Video.fromMessage(message("document", "song.mp3", "audio/mpeg")));
        assertNull(Video.fromMessage(message("document", "photo.jpg", "image/jpeg")));
        assertNull(Video.fromMessage(Json.obj("content", Json.obj("@type", "messageText"))));
        assertNull(Video.fromMessage(Json.obj("content", Json.obj("@type", "messageVideo", "video", new JSONObject()))));
    }
}
