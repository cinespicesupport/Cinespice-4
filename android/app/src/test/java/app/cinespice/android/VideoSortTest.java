package app.cinespice.android;

import org.junit.Test;
import java.util.*;
import static org.junit.Assert.*;

public class VideoSortTest {
    private Video video(String name, long message) { return new Video(Json.obj("chatId", -1, "messageId", message, "name", name, "date", message)); }
    @Test public void rejectsEmbeddedAndAmbiguousYears() {
        assertEquals(Integer.valueOf(2024), VideoSort.year(video("Film.2024.1080p.mkv", 1)));
        assertEquals(Integer.valueOf(1880), VideoSort.year(video("Film (1880).mp4", 1)));
        for (String name : new String[]{"S02E2024.mp4", "film.12024p.mp4", "Film.1990.2024.mp4", "1879.mp4", "2100.mp4"}) assertNull(name, VideoSort.year(video(name, 1)));
    }
    @Test public void unknownYearsFollowKnownInBothDirectionsAndSortDoesNotMutateInput() {
        Video old = video("Old.1990.mp4", 1), recent = video("New.2024.mp4", 2), unknown = video("Unknown.mp4", 3);
        List<Video> original = List.of(unknown, recent, old);
        assertEquals(List.of(recent, old, unknown), VideoSort.sorted(original, 0));
        assertEquals(List.of(old, recent, unknown), VideoSort.sorted(original, 1));
        assertSame(unknown, original.get(0));
    }
    @Test public void dailyPickIsIndependentOfInputOrderingAndStableForUtcDay() {
        Video one = video("One.mp4", 1), two = video("Two.mp4", 2);
        assertSame(VideoSort.daily(List.of(one, two), 20000), VideoSort.daily(List.of(two, one), 20000));
        assertNull(VideoSort.daily(List.of(), 20000));
    }
}
