package app.cinespice.android;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.room.*;
import java.util.List;

/** Account-scoped durable lists and full-download intent, independent of the metadata cache. */
@Database(entities = {SavedStore.Member.class, SavedStore.Download.class}, version = 1, exportSchema = false)
public abstract class SavedStore extends RoomDatabase {
    @Entity(tableName = "members", primaryKeys = {"id", "list"})
    public static class Member {
        @NonNull public String id = "";
        @NonNull public String list = "";
        public Member(@NonNull String id, @NonNull String list) { this.id = id; this.list = list; }
    }
    @Entity(tableName = "downloads")
    public static class Download {
        @PrimaryKey @NonNull public String id = "";
        @NonNull public String state = "";
        public Download(@NonNull String id, @NonNull String state) { this.id = id; this.state = state; }
    }
    @Dao public interface Entries {
        @Query("SELECT id FROM members WHERE list=:list") List<String> members(String list);
        @Insert(onConflict = OnConflictStrategy.REPLACE) void put(Member member);
        @Query("DELETE FROM members WHERE id=:id AND list=:list") void remove(String id, String list);
        @Query("SELECT * FROM downloads") List<Download> downloads();
        @Insert(onConflict = OnConflictStrategy.REPLACE) void putDownload(Download item);
        @Query("UPDATE downloads SET state=:next WHERE id=:id AND state=:previous") int updateDownloadIfCurrent(String id, String previous, String next);
        @Query("DELETE FROM downloads") void clearDownloads();
    }
    public abstract Entries entries();
    static SavedStore open(Context context, long account) {
        // Tiny indexed preference tables. Metadata and network work stay in the existing repositories.
        return Room.databaseBuilder(context, SavedStore.class, "saved_" + account + ".db").allowMainThreadQueries().build();
    }
    static String id(Video video) { return video.chatId + ":" + video.messageId; }
}
