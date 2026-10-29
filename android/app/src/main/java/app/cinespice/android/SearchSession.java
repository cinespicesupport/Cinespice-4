package app.cinespice.android;

import org.json.JSONObject;
import java.util.*;

final class SearchSession {
    interface Request { JSONObject search(long chat, String query, String filter, long cursor) throws Exception; }
    interface Save { void save(long chat, List<Video> videos) throws Exception; }
    private record Job(long chat, String filter, long cursor) {}
    final Map<String, Video> results = new LinkedHashMap<>();
    private final ArrayDeque<Job> jobs = new ArrayDeque<>();
    private final String query;
    private final Request request;
    private final Save save;
    SearchSession(Telegram telegram, List<Library.Chat> chats, String query) {
        this(chats.stream().map(Library.Chat::id).collect(java.util.stream.Collectors.toList()), query, telegram::search, saver(telegram));
    }
    private static Save saver(Telegram telegram) {
        long session = telegram.generation; Library store = telegram.requireLibrary();
        return (chat, videos) -> { telegram.check(session); store.page(chat, "", 0, videos, false); };
    }
    SearchSession(List<Long> chats, String query, Request request, Save save) {
        this.query = query; this.request = request; this.save = save;
        for (long chat : chats) for (String filter : Telegram.FILTERS) jobs.add(new Job(chat, filter, 0));
    }
    boolean next() throws Exception {
        int count = Math.min(4, jobs.size());
        for (int i = 0; i < count; i++) {
            Job job = jobs.element();
            JSONObject result = request.search(job.chat(), query, job.filter(), job.cursor());
            List<Video> videos = Telegram.decode(result);
            save.save(job.chat(), videos);
            for (Video video : videos) results.put(video.key(), video);
            long next = result.optLong("next_from_message_id");
            jobs.remove(); if (next != 0 && next != job.cursor()) jobs.add(new Job(job.chat(), job.filter(), next));
        }
        return !jobs.isEmpty();
    }
}
