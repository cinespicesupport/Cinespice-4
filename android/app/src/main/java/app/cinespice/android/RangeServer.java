package app.cinespice.android;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

final class RangeServer implements AutoCloseable {
    private final ServerSocket server;
    private final ExecutorService workers = new ThreadPoolExecutor(4, 4, 0, TimeUnit.SECONDS, new SynchronousQueue<>());
    private final Set<Socket> clients = ConcurrentHashMap.newKeySet();
    private final String path = "/" + UUID.randomUUID() + "/video";
    private final Telegram telegram;
    private final Video video;
    private final long session;
    private volatile boolean closed;
    RangeServer(Telegram telegram, Video video) throws IOException {
        this.telegram = telegram; this.video = video; session = telegram.generation;
        server = new ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"));
        Thread acceptor = new Thread(() -> {
            while (!closed) {
                try {
                    Socket socket = server.accept(); clients.add(socket);
                    try { workers.execute(() -> serve(socket)); }
                    catch (RejectedExecutionException e) { clients.remove(socket); socket.close(); }
                } catch (IOException e) { if (!closed) close(); }
            }
        }, "telegram-range-server"); acceptor.setDaemon(true); acceptor.start();
    }
    String url() { return "http://127.0.0.1:" + server.getLocalPort() + path; }
    private void serve(Socket socket) {
        try (socket) {
            socket.setSoTimeout(10000);
            InputStream input = socket.getInputStream(); ByteArrayOutputStream header = new ByteArrayOutputStream();
            int tail = 0;
            while (header.size() < 16384) {
                int next = input.read(); if (next == -1) return;
                header.write(next); tail = (tail << 8) | next;
                if (tail == 0x0d0a0d0a) break;
            }
            if (tail != 0x0d0a0d0a) return;
            String[] lines = header.toString(StandardCharsets.US_ASCII.name()).split("\r\n");
            String[] first = lines[0].split(" ");
            List<String> ranges = new ArrayList<>(); boolean malformed = false;
            for (int i = 1; i < lines.length; i++) {
                int colon = lines[i].indexOf(':');
                if (colon < 1) { malformed = true; break; }
                if (lines[i].substring(0, colon).equalsIgnoreCase("Range")) ranges.add(lines[i].substring(colon + 1).trim());
            }
            HttpRange.Response response;
            if (malformed || first.length != 3 || !(first[2].equals("HTTP/1.0") || first[2].equals("HTTP/1.1"))) response = new HttpRange.Response(400, 0, 0, false, "");
            else if (!first[1].equals(path)) response = new HttpRange.Response(404, 0, 0, false, "");
            else response = HttpRange.resolve(first[0], video.size, ranges);
            String reason = switch (response.code()) { case 200 -> "OK"; case 206 -> "Partial Content"; case 404 -> "Not Found"; case 405 -> "Method Not Allowed"; case 416 -> "Range Not Satisfiable"; default -> "Bad Request"; };
            String mime = video.mime.matches("[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+") ? video.mime : "application/octet-stream";
            OutputStream out = new BufferedOutputStream(socket.getOutputStream(), 64 * 1024);
            String headers = "HTTP/1.1 " + response.code() + " " + reason + "\r\nContent-Type: " + mime + "\r\nAccept-Ranges: bytes\r\nContent-Length: " + response.length() + "\r\nConnection: close\r\n" +
                (response.contentRange().isEmpty() ? "" : "Content-Range: " + response.contentRange() + "\r\n") + (response.code() == 405 ? "Allow: GET, HEAD\r\n" : "") + "\r\n";
            out.write(headers.getBytes(StandardCharsets.US_ASCII)); out.flush();
            if (response.body()) {
                long offset = response.start(), remaining = response.length();
                while (remaining > 0 && !closed) {
                    int count = (int) Math.min(1024 * 1024, remaining);
                    byte[] bytes = telegram.read(video, offset, count, session);
                    if (bytes.length == 0 || bytes.length > count) throw new IOException("Invalid cache range");
                    out.write(bytes); out.flush(); offset += bytes.length; remaining -= bytes.length;
                }
            }
        } catch (Exception ignored) { /* VLC retries or reports a failed stream; sockets always close. */ }
        finally { clients.remove(socket); }
    }
    @Override public void close() {
        closed = true;
        try { server.close(); } catch (IOException ignored) { }
        for (Socket socket : clients) { try { socket.close(); } catch (IOException ignored) { } }
        workers.shutdownNow();
    }
}
