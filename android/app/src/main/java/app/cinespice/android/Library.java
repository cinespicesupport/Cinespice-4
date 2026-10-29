package app.cinespice.android;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.List;

final class Library {
    private final SQLiteDatabase db;
    final long accountId;
    Library(Context context, long accountId) {
        this.accountId = accountId;
        db = context.openOrCreateDatabase("library_" + accountId + ".db", Context.MODE_PRIVATE, null);
        db.execSQL("CREATE TABLE IF NOT EXISTS chats(id INTEGER PRIMARY KEY,title TEXT,owner INTEGER,date INTEGER,selected INTEGER DEFAULT 0)");
        db.execSQL("CREATE TABLE IF NOT EXISTS videos(id TEXT PRIMARY KEY,chat INTEGER,name TEXT,caption TEXT,date INTEGER,json TEXT)");
        db.execSQL("CREATE INDEX IF NOT EXISTS videos_chat_date ON videos(chat,date DESC)");
        db.execSQL("CREATE TABLE IF NOT EXISTS cursors(chat INTEGER,filter TEXT,cursor INTEGER,PRIMARY KEY(chat,filter))");
        db.execSQL("CREATE TABLE IF NOT EXISTS history(id TEXT PRIMARY KEY,position INTEGER,duration INTEGER,updated INTEGER,completed INTEGER)");
    }
    record Chat(long id, String title, boolean selected) {}
    synchronized void chat(long id, String title, boolean owner, long date) {
        ContentValues row = new ContentValues(); row.put("title", title); row.put("owner", owner ? 1 : 0); row.put("date", date);
        if (db.update("chats", row, "id=?", new String[]{"" + id}) == 0) {
            row.put("id", id); db.insertOrThrow("chats", null, row);
        }
    }
    synchronized List<Chat> chats(boolean selectedOnly) {
        List<Chat> result = new ArrayList<>();
        try (Cursor rows = db.rawQuery("SELECT id,title,selected FROM chats" + (selectedOnly ? " WHERE selected=1" : "") + " ORDER BY owner DESC,CASE WHEN date>0 THEN 0 ELSE 1 END,date,title COLLATE NOCASE", null)) {
            while (rows.moveToNext()) result.add(new Chat(rows.getLong(0), rows.getString(1), rows.getInt(2) == 1));
        }
        return result;
    }
    synchronized void select(long id, boolean selected) {
        ContentValues row = new ContentValues(); row.put("selected", selected ? 1 : 0); db.update("chats", row, "id=?", new String[]{"" + id});
    }
    synchronized long cursor(long chat, String filter) {
        try (Cursor rows = db.rawQuery("SELECT cursor FROM cursors WHERE chat=? AND filter=?", new String[]{"" + chat, filter})) {
            return rows.moveToFirst() ? rows.getLong(0) : 0;
        }
    }
    synchronized void page(long chat, String filter, long next, List<Video> videos, boolean saveCursor) {
        db.beginTransaction();
        try {
            for (Video video : videos) save(video);
            if (saveCursor) {
                ContentValues row = new ContentValues(); row.put("chat", chat); row.put("filter", filter); row.put("cursor", next == 0 ? -1 : next);
                db.insertWithOnConflict("cursors", null, row, SQLiteDatabase.CONFLICT_REPLACE);
            }
            db.setTransactionSuccessful();
        } finally { db.endTransaction(); }
    }
    synchronized void save(Video video) {
        ContentValues row = new ContentValues(); row.put("id", video.key()); row.put("chat", video.chatId);
        row.put("name", video.name); row.put("caption", video.caption); row.put("date", video.data.optLong("date")); row.put("json", video.data.toString());
        db.insertWithOnConflict("videos", null, row, SQLiteDatabase.CONFLICT_REPLACE);
    }
    synchronized List<Video> videos(long chat, String query, boolean historyOnly, int limit) {
        List<Video> result = new ArrayList<>();
        String sql = "SELECT v.json FROM videos v JOIN chats c ON c.id=v.chat LEFT JOIN history h ON h.id=v.id WHERE c.selected=1";
        List<String> args = new ArrayList<>();
        if (chat != 0) { sql += " AND v.chat=?"; args.add("" + chat); }
        if (!query.isEmpty()) { sql += " AND (instr(lower(v.name),lower(?))>0 OR instr(lower(v.caption),lower(?))>0)"; args.add(query); args.add(query); }
        if (historyOnly) sql += " AND h.position>=5000 AND h.completed=0";
        sql += " ORDER BY " + (historyOnly ? "h.updated DESC" : "v.date DESC") + " LIMIT " + Math.min(limit, 10000);
        try (Cursor rows = db.rawQuery(sql, args.toArray(new String[0]))) {
            while (rows.moveToNext()) {
                try { result.add(new Video(new JSONObject(rows.getString(0)))); }
                catch (org.json.JSONException ignored) { /* Discard an unreadable metadata row. */ }
            }
        }
        return result;
    }
    synchronized List<Video> recentHistory(int limit) {
        List<Video> result = new ArrayList<>();
        try (Cursor rows = db.rawQuery("SELECT v.json FROM videos v JOIN chats c ON c.id=v.chat JOIN history h ON h.id=v.id WHERE c.selected=1 ORDER BY h.updated DESC LIMIT ?", new String[]{"" + limit})) {
            while (rows.moveToNext()) try { result.add(new Video(new JSONObject(rows.getString(0)))); } catch (org.json.JSONException ignored) { }
        }
        return result;
    }
    synchronized long position(String id) {
        try (Cursor rows = db.rawQuery("SELECT position,completed FROM history WHERE id=?", new String[]{id})) {
            return rows.moveToFirst() && rows.getInt(1) == 0 ? rows.getLong(0) : 0;
        }
    }
    synchronized void progress(Video video, long position, long duration, boolean completed) {
        ContentValues row = new ContentValues(); row.put("id", video.key()); row.put("position", Math.max(0, position)); row.put("duration", duration);
        row.put("updated", System.currentTimeMillis()); row.put("completed", completed || (duration > 0 && (double) position / duration >= .95) ? 1 : 0);
        db.insertWithOnConflict("history", null, row, SQLiteDatabase.CONFLICT_REPLACE);
    }
    synchronized void removeHistory(String id) { db.delete("history", "id=?", new String[]{id}); }
    synchronized void clearHistory() { db.delete("history", null, null); }
}
