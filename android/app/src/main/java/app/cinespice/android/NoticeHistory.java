package app.cinespice.android;

import org.json.JSONArray;
import org.json.JSONObject;
import java.util.*;
import java.nio.charset.StandardCharsets;

/** Feed only messages from the authenticated configured bot conversation. */
final class NoticeHistory {
    private final TreeMap<Long,JSONObject> messages = new TreeMap<>(Comparator.reverseOrder());
    long clearedThrough;
    private final Set<Long> removedIDs = new HashSet<>();
    private final Set<String> deletedCampaigns = new HashSet<>();
    static String marker(JSONObject message, String prefix) {
        JSONObject markup = Json.child(message,"reply_markup");
        if (!Json.type(markup).equals("replyMarkupInlineKeyboard")) return null;
        JSONArray rows = Json.array(markup,"rows");
        for (int i=0;i<rows.length();i++) {
            JSONArray row = rows.optJSONArray(i); if (row == null) continue;
            for (int j=0;j<row.length();j++) {
                JSONObject button = row.optJSONObject(j); if (button == null) continue;
                JSONObject type = Json.child(button,"type");
                if (!Json.type(type).equals("inlineKeyboardButtonTypeCallback")) continue;
                try {
                    String data = new String(Base64.getDecoder().decode(type.optString("data")),StandardCharsets.UTF_8);
                    if (data.startsWith(prefix) && data.substring(prefix.length()).matches("[0-9a-f]{32}")) return data.substring(prefix.length());
                } catch (IllegalArgumentException ignored) { }
            }
        }
        return null;
    }
    void ingest(JSONObject message) {
        long id = message.optLong("id"); if (id<=0) return;
        if (marker(message,"notice-clear:1:") != null) {
            clearedThrough = Math.max(clearedThrough,id);
            messages.entrySet().removeIf(entry -> entry.getKey()<=clearedThrough);
        } else if (marker(message,"notice-delete:1:") != null) {
            String campaign = marker(message,"notice-delete:1:"); deletedCampaigns.add(campaign);
            messages.entrySet().removeIf(entry -> campaign.equals(marker(entry.getValue(),"notice:1:")));
        } else {
            String campaign = marker(message,"notice:1:");
            if (id>clearedThrough && !removedIDs.contains(id) && campaign != null && !deletedCampaigns.contains(campaign)) messages.put(id,message);
        }
    }
    boolean contains(long id) { return messages.containsKey(id); }
    void remove(long id) { removedIDs.add(id); messages.remove(id); }
    List<JSONObject> ordered() { return new ArrayList<>(messages.values()); }
}
