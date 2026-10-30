package app.cinespice.android;

import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.Signature;
import java.security.spec.X509EncodedKeySpec;
import java.util.Base64;
import java.util.Set;
import org.json.JSONObject;

final class AccessReceipt {
    final String status;
    final long expires;
    final long revision;
    final boolean paid;
    final boolean persistent;
    final org.json.JSONArray missing;
    private AccessReceipt(String status, long expires, JSONObject value) {
        this.status = status; this.expires = expires; revision = value.optLong("revision");
        persistent = value.optBoolean("persistent", false);
        paid = value.optBoolean("paid"); missing = value.optJSONArray("missing");
    }
    static AccessReceipt verify(String token, String publicKey, long account, String nonce, long now) throws Exception {
        return verify(token, publicKey, account, nonce, now, null);
    }
    static AccessReceipt verify(String token, String publicKey, long account, String nonce, long now, String device) throws Exception {
        return verify(token, publicKey, account, nonce, now, device, false);
    }
    static AccessReceipt verify(String token, String publicKey, long account, String nonce, long now, String device, boolean allowStored) throws Exception {
        String[] parts = token.split("\\.", -1);
        if (token.length() > 2048 || parts.length != 3 || !parts[0].equals("CSP1") || !nonce.matches("[0-9a-f]{32}"))
            throw new SecurityException("Invalid access receipt");
        byte[] signature = Base64.getUrlDecoder().decode(parts[2]);
        if (signature.length > 72) throw new SecurityException("Invalid signature");
        Signature verifier = Signature.getInstance("SHA256withECDSA");
        verifier.initVerify(KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(Base64.getDecoder().decode(publicKey))));
        verifier.update((parts[0] + "." + parts[1]).getBytes(StandardCharsets.US_ASCII));
        if (!verifier.verify(signature)) throw new SecurityException("Invalid signature");
        JSONObject value = new JSONObject(new String(Base64.getUrlDecoder().decode(parts[1]), StandardCharsets.UTF_8));
        String status = value.getString("status"); long issued = value.getLong("iat"), expires = value.getLong("exp");
        if (value.getInt("v") != 1 || !value.getString("uid").equals(Long.toString(account)) || !value.getString("nonce").equals(nonce) ||
            !Set.of("authorized", "unpaid", "not_started", "join_required", "unavailable", "revoked", "other_device").contains(status) ||
            issued > now + 60 || expires <= issued || expires - issued > 86400 ||
            (!(allowStored && device != null && value.optBoolean("persistent", false) && status.equals("authorized")) && (issued < now - 86400 || expires <= now)))
            throw new SecurityException("Expired or mismatched access receipt");
        if (device != null) {
            if (!device.matches("[0-9a-f]{24}") || !device.equals(value.getString("device")) || value.getLong("revision") < 0)
                throw new SecurityException("Wrong installation");
            value.getBoolean("paid");
            org.json.JSONArray missing = value.getJSONArray("missing");
            for (int i=0; i<missing.length(); i++) if (missing.getInt(i)<0 || missing.getInt(i)>=10) throw new SecurityException("Invalid requirement");
        }
        return new AccessReceipt(status, expires, value);
    }
}
