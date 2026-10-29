package app.cinespice.android;
import org.json.JSONObject;
import org.junit.Test;
import static org.junit.Assert.*;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

public class AccessReceiptTest {
    @Test public void verifiesPythonSignatureAndRejectsReplaysAndTampering() throws Exception {
        JSONObject fixture;
        try (java.io.InputStream input = getClass().getResourceAsStream("/access-receipt.json")) {
            assertNotNull(input); fixture = new JSONObject(new String(input.readAllBytes(), StandardCharsets.UTF_8));
        }
        String token=fixture.getString("token"), key=fixture.getString("publicKey"), nonce=fixture.getString("nonce");
        assertEquals("authorized",AccessReceipt.verify(token,key,7,nonce,1800000001L).status);
        assertThrows(Exception.class,()->AccessReceipt.verify(token,key,8,nonce,1800000001L));
        assertThrows(Exception.class,()->AccessReceipt.verify(token,key,7,"b".repeat(32),1800000001L));
        assertThrows(Exception.class,()->AccessReceipt.verify(token,key,7,nonce,1800003600L));
        assertThrows(Exception.class,()->AccessReceipt.verify(token,key,7,nonce,1799999900L));
        String[] parts=token.split("\\.");
        JSONObject payload=new JSONObject(new String(Base64.getUrlDecoder().decode(parts[1]),StandardCharsets.UTF_8)); payload.put("uid","8");
        String tampered="CSP1."+Base64.getUrlEncoder().withoutPadding().encodeToString(payload.toString().getBytes(StandardCharsets.UTF_8))+"."+parts[2];
        assertThrows(Exception.class,()->AccessReceipt.verify(tampered,key,8,nonce,1800000001L));
    }
    @Test public void deviceBoundGrantsAndRevocations() throws Exception {
        JSONObject fixture;
        try (java.io.InputStream input = getClass().getResourceAsStream("/access-device.json")) {
            assertNotNull(input); fixture = new JSONObject(new String(input.readAllBytes(), StandardCharsets.UTF_8));
        }
        String key = fixture.getString("publicKey"), nonce = fixture.getString("nonce"), device = fixture.getString("device");
        for (String status : new String[]{"authorized", "revoked", "join_required"}) {
            String token = fixture.getString(status);
            AccessReceipt receipt = AccessReceipt.verify(token,key,7,nonce,1800000001L,device);
            assertEquals(status,receipt.status); assertEquals(3,receipt.revision);
            assertEquals(status.equals("join_required") ? 1 : 0,receipt.missing.length());
            assertThrows(Exception.class,()->AccessReceipt.verify(token,key,7,nonce,1800000001L,"d".repeat(24)));
            assertThrows(Exception.class,()->AccessReceipt.verify(token,key,8,nonce,1800000001L,device));
            assertThrows(Exception.class,()->AccessReceipt.verify(token,key,7,nonce,1800003600L,device));
        }
    }
}
