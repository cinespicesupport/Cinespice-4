package app.cinespice.android;
import org.junit.Test;
import static org.junit.Assert.*;

public class StreamReadPolicyTest {
    @Test public void deliversPartialCacheWithoutWaitingForOneMegabyte() {
        assertEquals(128 * 1024, StreamReadPolicy.readyCount(128 * 1024, 1024 * 1024));
        assertEquals(0, StreamReadPolicy.readyCount(1024, 1024 * 1024));
        assertEquals(0, StreamReadPolicy.readyCount(0, 1024 * 1024));
    }
    @Test public void boundsFinalReadAndInvalidInputs() {
        assertEquals(17, StreamReadPolicy.readyCount(Long.MAX_VALUE, 17));
        assertEquals(0, StreamReadPolicy.readyCount(16, 17));
        assertEquals(17, StreamReadPolicy.readyCount(17, 17));
        assertEquals(0, StreamReadPolicy.readyCount(-1, 17));
        assertEquals(0, StreamReadPolicy.readyCount(100, -1));
    }
    @Test public void partialReadsCoverResponseWithoutGaps() {
        int total = 2 * 1024 * 1024 + 17, position = 0, reads = 0;
        while (position < total) {
            int count = StreamReadPolicy.readyCount(Math.min(128 * 1024, total-position), Math.min(1024 * 1024, total-position));
            assertTrue(count > 0);
            position += count; reads++;
        }
        assertEquals(total, position); assertEquals(17, reads);
    }
}
