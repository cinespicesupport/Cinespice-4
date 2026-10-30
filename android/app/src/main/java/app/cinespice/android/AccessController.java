package app.cinespice.android;

import android.content.Context;
import android.os.SystemClock;
import org.json.JSONObject;
import java.util.UUID;
import org.json.JSONArray;

/** Only the configured bot's signed, account-bound reply can unlock this process. */
final class AccessController {
    final AccessConfiguration config;
    private final Telegram telegram;
    private final android.content.SharedPreferences preferences;
    private final SecureStore secure;
    volatile java.util.Set<Integer> missing = java.util.Set.of();
    volatile boolean needsPaid, revoked;
    private String device = "";
    private long revision;
    private boolean activated;
    private Runnable refresh;
    volatile String message = "Activate once to verify your membership on this device.";
    volatile boolean busy;
    volatile JSONObject announcement;
    volatile java.util.List<JSONObject> notifications = java.util.List.of();
    volatile boolean notificationsLoading, notificationsMore = true;
    volatile String notificationsError = "";
    private NoticeHistory noticeHistory = new NoticeHistory();
    private long notificationsCursor;
    private String nonce = "";
    private long botChat, deadline, expires;
    private boolean persistent;
    private final android.os.Handler timer = new android.os.Handler(android.os.Looper.getMainLooper());
    AccessController(Telegram telegram, Context context) { this.telegram = telegram; secure = new SecureStore(context); config = AccessConfiguration.load(context); preferences = context.getSharedPreferences("announcements", 0); }
    synchronized void reset() {
        if (refresh != null) timer.removeCallbacks(refresh);
        nonce = device = ""; botChat = revision = 0; deadline = expires = 0; busy = activated = needsPaid = revoked = persistent = false;
        missing = java.util.Set.of(); announcement = null; noticeHistory = new NoticeHistory(); notifications = java.util.List.of(); notificationsCursor = 0; notificationsMore = true; notificationsLoading = false; notificationsError = "";
        message = "Activate once to verify your membership on this device.";
    }
    private String cacheKey() throws Exception {
        StringBuilder input = new StringBuilder(config.botUserID + "\n" + config.botUsername + "\n" + config.publicKey + "\n" + config.contactURL);
        for (int i=0;i<config.channels.length();i++) input.append("\n").append(config.channels.getJSONObject(i).getString("url"));
        byte[] digest = java.security.MessageDigest.getInstance("SHA-256").digest(input.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
        return "access." + telegram.library.accountId + "." + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(digest);
    }
    synchronized void forget() { if (config != null && telegram.library != null) try { secure.remove(cacheKey()); } catch (Exception e) { throw new IllegalStateException("Could not clear activation", e); } }
    private void save(String token, String challenge) {
        if (!activated) return;
        try { secure.put(cacheKey(), Json.obj("token", token, "nonce", challenge, "device", device, "revision", revision).toString()); }
        catch (Exception ignored) { message = "Could not save activation. You may need to activate again after restarting."; }
    }
    synchronized void restore() {
        if (config == null || telegram.library == null) return;
        try {
            device = secure.installationID();
            String cached = secure.get(cacheKey());
            if (cached == null) return;
            JSONObject snapshot = new JSONObject(cached);
            if (!device.equals(snapshot.getString("device"))) return;
            activated = true; revision = Math.max(0, snapshot.getLong("revision"));
            AccessReceipt receipt = AccessReceipt.verify(snapshot.getString("token"), config.publicKey, telegram.library.accountId,
                snapshot.getString("nonce"), System.currentTimeMillis()/1000, device, true);
            if (receipt.status.equals("authorized") && receipt.revision >= revision) { grant(receipt); telegram.io.execute(() -> verify(false)); return; }
        } catch (Exception ignored) { }
        if (activated) telegram.io.execute(() -> verify(false));
    }
    private void grant(AccessReceipt receipt) {
        persistent = receipt.persistent;
        expires = receipt.expires; deadline = SystemClock.elapsedRealtime() + (expires-System.currentTimeMillis()/1000)*1000;
        telegram.stage = "ready";
        if (refresh != null) timer.removeCallbacks(refresh);
        long session = telegram.generation;
        refresh = () -> { if (session == telegram.generation) telegram.io.execute(() -> verify(false)); };
        timer.postDelayed(refresh, persistent ? 21600000 : Math.max(1000, (expires-System.currentTimeMillis()/1000-30)*1000));
        telegram.io.execute(() -> loadAnnouncements(true));
    }
    private boolean hasValidAccess() {
        return telegram.stage.equals("ready") && (persistent || (expires > System.currentTimeMillis()/1000 && deadline > SystemClock.elapsedRealtime()));
    }
    private void connectionFailed() {
        if (!hasValidAccess()) {
            telegram.stage = "activation";
            message = expires > 0 ? "Your access pass expired. Connect to Telegram and tap Activate to renew it."
                : "Could not reach the access bot. Check your connection and tap Activate.";
        } else {
            message = "Connection interrupted. Your current access remains valid while renewal retries.";
            if (refresh != null) timer.removeCallbacks(refresh);
            long session = telegram.generation;
            refresh = () -> { synchronized (AccessController.this) {
                if (session != telegram.generation) return;
                enforce();
                if (telegram.stage.equals("ready")) telegram.io.execute(() -> verify(false));
            } };
            timer.postDelayed(refresh, 60000);
        }
        telegram.changed();
    }
    synchronized void enforce() {
        if (telegram.stage.equals("ready") && !persistent && (deadline <= SystemClock.elapsedRealtime() || expires <= System.currentTimeMillis()/1000)) {
            telegram.stage = "activation"; message = "Your access pass expired. Connecting to Telegram to renew it…"; telegram.changed();
            if (!busy) telegram.io.execute(() -> verify(false));
        }
    }
    void verify(boolean start) {
        final long session; final String challenge;
        synchronized (this) {
            if (busy || config == null || (!telegram.stage.equals("activation") && !telegram.stage.equals("ready")) || telegram.library == null) return;
            try { device = secure.installationID(); } catch (Exception e) { message = "Could not securely save activation. Please try again."; telegram.changed(); return; }
            session = telegram.generation; challenge = UUID.randomUUID().toString().replace("-", "");
            nonce = challenge; busy = true; message = "Verifying your membership…"; telegram.changed();
        }
        timer.postDelayed(() -> {
            synchronized (this) {
                if (session == telegram.generation && nonce.equals(challenge) && busy) { nonce = ""; busy = false; connectionFailed(); }
            }
        }, 75000);
        try {
            JSONObject chat = telegram.request(Json.obj("@type", "searchPublicChat", "username", config.botUsername));
            JSONObject type = Json.child(chat, "type");
            if (!Json.type(type).equals("chatTypePrivate") || type.optLong("user_id") != config.botUserID) throw new SecurityException();
            synchronized (this) {
                if (session != telegram.generation || !nonce.equals(challenge)) return;
                botChat = chat.getLong("id");
            }
            if (start || !activated) telegram.request(Json.obj("@type", "sendBotStartMessage", "bot_user_id", config.botUserID, "chat_id", botChat, "parameter", "cs2_" + device + "_" + challenge));
            else telegram.request(Json.obj("@type", "sendMessage", "chat_id", botChat, "input_message_content",
                Json.obj("@type", "inputMessageText", "text", Json.obj("@type", "formattedText", "text", "/check " + challenge + " " + device))));
        } catch (Exception e) {
            synchronized (this) {
                if (session == telegram.generation && nonce.equals(challenge)) { busy = false; nonce = ""; connectionFailed(); }
            }
        }
    }
    synchronized void message(JSONObject value) { message(value, true); }
    private synchronized void message(JSONObject value, boolean allowBanner) {
        if (config == null || telegram.library == null || (!telegram.stage.equals("ready") && !telegram.stage.equals("activation")) || value.optBoolean("is_outgoing")) return;
        JSONObject sender = Json.child(value, "sender_id");
        if (!Json.type(sender).equals("messageSenderUser") || sender.optLong("user_id") != config.botUserID || value.optLong("chat_id") != config.botUserID) return;
        long event = eventRevision(value);
        if (event > revision) {
            boolean previousAccessIsValid = hasValidAccess();
            revision = event; nonce = ""; busy = false;
            if (refresh != null) timer.removeCallbacks(refresh);
            if (!previousAccessIsValid) {
                expires = deadline = 0; persistent = false; announcement = null;
                save("", ""); telegram.stage = "activation";
            }
            message = "Membership changed. Verifying…"; telegram.changed();
            if (activated) { long session = telegram.generation; timer.postDelayed(() -> { if (session == telegram.generation) telegram.io.execute(() -> verify(false)); }, 2100); }
            return;
        }
        JSONObject content = Json.child(value, "content");
        String text = Json.child(content, "text").optString("text");
        if (text.startsWith("CSP1.") && busy && !nonce.isEmpty() && value.optLong("chat_id") == botChat) {
            try {
                AccessReceipt receipt = AccessReceipt.verify(text, config.publicKey, telegram.library.accountId, nonce, System.currentTimeMillis()/1000, device);
                if (receipt.revision < revision) return;
                String challenge = nonce; long session = telegram.generation; long chat = botChat;
                nonce = ""; busy = false;
                if (receipt.status.equals("unavailable") && hasValidAccess()) {
                    telegram.io.execute(() -> {
                        try { if (session == telegram.generation) telegram.request(Json.obj("@type", "sendMessage", "chat_id", chat, "input_message_content",
                            Json.obj("@type", "inputMessageText", "text", Json.obj("@type", "formattedText", "text", "/verified " + challenge)))); }
                        catch (Exception ignored) { }
                    });
                    connectionFailed(); return;
                }
                activated = true; revision = receipt.revision;
                java.util.Set<Integer> required = new java.util.HashSet<>();
                for (int i=0;i<receipt.missing.length();i++) required.add(receipt.missing.getInt(i));
                missing = java.util.Set.copyOf(required); needsPaid = receipt.paid; revoked = receipt.status.equals("revoked");
                message = switch(receipt.status) {
                    case "authorized" -> "Verified. Welcome to Cinespice.";
                    case "unpaid" -> "Join the paid group or contact support for access.";
                    case "other_device" -> "This account is active on another device. Activate here to move access to this device.";
                    case "not_started" -> "Tap Activate to continue.";
                    case "join_required" -> "Join the channels below to continue.";
                    case "revoked" -> "Your access was revoked. Contact support.";
                    default -> "Verification is temporarily unavailable. Please try again.";
                };
                if (receipt.status.equals("authorized")) { activated = true; save(text, challenge); grant(receipt); }
                else {
                    expires = deadline = 0; persistent = false; telegram.stage = "activation"; announcement = null;
                    if (refresh != null) timer.removeCallbacks(refresh);
                    save("", "");
                }
                telegram.io.execute(() -> {
                    try { if (session == telegram.generation) telegram.request(Json.obj("@type", "sendMessage", "chat_id", chat, "input_message_content",
                        Json.obj("@type", "inputMessageText", "text", Json.obj("@type", "formattedText", "text", "/verified " + challenge)))); }
                    catch (Exception ignored) { }
                });
                telegram.changed();
            } catch (Exception ignored) { /* Invalid or stale replies never grant access. */ }
        } else if (telegram.stage.equals("ready")) {
            noticeHistory.ingest(value); notifications = noticeHistory.ordered();
            if (announcement != null && notifications.stream().noneMatch(item -> item.optLong("id")==announcement.optLong("id"))) announcement = null;
            if (allowBanner && Announcement.isNotice(value) && noticeHistory.contains(value.optLong("id"))) considerBanner(value);
            telegram.changed();
        }
    }
    private static long eventRevision(JSONObject value) {
        JSONArray rows = Json.array(Json.child(value, "reply_markup"), "rows");
        for (int i=0;i<rows.length();i++) {
            JSONArray row = rows.optJSONArray(i); if (row == null) continue;
            for (int j=0;j<row.length();j++) {
                JSONObject button = row.optJSONObject(j); if (button == null) continue;
                JSONObject type = Json.child(button, "type");
                if (!Json.type(type).equals("inlineKeyboardButtonTypeCallback")) continue;
                try {
                    String data = new String(java.util.Base64.getDecoder().decode(type.optString("data")), java.nio.charset.StandardCharsets.UTF_8);
                    if (data.matches("access:1:[0-9]+")) return Math.max(0, Long.parseLong(data.substring(9)));
                } catch (Exception ignored) { }
            }
        }
        return 0;
    }
    private void considerBanner(JSONObject value) {
        String latestKey = "latest:" + telegram.library.accountId + ":" + config.botUserID;
        long id = value.optLong("id");
        if (id < preferences.getLong(latestKey, 0)) return;
        preferences.edit().putLong(latestKey, id).apply();
        if (!preferences.getBoolean(key(value), false)) announcement = value;
    }
    private String key(JSONObject value) { return telegram.library.accountId + ":" + value.optLong("id"); }
    synchronized void dismiss() { if (announcement != null && telegram.library != null) preferences.edit().putBoolean(key(announcement), true).apply(); announcement = null; telegram.changed(); }
    void loadAnnouncements(boolean refresh) {
        final long session, from;
        synchronized (this) {
            if (config == null || !telegram.stage.equals("ready") || notificationsLoading || (!refresh && !notificationsMore)) return;
            if (refresh) { notificationsCursor = 0; notificationsMore = true; }
            session = telegram.generation; from = notificationsCursor; notificationsLoading = true; notificationsError = ""; telegram.changed();
        }
        try {
            JSONArray messages = Json.array(telegram.request(Json.obj("@type", "getChatHistory", "chat_id", config.botUserID, "from_message_id", from, "offset", 0, "limit", 100, "only_local", false)), "messages");
            synchronized (this) {
                if (session != telegram.generation || !telegram.stage.equals("ready")) return;
                long oldest = Long.MAX_VALUE;
                for (int i=0;i<messages.length();i++) {
                    JSONObject value = messages.getJSONObject(i); message(value, false);
                    oldest = Math.min(oldest,value.optLong("id"));
                }
                if (from == 0 && !notifications.isEmpty()) considerBanner(notifications.get(0));
                if (oldest == Long.MAX_VALUE) oldest = 0;
                notificationsMore = oldest>noticeHistory.clearedThrough && oldest>0 && oldest!=from;
                notificationsCursor = oldest;
            }
        } catch (Exception ignored) { if (session==telegram.generation) notificationsError = "Could not load notifications. Please retry."; }
        finally { synchronized (this) { if (session==telegram.generation) { notificationsLoading = false; telegram.changed(); } } }
    }
    synchronized void deleted(JSONObject update) {
        if (config == null || update.optLong("chat_id")!=config.botUserID || !update.optBoolean("is_permanent")) return;
        JSONArray ids = Json.array(update,"message_ids");
        for (int i=0;i<ids.length();i++) {
            long id = ids.optLong(i); noticeHistory.remove(id);
            if (announcement != null && announcement.optLong("id")==id) announcement = null;
        }
        notifications = noticeHistory.ordered(); telegram.changed();
    }
    String media(JSONObject notice) {
        long session = telegram.generation;
        try {
            telegram.check(session);
            JSONObject file = Announcement.file(notice);
            if (Math.max(file.optLong("size"),file.optLong("expected_size")) > 20_000_000) return null;
            JSONObject result = telegram.request(Json.obj("@type", "downloadFile", "file_id", file.getInt("id"), "priority", 8, "synchronous", true));
            telegram.check(session);
            JSONObject local = Json.child(result, "local");
            String path = local.optString("path");
            return local.optBoolean("is_downloading_completed") && new java.io.File(path).length()<=20_000_000 ? path : null;
        } catch (Exception ignored) { return null; }
    }
    void join(String url) {
        if (config == null) return;
        boolean configured = false;
        for (int i=0;i<config.channels.length();i++) if (config.channels.optJSONObject(i).optString("url").equals(url)) configured = true;
        if (!configured) return;
        long session = telegram.generation;
        try {
            String path = AccessConfiguration.safeLink(url).getPath().substring(1);
            if (path.startsWith("+") || path.startsWith("joinchat/")) telegram.request(Json.obj("@type", "joinChatByInviteLink", "invite_link", url));
            else {
                JSONObject chat = telegram.request(Json.obj("@type", "searchPublicChat", "username", path));
                if (session != telegram.generation) return;
                telegram.request(Json.obj("@type", "joinChat", "chat_id", chat.getLong("id")));
            }
            if (session == telegram.generation) timer.postDelayed(() -> { if (session == telegram.generation) telegram.io.execute(() -> verify(true)); }, 2100);
        } catch (Exception e) { if (session == telegram.generation) { message = "Could not join. Open the channel link or try again."; telegram.changed(); } }
    }
}
