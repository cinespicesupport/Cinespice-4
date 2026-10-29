package app.cinespice.android;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class SecureStore {
    private final Context context;
    private static final String ALIAS = "cinespice.telegram";
    SecureStore(Context context) { this.context = context; }
    private SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        if (store.containsAlias(ALIAS)) return (SecretKey) store.getKey(ALIAS, null);
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }
    synchronized void put(String name, String value) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key());
        String encoded = Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP) + ":" +
            Base64.encodeToString(cipher.doFinal(value.getBytes(StandardCharsets.UTF_8)), Base64.NO_WRAP);
        if (!context.getSharedPreferences("secure", 0).edit().putString(name, encoded).commit()) throw new IllegalStateException("Could not save secure credentials");
    }
    synchronized String get(String name) throws Exception {
        String value = context.getSharedPreferences("secure", 0).getString(name, null);
        if (value == null) return null;
        String[] parts = value.split(":");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)));
        return new String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), StandardCharsets.UTF_8);
    }
    synchronized String installationID() throws Exception {
        String value = get("access-installation");
        if (value == null || !value.matches("[0-9a-f]{24}")) {
            byte[] bytes = new byte[12]; new java.security.SecureRandom().nextBytes(bytes);
            StringBuilder text = new StringBuilder(); for (byte b: bytes) text.append(String.format("%02x", b & 255));
            value = text.toString(); put("access-installation", value);
        }
        return value;
    }
    synchronized void remove(String name) {
        if (!context.getSharedPreferences("secure", 0).edit().remove(name).commit()) throw new IllegalStateException("Could not clear activation");
    }
    synchronized void removeSession() {
        if (!context.getSharedPreferences("secure", 0).edit().remove("database-key").remove("credentials").commit())
            throw new IllegalStateException("Could not clear the saved session key");
    }
}
