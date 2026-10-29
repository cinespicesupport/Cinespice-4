package app.cinespice.android;

import android.content.Context;
import org.json.JSONObject;
import org.json.JSONArray;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.spec.X509EncodedKeySpec;
import java.util.Base64;

final class AccessConfiguration {
    final String botUsername, publicKey, contactURL;
    final long botUserID;
    final JSONArray channels;
    private AccessConfiguration(JSONObject data) throws Exception {
        botUsername = data.getString("botUsername"); botUserID = Long.parseLong(data.getString("botUserID"));
        publicKey = data.getString("publicKey"); contactURL = data.getString("contactURL"); channels = data.getJSONArray("channels");
        if (!botUsername.matches("[A-Za-z0-9_]{5,32}") || !botUsername.toLowerCase(java.util.Locale.ROOT).endsWith("bot") || botUserID <= 0 || channels.length() > 10)
            throw new IllegalArgumentException("Invalid access configuration");
        KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(Base64.getDecoder().decode(publicKey)));
        safeLink(contactURL);
        for (int i=0;i<channels.length();i++) {
            JSONObject channel = channels.getJSONObject(i);
            if (channel.getString("title").trim().isEmpty()) throw new IllegalArgumentException("Missing channel title");
            safeLink(channel.getString("url"));
        }
    }
    static URI safeLink(String text) throws Exception {
        URI uri = new URI(text);
        if (!"https".equals(uri.getScheme()) || !"t.me".equals(uri.getHost()) || uri.getRawUserInfo()!=null || uri.getPort()!=-1 ||
            uri.getQuery()!=null || uri.getFragment()!=null || uri.getPath()==null || uri.getPath().length()<2)
            throw new IllegalArgumentException("Invalid community link");
        return uri;
    }
    static AccessConfiguration load(Context context) {
        try (java.io.InputStream input = context.getAssets().open("cinespice-access.json")) {
            java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream(); byte[] buffer = new byte[1024]; int n;
            while ((n=input.read(buffer))!=-1) { bytes.write(buffer,0,n); if (bytes.size()>16384) return null; }
            return new AccessConfiguration(new JSONObject(bytes.toString(StandardCharsets.UTF_8.name())));
        } catch (Exception ignored) { return null; }
    }
}
