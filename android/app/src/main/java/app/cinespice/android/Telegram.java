package app.cinespice.android;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import io.github.up9cloud.td.JsonClient;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.RandomAccessFile;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

final class Telegram {
    static final String[] FILTERS = {"searchMessagesFilterVideo", "searchMessagesFilterDocument"};
    interface Listener { void changed(); }
    private final Context context;
    private final SecureStore secure;
    private final SessionLogout logout;
    private volatile CompletableFuture<Void> signOutCompletion;
    private boolean clientClosed;
    private final Handler main = new Handler(Looper.getMainLooper());
    final ExecutorService io = Executors.newFixedThreadPool(4);
    private final Map<Integer, CompletableFuture<JSONObject>> pending = new ConcurrentHashMap<>();
    private final Map<Integer, Object> fileLocks = new ConcurrentHashMap<>();
    final Map<Integer, JSONObject> files = new ConcurrentHashMap<>();
    private final Map<Integer, long[]> windows = new ConcurrentHashMap<>();
    final Set<Integer> downloads = ConcurrentHashMap.newKeySet();
    private final ExecutorService authQueue = Executors.newSingleThreadExecutor();
    private final AtomicInteger sequence = new AtomicInteger();
    private final CopyOnWriteArrayList<Listener> listeners = new CopyOnWriteArrayList<>();
    private volatile int client;
    private volatile String apiId, apiHash;
    volatile String stage = "credentials", error = "";
    volatile String displayName = "", username = "";
    final AccessController access;
    volatile Library library;
    volatile long generation;
    private final int[] discovered = {0, 0};
    private final boolean[] exhausted = {false, false};
    private int nextList;
    private final Set<Long> resolvedChats = ConcurrentHashMap.newKeySet();
    Telegram(Context context) {
        this.context = context; secure = new SecureStore(context); access = new AccessController(this, context);
        android.content.SharedPreferences session = context.getSharedPreferences("session", 0);
        logout = new SessionLogout(new SessionLogout.Storage() {
            public boolean isPending() { return session.getBoolean("sign-out-pending", false); }
            public void setPending(boolean pending) {
                if (!session.edit().putBoolean("sign-out-pending", pending).commit())
                    throw new IllegalStateException("Could not update sign-out status");
            }
            public void clearSession() throws Exception {
                SessionLogout.deleteSession(new File(context.getFilesDir(), "telegram"));
                secure.removeSession();
            }
        });
        io.execute(() -> {
            try {
                connectUsingBuildCredentials();
            } catch (Exception e) { fail("Could not restore credentials: " + e.getMessage()); }
        });
    }
    void connectUsingBuildCredentials() throws Exception {
        try (java.io.InputStream input = context.getAssets().open("telegram-build-credentials.json")) {
            java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
            byte[] buffer = new byte[1024]; int count;
            while ((count = input.read(buffer)) != -1) bytes.write(buffer, 0, count);
            JSONObject data = new JSONObject(bytes.toString("UTF-8"));
            connect(data.getString("apiID"), data.getString("apiHash"));
        }
    }
    void listen(Listener listener) { listeners.add(listener); }
    void unlisten(Listener listener) { listeners.remove(listener); }
    void changed() { main.post(() -> { for (Listener listener : listeners) listener.changed(); }); }
    void fail(String message) { error = message; changed(); }
    synchronized void connect(String id, String hash) throws Exception {
        if (!id.matches("[1-9][0-9]{0,9}") || Long.parseLong(id) > Integer.MAX_VALUE || !hash.matches("[a-fA-F0-9]{32}"))
            throw new IllegalArgumentException("This build has invalid sign-in configuration. Install a configured build.");
        secure.put("credentials", Json.obj("id", id, "hash", hash).toString());
        apiId = id; apiHash = hash; error = ""; stage = "loading"; changed();
        if (client == 0) {
            JsonClient.td_execute(Json.obj("@type", "setLogVerbosityLevel", "new_verbosity_level", 0).toString());
            client = JsonClient.td_create_client_id();
            Thread receiver = new Thread(this::receive, "tdlib-receiver"); receiver.setDaemon(true); receiver.start();
        }
        JSONObject state = request(Json.obj("@type", "getAuthorizationState"));
        authQueue.execute(() -> { try { if (lastAuth.isEmpty()) authorization(state); } catch (Exception e) { authFailed(e); } });
    }
    JSONObject request(JSONObject request) throws Exception {
        if (client == 0) throw new IllegalStateException("Connect your account first.");
        int id = sequence.incrementAndGet();
        CompletableFuture<JSONObject> result = new CompletableFuture<>(); pending.put(id, result);
        try {
            request.put("@extra", id);
            JsonClient.td_send(client, request.toString());
            return result.get(60, TimeUnit.SECONDS);
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof Exception exception) throw exception;
            throw new IllegalStateException(cause);
        } finally { pending.remove(id); }
    }
    private void receive() {
        while (true) {
            try {
                String text = JsonClient.td_receive(1);
                if (text == null) continue;
                JSONObject value = new JSONObject(text);
                if (value.optInt("@client_id", client) != client) continue;
                int id = value.optInt("@extra");
                CompletableFuture<JSONObject> result = pending.get(id);
                if (result != null) {
                    if (Json.type(value).equals("error")) result.completeExceptionally(new TelegramException(value.optInt("code"), value.optString("message")));
                    else result.complete(value);
                } else if (Json.type(value).equals("updateAuthorizationState")) {
                    JSONObject auth = Json.child(value, "authorization_state");
                    authQueue.execute(() -> { try { authorization(auth); } catch (Exception e) {
                        if (Json.type(auth).equals("authorizationStateWaitTdlibParameters")) { stage = "credentials"; lastAuth = ""; }
                        authFailed(e);
                    } });
                } else if (Json.type(value).equals("updateNewMessage")) {
                    access.message(Json.child(value, "message"));
                } else if (Json.type(value).equals("updateDeleteMessages")) {
                    access.deleted(value);
                } else if (Json.type(value).equals("updateFile")) {
                    JSONObject file = Json.child(value, "file"); files.put(file.optInt("id"), file);
                    if (Json.child(file, "local").optBoolean("is_downloading_completed")) downloads.remove(file.optInt("id"));
                }
            } catch (Exception e) { fail("Account connection: " + e.getMessage()); }
        }
    }
    private volatile String lastAuth = "";
    private synchronized void authorization(JSONObject auth) throws Exception {
        String type = Json.type(auth);
        if (type.equals(lastAuth)) return;
        lastAuth = type; error = "";
        if (logout.blocksAuthorization(type)) {
            clearAccount();
            changed();
            logout.request(() -> request(Json.obj("@type", "logOut")));
            return;
        }
        switch (type) {
            case "authorizationStateWaitTdlibParameters": {
                try {
                    stage = "loading"; changed();
                    String key = secure.get("database-key");
                    if (key == null) { byte[] bytes = new byte[32]; new SecureRandom().nextBytes(bytes); key = Base64.encodeToString(bytes, Base64.NO_WRAP); secure.put("database-key", key); }
                    File directory = new File(context.getFilesDir(), "telegram");
                    if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException("Could not create account storage");
                    request(Json.obj("@type", "setTdlibParameters", "database_directory", directory.getAbsolutePath(),
                        "files_directory", new File(directory, "files").getAbsolutePath(), "database_encryption_key", key,
                        "use_message_database", true, "use_chat_info_database", true, "use_file_database", true,
                        "use_secret_chats", false, "api_id", Integer.parseInt(apiId), "api_hash", apiHash,
                        "system_language_code", "en", "device_model", android.os.Build.MODEL,
                        "system_version", android.os.Build.VERSION.RELEASE, "application_version", "1.0"));
                } catch (Exception e) { stage = "credentials"; lastAuth = ""; throw e; }
                break;
            }
            case "authorizationStateWaitPhoneNumber": stage = "phone"; break;
            case "authorizationStateWaitCode": stage = "code"; break;
            case "authorizationStateWaitPassword": stage = "password"; break;
            case "authorizationStateWaitEmailAddress": stage = "email"; break;
            case "authorizationStateWaitEmailCode": stage = "emailCode"; break;
            case "authorizationStateReady": {
                JSONObject me = request(Json.obj("@type", "getMe"));
                long account = me.getLong("id");
                displayName = (me.optString("first_name") + " " + me.optString("last_name")).trim();
                org.json.JSONArray names = Json.array(Json.child(me, "usernames"), "active_usernames");
                username = names.length() > 0 ? names.optString(0) : "";
                library = new Library(context, account); generation++;
                resolvedChats.clear(); discovered[0] = discovered[1] = 0; exhausted[0] = exhausted[1] = false;
                stage = "activation"; access.reset(); access.restore(); break;
            }
            case "authorizationStateLoggingOut":
                access.forget(); clearAccount(); break;
            case "authorizationStateClosing":
                clearAccount(); break;
            case "authorizationStateClosed":
                clientClosed = true;
                clearAccount();
                finishClosedClient(); break;
            default: stage = "unsupported"; error = "This account requires a sign-in step that is not supported by this build.";
        }
        changed();
    }
    private void clearAccount() {
        access.reset(); generation++; stage = "loading"; library = null; displayName = ""; username = "";
        files.clear(); downloads.clear(); windows.clear(); resolvedChats.clear();
    }
    private void finishClosedClient() throws Exception {
        // Never delete a live TDLib database or announce success before cleanup.
        logout.closed();
        client = JsonClient.td_create_client_id(); clientClosed = false; lastAuth = "";
        error = ""; stage = "loading"; changed();
        CompletableFuture<Void> completion = signOutCompletion;
        if (completion != null) completion.complete(null);
        authorization(request(Json.obj("@type", "getAuthorizationState")));
    }
    private void authFailed(Exception error) {
        if (logout.isPending()) {
            stage = "signoutError";
            fail("Sign-out did not finish. Check your connection and retry.");
            CompletableFuture<Void> completion = signOutCompletion;
            if (completion != null) completion.completeExceptionally(error);
        } else fail(error.getMessage());
    }
    boolean isSigningOut() { return logout.isPending(); }
    void signOut() throws Exception {
        // Save intent before sending anything, so process death cannot restore Ready.
        CompletableFuture<Void> completion = new CompletableFuture<>();
        synchronized (this) {
            access.forget();
            logout.begin();
            signOutCompletion = completion;
            error = ""; clearAccount(); changed();
        }
        authQueue.execute(() -> {
            try {
                if (clientClosed) finishClosedClient();
                else if (lastAuth.isEmpty()) authorization(request(Json.obj("@type", "getAuthorizationState")));
                else logout.request(() -> request(Json.obj("@type", "logOut")));
            } catch (Exception e) { authFailed(e); }
        });
        try { completion.get(75, TimeUnit.SECONDS); }
        catch (Exception e) {
            if (logout.isPending()) authFailed(e);
            throw e;
        }
    }
    void authenticate(String value) throws Exception {
        if (logout.isPending()) throw new IllegalStateException("Finish signing out before signing in again.");
        JSONObject request = switch (stage) {
            case "phone" -> Json.obj("@type", "setAuthenticationPhoneNumber", "phone_number", value);
            case "code" -> Json.obj("@type", "checkAuthenticationCode", "code", value);
            case "password" -> Json.obj("@type", "checkAuthenticationPassword", "password", value);
            case "email" -> Json.obj("@type", "setAuthenticationEmailAddress", "email_address", value);
            case "emailCode" -> Json.obj("@type", "checkAuthenticationEmailCode", "code", Json.obj("@type", "emailAddressAuthenticationCode", "code", value));
            default -> throw new IllegalStateException("Wait for your account to finish connecting.");
        };
        try { request(request); }
        finally { request.remove("password"); request.remove("code"); }
    }
    void check(long session) throws InterruptedException {
        access.enforce();
        if (generation != session || !stage.equals("ready") || Thread.currentThread().isInterrupted()) throw new InterruptedException("Session changed or operation cancelled");
    }
    boolean discover() throws Exception {
        long session = generation; Library store = requireLibrary();
        if (exhausted[0] && exhausted[1]) return false;
        int list = exhausted[nextList] ? 1 - nextList : nextList;
        JSONObject chatList = Json.obj("@type", list == 0 ? "chatListMain" : "chatListArchive");
        boolean end = false;
        try { request(Json.obj("@type", "loadChats", "chat_list", chatList, "limit", 30)); }
        catch (TelegramException e) { if (e.code == 404) end = true; else throw e; }
        int limit = discovered[list] + 30;
        JSONArray ids = Json.array(request(Json.obj("@type", "getChats", "chat_list", chatList, "limit", limit)), "chat_ids");
        Set<Long> known = new java.util.HashSet<>(resolvedChats); for (Library.Chat chat : store.chats(false)) known.add(chat.id());
        int resolved = 0;
        for (int i = 0; i < ids.length(); i++) {
            check(session); long id = ids.getLong(i);
            if (!known.contains(id)) { resolveChat(id, store, session); resolvedChats.add(id); if (++resolved == 30) break; }
        }
        discovered[list] = limit;
        exhausted[list] = end && ids.length() < limit && resolved < 30;
        nextList = 1 - list;
        return !(exhausted[0] && exhausted[1]);
    }
    private boolean resolveChat(long id, Library store, long session) throws Exception {
        JSONObject chat = request(Json.obj("@type", "getChat", "chat_id", id));
        JSONObject type = Json.child(chat, "type"); String kind = Json.type(type);
        if (!kind.equals("chatTypeSupergroup") && !kind.equals("chatTypeBasicGroup")) return false;
        boolean supergroup = kind.equals("chatTypeSupergroup");
        JSONObject group = request(Json.obj("@type", supergroup ? "getSupergroup" : "getBasicGroup",
            supergroup ? "supergroup_id" : "basic_group_id", type.optLong(supergroup ? "supergroup_id" : "basic_group_id")));
        check(session);
        store.chat(id, chat.optString("title"), Json.type(Json.child(group, "status")).equals("chatMemberStatusCreator"), group.optLong("date"));
        return true;
    }
    Set<Long> searchChats(String query) throws Exception {
        Library store = requireLibrary(); long session = generation;
        Set<Long> candidates = new java.util.LinkedHashSet<>();
        for (String method : new String[]{"searchChatsOnServer", "searchChats"}) {
            JSONArray ids = Json.array(request(Json.obj("@type", method, "query", query, "limit", 30)), "chat_ids");
            for (int i = 0; i < ids.length(); i++) candidates.add(ids.getLong(i));
        }
        Set<Long> matches = new java.util.LinkedHashSet<>();
        for (long id : candidates) {
            check(session);
            if (resolveChat(id, store, session)) {
                matches.add(id);
                if (matches.size() >= 30) break;
            }
        }
        return matches;
    }
    Library requireLibrary() {
        access.enforce();
        Library result = library;
        if (result == null || !stage.equals("ready")) throw new IllegalStateException("Sign in first.");
        return result;
    }
    boolean page(long chat, boolean refresh) throws Exception {
        Library store = requireLibrary(); long session = generation;
        boolean more = false;
        for (String filter : FILTERS) {
            long previous = store.cursor(chat, filter);
            if (!refresh && previous == -1) continue;
            long cursor = refresh ? 0 : previous;
            JSONObject result = search(chat, "", filter, cursor);
            check(session);
            long next = result.optLong("next_from_message_id");
            if (next == cursor) next = 0;
            store.page(chat, filter, next, decode(result), !refresh || previous == 0);
            more |= store.cursor(chat, filter) != -1;
        }
        return more;
    }
    JSONObject search(long chat, String query, String filter, long cursor) throws Exception {
        return request(Json.obj("@type", "searchChatMessages", "chat_id", chat, "query", query, "from_message_id", cursor,
            "offset", 0, "limit", 30, "filter", Json.obj("@type", filter)));
    }
    static List<Video> decode(JSONObject result) throws Exception {
        List<Video> videos = new ArrayList<>(); JSONArray messages = Json.array(result, "messages");
        for (int i = 0; i < messages.length(); i++) { Video video = Video.fromMessage(messages.getJSONObject(i)); if (video != null) videos.add(video); }
        return videos;
    }
    Video prepare(Video saved) throws Exception {
        long session = generation; Library store = requireLibrary();
        JSONObject message = request(Json.obj("@type", "getMessage", "chat_id", saved.chatId, "message_id", saved.messageId)); check(session);
        Video current = Video.fromMessage(message);
        if (current == null) throw new IllegalStateException("This video is no longer available.");
        JSONObject content = Json.child(message, "content"); JSONObject media = Json.child(content, Json.type(content).equals("messageVideo") ? "video" : "document");
        JSONObject file = Json.child(media, Json.type(content).equals("messageVideo") ? "video" : "document");
        files.put(current.fileId, file); store.save(current);
        return current;
    }
    void download(Video saved) throws Exception {
        Video video = prepare(saved);
        windows.remove(video.fileId);
        downloads.add(video.fileId);
        try { files.put(video.fileId, request(Json.obj("@type", "downloadFile", "file_id", video.fileId, "priority", 32, "offset", 0, "limit", 0, "synchronous", false))); }
        catch (Exception e) { downloads.remove(video.fileId); throw e; }
    }
    void cancelDownload(Video saved) throws Exception {
        Video video = prepare(saved);
        request(Json.obj("@type", "cancelDownloadFile", "file_id", video.fileId, "only_if_pending", false)); downloads.remove(video.fileId); windows.remove(video.fileId);
    }
    String downloadStatus(Video video, String previous) throws Exception {
        long session = generation;
        JSONObject file = request(Json.obj("@type", "getFile", "file_id", video.fileId)); check(session);
        files.put(video.fileId, file);
        JSONObject local = Json.child(file, "local");
        String state = DownloadStatus.reconcile(previous, local.optBoolean("is_downloading_completed"),
            new File(local.optString("path")).isFile(), local.optBoolean("is_downloading_active"));
        return state;
    }
    String completedPath(Video video) {
        JSONObject file = files.get(video.fileId);
        if (file == null) return "";
        JSONObject local = Json.child(file, "local");
        String path = local.optString("path");
        return local.optBoolean("is_downloading_completed") && new File(path).isFile() ? path : "";
    }
    byte[] read(Video video, long offset, int count, long session) throws Exception {
        synchronized (fileLocks.computeIfAbsent(video.fileId, ignored -> new Object())) {
            check(session);
            String completed = completedPath(video);
            if (!completed.isEmpty()) {
                byte[] bytes = new byte[count];
                try (RandomAccessFile input = new RandomAccessFile(completed, "r")) { input.seek(offset); input.readFully(bytes); }
                return bytes;
            }
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(45);
            boolean requested = false;
            while (true) {
                check(session);
                JSONObject file = request(Json.obj("@type", "getFile", "file_id", video.fileId)); files.put(video.fileId, file);
                JSONObject local = Json.child(file, "local"); String path = local.optString("path");
                boolean complete = local.optBoolean("is_downloading_completed");
                long start = local.optLong("download_offset"), end = start + local.optLong("downloaded_prefix_size");
                long available = complete ? count : (offset >= start && offset < end ? end - offset : 0);
                if (!complete && available == 0) {
                    // Seeking may return to a cached segment outside the latest download window.
                    available = request(Json.obj("@type", "getFileDownloadedPrefixSize", "file_id", video.fileId, "offset", offset)).optLong("size");
                    check(session);
                }
                int ready = StreamReadPolicy.readyCount(available, count);
                if (ready > 0 && !path.isEmpty()) {
                    byte[] bytes = new byte[ready];
                    try (RandomAccessFile input = new RandomAccessFile(path, "r")) { input.seek(offset); input.readFully(bytes); }
                    return bytes;
                }
                if (downloads.contains(video.fileId)) throw new IllegalStateException("Download is in progress; wait until it finishes.");
                if (!requested) {
                    long[] window = windows.get(video.fileId);
                    if (window != null && offset >= window[0] && offset + count <= window[1] && local.optBoolean("is_downloading_active")) { requested = true; }
                    else {
                    long length = Math.min(8L * 1024 * 1024, video.size - offset);
                    request(Json.obj("@type", "downloadFile", "file_id", video.fileId, "priority", 32, "offset", offset,
                        "limit", length, "synchronous", false)); windows.put(video.fileId, new long[]{offset, offset + length}); requested = true;
                    }
                }
                if (System.nanoTime() > deadline) throw new java.net.SocketTimeoutException("Video streaming timed out. Try Download.");
                Thread.sleep(100);
            }
        }
    }
    void clearDownloads() throws Exception {
        request(Json.obj("@type", "optimizeStorage", "size", 0, "ttl", 0, "count", 0, "immunity_delay", 0,
            "file_types", new JSONArray().put(Json.obj("@type", "fileTypeVideo")).put(Json.obj("@type", "fileTypeDocument"))));
        files.clear(); downloads.clear();
    }
    static final class TelegramException extends Exception {
        final int code;
        TelegramException(int code, String message) { super(message); this.code = code; }
    }
}
