package app.cinespice.android;

import org.json.JSONObject;
import java.util.Locale;
import java.util.Set;

final class Video {
    private static final Set<String> EXTENSIONS = Set.of("mp4", "mkv", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mpeg", "mpg", "wmv", "flv", "3gp", "vob", "ogv");
    final long chatId, messageId, size;
    final int fileId, duration, thumbnailId;
    final String name, caption, mime;
    final String displayTitle;
    final JSONObject data;
    Video(JSONObject data) {
        this.data = data;
        chatId = data.optLong("chatId"); messageId = data.optLong("messageId");
        fileId = data.optInt("fileId"); size = data.optLong("size"); duration = data.optInt("duration");
        name = data.optString("name"); caption = data.optString("caption"); mime = data.optString("mime", "video/mp4");
        thumbnailId = data.optInt("thumbnailId");
        displayTitle = cleanTitle(name);
    }
    private static final java.util.regex.Pattern EXTENSION = java.util.regex.Pattern.compile("(?i)\\.(mp4|mkv|mov|avi|webm|m4v|ts|m2ts|mpeg|mpg|wmv|flv|3gp|vob|ogv)(?:\\s+\\1)?$");
    static String cleanTitle(String name) {
        String value = EXTENSION.matcher(name.split("\\R", 2)[0].trim()).replaceFirst("");
        value = value.replaceFirst("(?i)^\\s*[\\[({]?\\s*(?:(?:tg|telegram)[\\s_.:-]*)?@streamers[-_]?hub[\\])}]?[\\s_.:-]*", "");
        value = value.replaceFirst("(?i)^\\s*(?:tg|telegram)\\s+@[a-z0-9_]+\\s+", "");
        value = value.replace('_', ' ').replaceAll("(?<=[\\p{L}\\p{N})])\\.(?=[\\p{L}\\p{N}(])", " ").replaceAll("\\s+", " ").replaceAll("^[ ._-]+|[ ._-]+$", "");
        return value.isEmpty() ? "Untitled video" : value;
    }
    String key() { return chatId + "_" + messageId; }
    static Video fromMessage(JSONObject message) {
        JSONObject content = Json.child(message, "content");
        String type = Json.type(content);
        boolean video = type.equals("messageVideo");
        if (!video && !type.equals("messageDocument")) return null;
        JSONObject media = Json.child(content, video ? "video" : "document");
        String name = media.optString("file_name");
        String mime = media.optString("mime_type", "video/mp4");
        String extension = name.substring(name.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT);
        if (!video && !mime.toLowerCase(Locale.ROOT).startsWith("video/") && !EXTENSIONS.contains(extension)) return null;
        JSONObject file = Json.child(media, video ? "video" : "document");
        if (file.optInt("id") == 0) return null;
        return new Video(Json.obj("chatId", message.optLong("chat_id"), "messageId", message.optLong("id"),
            "fileId", file.optInt("id"), "size", file.optLong("size"), "duration", media.optInt("duration"),
            "name", name.isEmpty() ? "Video " + message.optLong("id") + ".mp4" : name,
            "caption", Json.child(content, "caption").optString("text"), "mime", mime,
            "thumbnailId", Json.child(Json.child(media, "thumbnail"), "file").optInt("id"),
            "mini", Json.child(media, "minithumbnail").optString("data"), "date", message.optLong("date")));
    }
}
