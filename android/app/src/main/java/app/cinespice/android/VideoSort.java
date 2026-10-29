package app.cinespice.android;

import java.util.*;
import java.util.regex.*;

final class VideoSort {
    static final String[] LABELS = {"Latest releases", "Earliest releases", "Title A–Z", "Title Z–A", "Recently added", "Oldest uploads"};
    private static final Pattern YEAR = Pattern.compile("(?<![\\p{L}\\p{N}])(?:18[89][0-9]|19[0-9]{2}|20[0-9]{2})(?![\\p{L}\\p{N}])");
    static Integer year(Video video) {
        Matcher matcher = YEAR.matcher(video.name); Integer year = null;
        while (matcher.find()) { if (year != null) return null; year = Integer.valueOf(matcher.group()); }
        return year;
    }
    static List<Video> sorted(List<Video> videos, int order) {
        List<Video> result = new ArrayList<>(videos);
        Comparator<Video> newest = Comparator.<Video>comparingLong(v -> v.data.optLong("date")).reversed();
        Comparator<Video> stable = newest.thenComparingLong(v -> v.chatId).thenComparingLong(v -> v.messageId);
        Comparator<Video> comparator;
        if (order == 0 || order == 1) comparator = (a, b) -> {
            Integer ay = year(a), by = year(b);
            if (ay == null || by == null) return ay == by ? 0 : ay == null ? 1 : -1;
            return order == 0 ? by.compareTo(ay) : ay.compareTo(by);
        };
        else if (order == 2 || order == 3) {
            comparator = Comparator.comparing(v -> v.displayTitle.toLowerCase(Locale.ROOT)); if (order == 3) comparator = comparator.reversed();
        } else comparator = order == 5 ? Comparator.comparingLong(v -> v.data.optLong("date")) : newest;
        result.sort(comparator.thenComparing(stable)); return result;
    }
    static Video daily(List<Video> videos, long utcDay) {
        if (videos.isEmpty()) return null;
        List<Video> ordered = new ArrayList<>(videos); ordered.sort(Comparator.comparing(Video::key));
        return ordered.get(Math.floorMod(Long.hashCode(utcDay), ordered.size()));
    }
}
