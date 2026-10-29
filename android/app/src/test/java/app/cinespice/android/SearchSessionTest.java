package app.cinespice.android;
import org.junit.Test;
import java.io.IOException;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
import static org.junit.Assert.*;

public class SearchSessionTest {
    @Test public void boundsWorkAndRotatesAcrossSources() throws Exception {
        List<Long> visited = new ArrayList<>();
        SearchSession search = new SearchSession(List.of(1L,2L,3L), "film", (chat,q,f,c) -> { visited.add(chat); assertEquals("film", q); return Json.obj("next_from_message_id", c + 100); }, (chat,videos) -> {});
        assertTrue(search.next()); assertEquals(List.of(1L,1L,2L,2L), visited);
        search.next(); assertEquals(List.of(1L,1L,2L,2L,3L,3L,1L,1L), visited);
    }
    @Test public void retainsFailedCursorAndEndsRepeatedOrZeroCursors() throws Exception {
        AtomicBoolean fail = new AtomicBoolean(true); List<Long> cursors = new ArrayList<>();
        SearchSession search = new SearchSession(List.of(1L), "film", (chat,q,f,c) -> {
            cursors.add(c); if (fail.getAndSet(false)) throw new IOException("offline");
            return Json.obj("next_from_message_id", 0);
        }, (chat,videos) -> {});
        try { search.next(); fail("Expected connection failure"); } catch (IOException expected) { }
        assertFalse(search.next()); assertEquals(List.of(0L,0L,0L), cursors);
        SearchSession repeated = new SearchSession(List.of(1L), "film", (chat,q,f,c) -> Json.obj("next_from_message_id", 10), (chat,v) -> {});
        assertTrue(repeated.next()); assertFalse(repeated.next());
    }
}
