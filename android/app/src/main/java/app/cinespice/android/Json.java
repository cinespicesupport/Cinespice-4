package app.cinespice.android;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

final class Json {
    private Json() {}
    static JSONObject obj(Object... pairs) {
        JSONObject value = new JSONObject();
        try {
            for (int i = 0; i < pairs.length; i += 2) value.put((String) pairs[i], pairs[i + 1]);
        } catch (JSONException e) { throw new IllegalArgumentException(e); }
        return value;
    }
    static JSONObject child(JSONObject obj, String key) {
        JSONObject result = obj.optJSONObject(key);
        return result == null ? new JSONObject() : result;
    }
    static JSONArray array(JSONObject obj, String key) {
        JSONArray result = obj.optJSONArray(key);
        return result == null ? new JSONArray() : result;
    }
    static String type(JSONObject obj) { return obj.optString("@type"); }
}
