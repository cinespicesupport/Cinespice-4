package app.cinespice.android;

import android.graphics.*;
import android.util.LruCache;
import org.json.JSONObject;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;

final class Artwork {
    private final Telegram telegram;
    private final File directory;
    private final long session;
    private volatile long epoch;
    private final LruCache<String, Bitmap> memory = new LruCache<>(32 * 1024 * 1024) {
        @Override protected int sizeOf(String key, Bitmap value) { return value.getAllocationByteCount(); }
    };
    private final Set<String> pending = ConcurrentHashMap.newKeySet();
    private final ExecutorService workers = Executors.newFixedThreadPool(2);
    Artwork(Telegram telegram, File directory) {
        this.telegram = telegram; this.directory = directory; session = telegram.generation;
        if (!directory.isDirectory()) directory.mkdirs();
    }
    Bitmap cached(Video video) { return memory.get(video.key()); }
    void load(Video video, java.util.function.Consumer<Bitmap> complete) {
        String key = video.key();
        if (!pending.add(key)) return;
        long token = epoch;
        try {
            workers.execute(() -> {
                try {
                    telegram.check(session);
                    File file = new File(directory, key + ".image");
                    Bitmap bitmap = memory.get(key);
                    if (bitmap == null && file.isFile()) { bitmap = decode(file); file.setLastModified(System.currentTimeMillis()); }
                    if (bitmap == null) {
                        Video current = telegram.prepare(video);
                        if (current.thumbnailId == 0) return;
                        JSONObject status = telegram.request(Json.obj("@type", "getFile", "file_id", current.thumbnailId));
                        long size = status.optLong("size");
                        if (size <= 0 || size > 2 * 1024 * 1024) return;
                        JSONObject downloaded = telegram.request(Json.obj("@type", "downloadFile", "file_id", current.thumbnailId, "priority", 1, "offset", 0, "limit", 0, "synchronous", true));
                        telegram.check(session);
                        JSONObject local = Json.child(downloaded, "local");
                        if (!local.optBoolean("is_downloading_completed")) return;
                        File source = new File(local.optString("path"));
                        if (source.length() > 2 * 1024 * 1024) return;
                        synchronized (this) {
                            if (epoch != token) return;
                            try (InputStream input = new FileInputStream(source); OutputStream out = new FileOutputStream(file)) {
                                byte[] buffer = new byte[8192]; int n; while ((n = input.read(buffer)) != -1) out.write(buffer, 0, n);
                            }
                            bitmap = decode(file); prune();
                        }
                    }
                    telegram.check(session);
                    synchronized (this) { if (epoch != token || bitmap == null) return; memory.put(key, bitmap); }
                    complete.accept(bitmap);
                } catch (Exception ignored) { /* Embedded minithumbnail remains visible; retry on next render. */ }
                finally { pending.remove(key); }
            });
        } catch (RejectedExecutionException e) { pending.remove(key); }
    }
    private Bitmap decode(File file) {
        BitmapFactory.Options options = new BitmapFactory.Options(); options.inJustDecodeBounds = true; BitmapFactory.decodeFile(file.getAbsolutePath(), options);
        options.inSampleSize = 1; while (options.outWidth / options.inSampleSize > 512 || options.outHeight / options.inSampleSize > 512) options.inSampleSize *= 2;
        options.inJustDecodeBounds = false; return BitmapFactory.decodeFile(file.getAbsolutePath(), options);
    }
    private void prune() {
        File[] files = directory.listFiles(); if (files == null) return;
        Arrays.sort(files, Comparator.comparingLong(File::lastModified)); long size = 0; for (File file : files) size += file.length();
        for (File file : files) { if (size <= 40L * 1024 * 1024) break; long count = file.length(); if (file.delete()) size -= count; }
    }
    synchronized void clear() { epoch++; memory.evictAll(); File[] files = directory.listFiles(); if (files != null) for (File file : files) file.delete(); }
    synchronized void close() { epoch++; memory.evictAll(); workers.shutdownNow(); }
}
