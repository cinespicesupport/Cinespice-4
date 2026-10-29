package app.cinespice.android;

import android.graphics.Typeface;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.style.*;
import org.json.JSONObject;
import org.json.JSONArray;
import java.util.Set;

final class Announcement {
    static boolean isNotice(JSONObject message) {
        return NoticeHistory.marker(message,"notice:1:") != null;
    }
    static boolean hasMedia(JSONObject message) {
        return Set.of("messagePhoto","messageAnimation").contains(Json.type(Json.child(message,"content")));
    }
    static boolean animated(JSONObject message) { return Json.type(Json.child(message,"content")).equals("messageAnimation"); }
    static JSONObject bestPhoto(JSONObject content) {
        JSONArray sizes = Json.array(Json.child(content,"photo"),"sizes");
        JSONObject best = new JSONObject(); long area=0;
        for (int i=0;i<sizes.length();i++) {
            JSONObject size=sizes.optJSONObject(i); if (size==null) continue;
            long candidate=size.optLong("width")*size.optLong("height");
            if (candidate>area) { area=candidate; best=size; }
        }
        return best;
    }
    static float ratio(JSONObject message) {
        JSONObject content=Json.child(message,"content");
        JSONObject media=animated(message) ? Json.child(content,"animation") : bestPhoto(content);
        return Math.max(1,media.optInt("width",1))/(float)Math.max(1,media.optInt("height",1));
    }
    static JSONObject file(JSONObject message) {
        JSONObject content = Json.child(message, "content");
        if (Json.type(content).equals("messageAnimation")) return Json.child(Json.child(content, "animation"), "animation");
        return Json.child(bestPhoto(content),"photo");
    }
    static CharSequence text(JSONObject message) {
        JSONObject content = Json.child(message, "content");
        JSONObject formatted = Json.child(content, Json.type(content).equals("messageText") ? "text" : "caption");
        SpannableString text = new SpannableString(formatted.optString("text")); JSONArray entities = Json.array(formatted, "entities");
        for (int i=0;i<entities.length();i++) {
            JSONObject entity = entities.optJSONObject(i); if (entity==null) continue;
            int start=entity.optInt("offset", -1), length=entity.optInt("length");
            if (start<0 || length<=0 || start>text.length() || length>text.length()-start) continue;
            JSONObject type = Json.child(entity, "type");
            Object span = switch(Json.type(type)) {
                case "textEntityTypeBold" -> new StyleSpan(Typeface.BOLD);
                case "textEntityTypeItalic" -> new StyleSpan(Typeface.ITALIC);
                case "textEntityTypeUnderline" -> new UnderlineSpan();
                case "textEntityTypeStrikethrough" -> new StrikethroughSpan();
                case "textEntityTypeCode", "textEntityTypePre", "textEntityTypePreCode" -> new TypefaceSpan("monospace");
                default -> null;
            };
            if (Json.type(type).equals("textEntityTypeTextUrl") || Json.type(type).equals("textEntityTypeUrl")) {
                String url = type.optString("url", text.subSequence(start,start+length).toString());
                if (url.startsWith("https://") || url.startsWith("http://")) span = new URLSpan(url);
            }
            if (span!=null) text.setSpan(span,start,start+length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        return text;
    }
}
