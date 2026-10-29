package app.cinespice.android;
import org.junit.Test;
import java.util.List;
import static org.junit.Assert.*;

public class HttpRangeTest {
    @Test public void supportsSeekAndSuffixAndCapsToFileSize() {
        assertEquals(new HttpRange.Response(206, 30, 70, true, "bytes 30-99/100"), HttpRange.resolve("GET", 100, List.of("bytes=30-")));
        assertEquals(new HttpRange.Response(206, 90, 10, true, "bytes 90-99/100"), HttpRange.resolve("GET", 100, List.of("bytes=-10")));
        assertEquals(100, HttpRange.resolve("GET", 100, List.of("bytes=0-99999")).length());
    }
    @Test public void headIgnoresRangeAndHasNoBody() {
        assertEquals(new HttpRange.Response(200, 0, 100, false, ""), HttpRange.resolve("HEAD", 100, List.of("bytes=80-90")));
    }
    @Test public void rejectsInvalidRangesAndMethods() {
        for (String range : List.of("bytes=0-1,4-5", "bytes=abc-", "bytes=--1", "bytes=9223372036854775808-", "items=0-3")) assertEquals(400, HttpRange.resolve("GET", 100, List.of(range)).code());
        assertEquals(400, HttpRange.resolve("GET", 100, List.of("bytes=0-1", "bytes=2-3")).code());
        assertEquals(405, HttpRange.resolve("POST", 100, List.of()).code());
        assertEquals(416, HttpRange.resolve("GET", 100, List.of("bytes=100-")).code());
        assertEquals(416, HttpRange.resolve("GET", 100, List.of("bytes=9-4")).code());
        assertEquals(416, HttpRange.resolve("GET", 0, List.of("bytes=-1")).code());
        assertEquals("bytes */100", HttpRange.resolve("GET", 100, List.of("bytes=-0")).contentRange());
    }
    @Test public void permitsFullAndZeroByteResponses() {
        assertEquals(new HttpRange.Response(200, 0, 42, true, ""), HttpRange.resolve("GET", 42, List.of()));
        assertEquals(0, HttpRange.resolve("GET", 0, List.of()).length());
    }
}
