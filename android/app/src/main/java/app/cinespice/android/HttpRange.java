package app.cinespice.android;

import java.util.List;

final class HttpRange {
    record Response(int code, long start, long length, boolean body, String contentRange) {}
    static Response resolve(String method, long size, List<String> ranges) {
        if (!method.equals("GET") && !method.equals("HEAD")) return new Response(405, 0, 0, false, "");
        if (size < 0) return new Response(400, 0, 0, false, "");
        if (method.equals("HEAD") || ranges.isEmpty()) return new Response(200, 0, size, method.equals("GET"), "");
        if (ranges.size() != 1 || !ranges.get(0).matches("bytes=([0-9]+-[0-9]*|-[0-9]+)")) return new Response(400, 0, 0, false, "");
        String[] parts = ranges.get(0).substring(6).split("-", -1);
        try {
            long start, end;
            if (parts[0].isEmpty()) {
                long suffix = Long.parseLong(parts[1]);
                if (suffix == 0 || size == 0) return unsatisfied(size);
                start = Math.max(0, size - suffix); end = size - 1;
            } else {
                start = Long.parseLong(parts[0]); end = parts[1].isEmpty() ? size - 1 : Long.parseLong(parts[1]);
                if (start >= size || end < start) return unsatisfied(size);
                end = Math.min(end, size - 1);
            }
            return new Response(206, start, end - start + 1, true, "bytes " + start + "-" + end + "/" + size);
        } catch (NumberFormatException e) { return new Response(400, 0, 0, false, ""); }
    }
    private static Response unsatisfied(long size) { return new Response(416, 0, 0, false, "bytes */" + size); }
}
