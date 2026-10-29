package app.cinespice.android;

import android.app.*;
import android.content.*;
import android.content.pm.ActivityInfo;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.*;
import android.provider.OpenableColumns;
import android.view.*;
import android.widget.*;
import org.json.JSONObject;
import org.videolan.libvlc.*;
import org.videolan.libvlc.interfaces.IMedia;
import org.videolan.libvlc.util.VLCVideoLayout;
import java.io.*;
import java.util.*;

public final class PlayerActivity extends androidx.appcompat.app.AppCompatActivity {
    private final java.util.concurrent.ExecutorService progressWriter = java.util.concurrent.Executors.newSingleThreadExecutor();
    private Telegram telegram;
    private Library library;
    private Video video;
    private LibVLC vlc;
    private MediaPlayer player;
    private RangeServer bridge;
    private FrameLayout root;
    private LinearLayout controls;
    private FrameLayout optionsOverlay;
    private int pictureChoice;
    private TextView message, time, remaining;
    private ProgressBar spinner;
    private SeekBar seek;
    private ImageButton play;
    private Button unlock;
    private LinearLayout recoveryActions;
    private final PlaybackRecovery recovery = new PlaybackRecovery();
    private boolean userPaused, playbackEnded;
    private VLCVideoLayout videoSurface;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private volatile boolean released;
    private boolean locked, dragging, positioned, playbackError, resumeAfterPause, foreground, landscape, edges;
    private long initialPosition, lastTime = -1, lastMovement, lastSaved, openingStarted;
    private long session;
    private int importType;
    private final List<File> externalFiles = new ArrayList<>();
    private final Runnable hide = () -> { if (!released && optionsOverlay == null && !playbackError && recovery.failedTarget == null && player != null && player.isPlaying()) controls.setVisibility(View.GONE); };
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (released || player == null) return;
            telegram.access.enforce();
            if (telegram.generation != session || !telegram.stage.equals("ready")) { finish(); return; }
            long position = player.getTime(), duration = player.getLength();
            if (!positioned && SystemClock.elapsedRealtime() - openingStarted > 45000) showPlaybackError();
            PlaybackRecovery.Result recoveryResult = recovery.poll(position, SystemClock.elapsedRealtime());
            if (recoveryResult == PlaybackRecovery.Result.TIMED_OUT) {
                userPaused = true; resumeAfterPause = false; player.pause();
                locked = false; unlock.setVisibility(View.GONE); recoveryActions.setVisibility(View.VISIBLE);
                controls.setVisibility(View.VISIBLE); handler.removeCallbacks(hide);
                message.setText(R.string.playback_position_unavailable);
            } else if (recoveryResult == PlaybackRecovery.Result.REACHED) recoveryActions.setVisibility(View.GONE);
            if (positioned && player.isSeekable() && duration > 0) {
                Long target = recovery.issue(duration); if (target != null) player.setTime(target);
            }
            if (!dragging) seek.setProgress(duration > 0 ? (int) (position * 1000 / duration) : 0);
            seek.setEnabled(player.isSeekable());
            time.setText(timelineTime(position));
            remaining.setText(getString(R.string.playback_remaining_time, timelineTime(Math.max(0, duration - position))));
            updatePlayIcon();
            if (position != lastTime) { lastMovement = SystemClock.elapsedRealtime(); lastTime = position; }
            boolean stalled = player.isPlaying() && SystemClock.elapsedRealtime() - lastMovement >= 2000;
            spinner.setVisibility(!playbackError && (!positioned || stalled) ? View.VISIBLE : View.GONE);
            if (positioned && !playbackError && recovery.failedTarget == null) message.setText(stalled ? "Buffering…" : "");
            if (SystemClock.elapsedRealtime() - lastSaved >= 5000) save();
            handler.postDelayed(this, 500);
        }
    };
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        telegram = ((CinespiceApp) getApplication()).telegram;
        session = getIntent().getLongExtra("generation", -1);
        try {
            telegram.check(session); library = telegram.requireLibrary();
            video = new Video(new JSONObject(Objects.requireNonNull(getIntent().getStringExtra("video"))));
            initialPosition = state != null ? state.getLong("position") : getIntent().getBooleanExtra("resume", true) ? library.position(video.key()) : 0;
            if (initialPosition >= 5000) recovery.begin(initialPosition, SystemClock.elapsedRealtime());
            landscape = state != null && state.getBoolean("landscape");
            setRequestedOrientation(landscape ? ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE : ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            layout(); start();
        } catch (Exception | LinkageError e) {
            new AlertDialog.Builder(this).setTitle("Could not open video").setMessage(e.getMessage()).setPositiveButton("Back", (d, w) -> finish()).setOnCancelListener(d -> finish()).show();
        }
    }
    private void layout() {
        root = new FrameLayout(this); root.setBackgroundColor(android.graphics.Color.BLACK); setContentView(root);
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            v.setPadding(edges ? 0 : insets.getSystemWindowInsetLeft(), edges ? 0 : insets.getSystemWindowInsetTop(), edges ? 0 : insets.getSystemWindowInsetRight(), edges ? 0 : insets.getSystemWindowInsetBottom());
            if (controls != null) controls.setPadding(edges ? insets.getSystemWindowInsetLeft() : 0, edges ? insets.getSystemWindowInsetTop() : 0, edges ? insets.getSystemWindowInsetRight() : 0, edges ? insets.getSystemWindowInsetBottom() : 0);
            return insets.consumeSystemWindowInsets();
        }); root.requestApplyInsets();
        controls = Ui.column(this); controls.setPadding(0, 0, 0, 0); controls.setBackgroundColor(android.graphics.Color.TRANSPARENT);
        LinearLayout top = Ui.row(this); top.setPadding(Ui.dp(this, 10), Ui.dp(this, 4), Ui.dp(this, 10), Ui.dp(this, 4)); top.setBackground(new GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, new int[]{0xD9000000, 0xA6000000, 0x00000000}));
        top.addView(playerIcon("⌄", "Close player", 22, this::finish));
        LinearLayout title = Ui.column(this); title.setPadding(Ui.dp(this, 4), 0, 0, 0);
        TextView name = Ui.text(this, video.displayTitle, 14, Ui.TEXT); name.setTypeface(android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)); name.setMaxLines(1); name.setEllipsize(android.text.TextUtils.TruncateAt.END); name.setPadding(0, 0, 0, 0); title.addView(name);
        top.addView(title, new LinearLayout.LayoutParams(0, -2, 1));
        top.addView(playerIcon("rotate", "Rotate screen", 20, () -> { landscape = !landscape; setRequestedOrientation(landscape ? ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE : ActivityInfo.SCREEN_ORIENTATION_PORTRAIT); reveal(); }));
        controls.addView(top, new LinearLayout.LayoutParams(-1, -2));
        LinearLayout spacer = new LinearLayout(this); controls.addView(spacer, new LinearLayout.LayoutParams(-1, 0, 1));
        LinearLayout bottom = Ui.column(this); bottom.setPadding(Ui.dp(this, 12), Ui.dp(this, 22), Ui.dp(this, 12), Ui.dp(this, 8)); bottom.setBackground(new GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP, new int[]{0xF0000000, 0xD9000000, 0x00000000}));
        LinearLayout status = Ui.row(this); status.setPadding(0, 0, 0, Ui.dp(this, 2));
        spinner = new ProgressBar(this); spinner.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(Ui.accent(this))); status.addView(spinner, new LinearLayout.LayoutParams(Ui.dp(this, 16), Ui.dp(this, 16)));
        message = Ui.text(this, "Opening media…", 11, Ui.accent(this)); message.setPadding(Ui.dp(this, 7), 0, 0, 0); status.addView(message, new LinearLayout.LayoutParams(0, -2, 1)); bottom.addView(status);
        recoveryActions = Ui.row(this); recoveryActions.setVisibility(View.GONE);
        Ui.weighted(recoveryActions, Ui.button(this, "Retry position", () -> { if (recovery.failedTarget != null) recover(recovery.failedTarget); }));
        Ui.weighted(recoveryActions, Ui.button(this, "Start over", () -> recover(0)));
        bottom.addView(recoveryActions);
        LinearLayout timeline = Ui.row(this); time = Ui.text(this, "0:00", 11, 0xFFEAE6E3); time.setTypeface(android.graphics.Typeface.MONOSPACE); time.setPadding(0, 0, Ui.dp(this, 8), 0); timeline.addView(time);
        seek = new SeekBar(this); seek.setProgressTintList(android.content.res.ColorStateList.valueOf(Ui.accent(this))); seek.setThumbTintList(android.content.res.ColorStateList.valueOf(Ui.accent(this))); seek.setMax(1000); seek.setContentDescription("Video timeline"); timeline.addView(seek, new LinearLayout.LayoutParams(0, Ui.dp(this, 34), 1));
        remaining = Ui.text(this, "−0:00", 11, 0xFFEAE6E3); remaining.setTypeface(android.graphics.Typeface.MONOSPACE); remaining.setGravity(Gravity.END); remaining.setPadding(Ui.dp(this, 8), 0, 0, 0); timeline.addView(remaining); bottom.addView(timeline);
        seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            public void onStartTrackingTouch(SeekBar bar) { dragging = true; handler.removeCallbacks(hide); }
            public void onStopTrackingTouch(SeekBar bar) { if (player != null && player.isSeekable()) requestSeek(player.getLength() * bar.getProgress() / 1000); dragging = false; reveal(); }
            public void onProgressChanged(SeekBar bar, int progress, boolean user) { if (user && player != null) { long pos = player.getLength() * progress / 1000; time.setText(timelineTime(pos)); remaining.setText(getString(R.string.playback_remaining_time, timelineTime(Math.max(0, player.getLength() - pos)))); } }
        });
        HorizontalScrollView strip = new HorizontalScrollView(this); strip.setHorizontalScrollBarEnabled(false); strip.setFillViewport(true);
        LinearLayout transport = Ui.row(this); transport.setGravity(Gravity.CENTER); transport.setMinimumWidth(Ui.dp(this, 360));
        transport.addView(playerIcon("lock", "Lock controls", 20, () -> { locked = true; controls.setVisibility(View.GONE); unlock.setVisibility(View.VISIBLE); }), controlSlot());
        transport.addView(playerIcon("captions", "Audio and subtitles", 20, () -> tracks(true)), controlSlot());
        transport.addView(playerIcon("back", "Back ten seconds", 22, () -> skip(-10000)), controlSlot());
        play = playerIcon("pause", "Pause", 20, () -> { if (player != null) { if (!userPaused && !playbackError) { userPaused = true; player.pause(); save(); } else if (recovery.failedTarget != null) recover(recovery.failedTarget); else { userPaused = false; player.play(); } updatePlayIcon(); reveal(); } });
        GradientDrawable pill = new GradientDrawable(); pill.setColor(Ui.action(this)); pill.setCornerRadius(Ui.dp(this, 24));
        play.setSelected(true); play.setBackground(pill); play.setImageTintList(android.content.res.ColorStateList.valueOf(Ui.onAction(this)));
        transport.addView(play, new LinearLayout.LayoutParams(Ui.dp(this, 72), Ui.dp(this, 48)));
        transport.addView(playerIcon("forward", "Forward ten seconds", 22, () -> skip(10000)), controlSlot());
        transport.addView(playerIcon("picture", "Picture options", 20, this::picture), controlSlot());
        transport.addView(playerIcon("more", "More options", 20, () -> options("More", new String[]{"Playback speed", "Audio tracks", "Subtitles", "Download"}, -1, index -> {
            if (index == 0) { speed(); return; }
            if (index == 1) { tracks(false); return; }
            if (index == 2) { tracks(true); return; }
            if (player != null) { userPaused = true; player.pause(); }
            if (bridge != null) { bridge.close(); bridge = null; }
            save();
            telegram.io.execute(() -> {
                SavedStore saved = null;
                try {
                    telegram.check(session);
                    saved = SavedStore.open(getApplicationContext(), library.accountId);
                    saved.entries().putDownload(new SavedStore.Download(SavedStore.id(video), "Preparing"));
                    telegram.download(video); telegram.check(session);
                    saved.entries().putDownload(new SavedStore.Download(SavedStore.id(video), "Downloading"));
                    runOnUiThread(() -> { if (!released) { Toast.makeText(this, R.string.download_reopen, Toast.LENGTH_LONG).show(); finish(); } });
                } catch (Exception e) {
                    if (session == telegram.generation && saved != null) saved.entries().putDownload(new SavedStore.Download(SavedStore.id(video), "Retry download"));
                    runOnUiThread(() -> { if (!released) { playbackError = true; message.setText(R.string.download_retry); reveal(); } });
                } finally { if (saved != null) saved.close(); }
            });
        })), controlSlot());
        strip.addView(transport, new HorizontalScrollView.LayoutParams(-1, -2)); bottom.addView(strip);
        controls.addView(bottom, new LinearLayout.LayoutParams(-1, -2));
        unlock = Ui.primary(this, "Unlock", () -> { locked = false; unlock.setVisibility(View.GONE); reveal(); }); unlock.setVisibility(View.GONE);
    }
    private LinearLayout.LayoutParams controlSlot() { return new LinearLayout.LayoutParams(0, Ui.dp(this, 48), 1); }
    private ImageButton playerIcon(String glyph, String description, int size, Runnable action) {
        ImageButton button = new androidx.appcompat.widget.AppCompatImageButton(this);
        int resource = switch (glyph) {
            case "pause" -> R.drawable.ic_player_pause; case "back" -> R.drawable.ic_player_back;
            case "forward" -> R.drawable.ic_player_forward; case "captions" -> R.drawable.ic_player_captions;
            case "lock" -> R.drawable.ic_player_lock; case "rotate" -> R.drawable.ic_player_rotate;
            case "picture" -> R.drawable.ic_player_picture; case "more" -> R.drawable.ic_player_more;
            default -> R.drawable.ic_player_close;
        };
        button.setImageResource(resource); button.setImageTintList(android.content.res.ColorStateList.valueOf(Ui.TEXT));
        button.setBackgroundColor(android.graphics.Color.TRANSPARENT); button.setPadding(Ui.dp(this, 12), Ui.dp(this, 12), Ui.dp(this, 12), Ui.dp(this, 12));
        button.setMinimumWidth(Ui.dp(this, 48)); button.setMinimumHeight(Ui.dp(this, 48)); button.setContentDescription(description);
        button.setOnClickListener(v -> { action.run(); reveal(); }); return button;
    }
    private void updatePlayIcon() {
        boolean playing = player != null && !userPaused && !playbackError;
        if (play.isSelected() != playing) { play.setSelected(playing); play.setImageResource(playing ? R.drawable.ic_player_pause : R.drawable.ic_player_play); }
        play.setContentDescription(playing ? "Pause" : "Play");
    }
    private String timelineTime(long milliseconds) { long seconds = Math.max(0, milliseconds / 1000); return seconds >= 3600 ? String.format(Locale.ROOT, "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String.format(Locale.ROOT, "%d:%02d", seconds / 60, seconds % 60); }
    private static final class PlayerGestureView extends View {
        GestureDetector detector;
        PlayerGestureView(Context context) { super(context); }
        // GestureDetector confirms single taps asynchronously; its callback invokes performClick().
        // Calling it on ACTION_UP here would also toggle controls during a double-tap seek.
        @android.annotation.SuppressLint("ClickableViewAccessibility")
        @Override public boolean onTouchEvent(MotionEvent event) {
            return (detector != null && detector.onTouchEvent(event)) || super.onTouchEvent(event);
        }
        @Override public boolean performClick() { return super.performClick(); }
    }

    private void start() throws Exception {
        ArrayList<String> options = new ArrayList<>(List.of("--network-caching=1500", "--no-video-title-show", "--freetype-rel-fontsize=" + getPreferences(0).getInt("subtitleSize", 16)));
        vlc = new LibVLC(this, options); player = new MediaPlayer(vlc);
        videoSurface = new VLCVideoLayout(this); root.addView(videoSurface, 0, new FrameLayout.LayoutParams(-1, -1));
        player.attachViews(videoSurface, null, true, false);
        PlayerGestureView gestures = new PlayerGestureView(this); root.addView(gestures, new FrameLayout.LayoutParams(-1, -1));
        GestureDetector detector = new GestureDetector(this, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onDown(MotionEvent event) { return true; }
            @Override public boolean onSingleTapConfirmed(MotionEvent event) { gestures.performClick(); return true; }
            @Override public boolean onDoubleTap(MotionEvent event) { if (!locked) skip(event.getX() < root.getWidth() / 2f ? -10000 : 10000); return true; }
        });
        gestures.setContentDescription("Show or hide player controls");
        gestures.setOnClickListener(v -> { if (!locked) { if (controls.getVisibility() == View.VISIBLE) controls.setVisibility(View.GONE); else reveal(); } });
        gestures.detector = detector;
        root.addView(controls, new FrameLayout.LayoutParams(-1, -1));
        FrameLayout.LayoutParams corner = new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.END); root.addView(unlock, corner);
        String local = telegram.completedPath(video);
        Uri uri;
        if (!local.isEmpty()) uri = Uri.fromFile(new File(local));
        else { if (video.size <= 0) throw new IOException("Video size is unknown. Download, then try again."); bridge = new RangeServer(telegram, video); uri = Uri.parse(bridge.url()); }
        Media media = new Media(vlc, uri); media.setHWDecoderEnabled(true, false); media.addOption(":network-caching=1500");
        player.setMedia(media); media.release();
        openingStarted = lastMovement = SystemClock.elapsedRealtime();
        player.setEventListener(event -> {
            if (released) return;
            if (event.type == MediaPlayer.Event.Playing) {
                if (!positioned) positioned = true;
                playbackError = false; playbackEnded = false;
                if (!foreground) { resumeAfterPause = !userPaused && recovery.failedTarget == null; player.pause(); }
                message.setText(""); reveal();
            } else if (event.type == MediaPlayer.Event.EncounteredError) {
                showPlaybackError();
            } else if (event.type == MediaPlayer.Event.EndReached) {
                if (!positioned || player.getLength() <= 0) { showPlaybackError(); return; }
                if (!recovery.protectsProgress()) { Library target = library; Video mediaVideo = video; long end = Math.max(0, player.getLength()); progressWriter.execute(() -> target.progress(mediaVideo, end, end, true)); }
                playbackEnded = true; userPaused = true; controls.setVisibility(View.VISIBLE); handler.removeCallbacks(hide);
            }
        });
        player.play(); handler.post(tick); reveal();
    }
    private void showPlaybackError() {
        spinner.setVisibility(View.GONE); positioned = true; playbackError = true; userPaused = true; locked = false; unlock.setVisibility(View.GONE);
        message.setText(R.string.playback_failed); controls.setVisibility(View.VISIBLE); handler.removeCallbacks(hide);
    }
    private void reveal() { if (locked) return; controls.setVisibility(View.VISIBLE); handler.removeCallbacks(hide); handler.postDelayed(hide, 4500); }
    private void skip(long delta) { if (player != null && player.isSeekable()) { requestSeek(Math.max(0, Math.min(player.getLength(), player.getTime() + delta))); reveal(); } }
    private void requestSeek(long position) {
        recovery.begin(position, SystemClock.elapsedRealtime()); recoveryActions.setVisibility(View.GONE);
        Long target = recovery.issue(player.getLength()); if (target != null) player.setTime(target);
    }
    private void recover(long position) {
        recovery.begin(position, SystemClock.elapsedRealtime()); recoveryActions.setVisibility(View.GONE);
        userPaused = false; message.setText(R.string.playback_seeking); player.play(); reveal();
    }
    private void save() {
        if (player != null && positioned && !playbackError && !playbackEnded && !recovery.protectsProgress() && player.getTime() >= 0 && library != null && !progressWriter.isShutdown()) {
            long position = player.getTime(), duration = player.getLength();
            Library target = library; Video media = video;
            progressWriter.execute(() -> target.progress(media, position, duration, false));
        }
        lastSaved = SystemClock.elapsedRealtime();
    }
    private void tracks(boolean subtitles) {
        if (player == null) return;
        handler.removeCallbacks(hide);
        MediaPlayer.TrackDescription[] tracks = subtitles ? player.getSpuTracks() : player.getAudioTracks();
        ArrayList<String> names = new ArrayList<>(); ArrayList<Integer> ids = new ArrayList<>();
        if (subtitles) { names.add("Off"); ids.add(-1); }
        if (tracks != null) for (MediaPlayer.TrackDescription track : tracks) { if (subtitles && track.id == -1) continue; names.add(track.name); ids.add(track.id); }
        names.add("Add external " + (subtitles ? "subtitles" : "audio") + "…"); names.add("Adjust delay…"); if (subtitles) names.add("Subtitle size…");
        int selected = ids.indexOf(subtitles ? player.getSpuTrack() : player.getAudioTrack());
        options(subtitles ? "Subtitles" : "Audio tracks", names.toArray(new String[0]), selected, index -> {
            if (index < ids.size()) { if (subtitles) player.setSpuTrack(ids.get(index)); else player.setAudioTrack(ids.get(index)); tracks(subtitles); }
            else if (index == ids.size()) { importType = subtitles ? IMedia.Slave.Type.Subtitle : IMedia.Slave.Type.Audio; startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE), 200); }
            else if (index == ids.size() + 1) delay(subtitles);
            else subtitleSize();
        });
    }
    private void delay(boolean subtitles) {
        LinearLayout panel = Ui.column(this); TextView label = Ui.text(this, "", 18, Ui.TEXT); panel.addView(label);
        Runnable update = () -> label.setText(String.format(Locale.ROOT, "Delay: %.2f seconds", (subtitles ? player.getSpuDelay() : player.getAudioDelay()) / 1000000.0)); update.run();
        LinearLayout buttons = Ui.row(this);
        for (int direction : new int[]{-1, 1}) Ui.weighted(buttons, Ui.button(this, direction < 0 ? "−0.25s" : "+0.25s", () -> {
            long value = Math.max(-30000000, Math.min(30000000, (subtitles ? player.getSpuDelay() : player.getAudioDelay()) + direction * 250000L));
            boolean changed = subtitles ? player.setSpuDelay(value) : player.setAudioDelay(value);
            if (!changed) Toast.makeText(this, "The player could not change this delay.", Toast.LENGTH_SHORT).show(); update.run();
        })); panel.addView(buttons);
        panel(subtitles ? "Subtitle delay" : "Audio delay", panel);
    }
    private void subtitleSize() {
        String[] names = {"Smallest", "Small", "Normal", "Large", "Largest"}; int[] sizes = {20,18,16,12,6};
        int current = getPreferences(0).getInt("subtitleSize", 16), selected = 2; for (int i = 0; i < sizes.length; i++) if (sizes[i] == current) selected = i;
        options("Subtitle size · reopens video", names, selected, which -> {
            getPreferences(0).edit().putInt("subtitleSize", sizes[which]).apply(); save();
            getIntent().putExtra("resume", true); closeOptions(); recreate();
        });
    }
    private void speed() {
        float[] values = {.25f,.5f,.75f,1,1.25f,1.5f,1.75f,2,3,4}; String[] names = new String[values.length];
        for (int i = 0; i < values.length; i++) names[i] = values[i] + "×";
        int selected = -1; for (int i = 0; i < values.length; i++) if (Math.abs(player.getRate() - values[i]) < .01f) selected = i;
        options("Playback speed", names, selected, index -> { player.setRate(values[index]); Toast.makeText(this, names[index], Toast.LENGTH_SHORT).show(); reveal(); });
    }
    private void picture() {
        options("Picture", new String[]{"Fit", "Fill / crop", "16:9", "4:3", "21:9", edges ? "Respect screen edges" : "Use screen edges"}, pictureChoice, index -> {
            if (index < 5) { pictureChoice = index; }
            if (index == 5) { edges = !edges; getWindow().getDecorView().setSystemUiVisibility(edges ? View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY : View.SYSTEM_UI_FLAG_VISIBLE); root.requestApplyInsets(); }
            else if (index == 4) { player.setVideoScale(MediaPlayer.ScaleType.SURFACE_BEST_FIT); player.setAspectRatio("21:9"); }
            else { player.setAspectRatio(null); player.setVideoScale(new MediaPlayer.ScaleType[]{MediaPlayer.ScaleType.SURFACE_BEST_FIT, MediaPlayer.ScaleType.SURFACE_FILL, MediaPlayer.ScaleType.SURFACE_16_9, MediaPlayer.ScaleType.SURFACE_4_3}[index]); }
            reveal();
        });
    }
    private void options(String title, String[] labels, int selected, java.util.function.IntConsumer action) {
        LinearLayout content = Ui.column(this); content.setPadding(Ui.dp(this, 8), 0, Ui.dp(this, 8), Ui.dp(this, 8));
        for (int i = 0; i < labels.length; i++) {
            final int index = i;
            Button choice = Ui.quiet(this, (i == selected ? "✓ " : "") + labels[i], () -> { closeOptions(); action.accept(index); });
            choice.setGravity(Gravity.START | Gravity.CENTER_VERTICAL); choice.setTextColor(i == selected ? Ui.accent(this) : Ui.TEXT);
            content.addView(choice, new LinearLayout.LayoutParams(-1, -2));
        }
        panel(title, content);
    }
    private void panel(String title, View content) {
        closeOptions(); handler.removeCallbacks(hide);
        optionsOverlay = new FrameLayout(this); optionsOverlay.setContentDescription("Player options");
        optionsOverlay.setOnClickListener(v -> closeOptions());
        LinearLayout panel = Ui.column(this); panel.setPadding(Ui.dp(this, 12), Ui.dp(this, 8), Ui.dp(this, 12), Ui.dp(this, 12));
        panel.setOnClickListener(v -> { });
        android.graphics.drawable.GradientDrawable background = new android.graphics.drawable.GradientDrawable();
        background.setColor(Ui.panel(this)); background.setCornerRadius(Ui.dp(this, 16)); background.setStroke(Ui.dp(this, 1), Ui.accent(this)); panel.setBackground(background);
        LinearLayout heading = Ui.row(this); TextView label = Ui.text(this, title, 16, Ui.TEXT); Ui.weighted(heading, label);
        Button close = Ui.quiet(this, "×", this::closeOptions); close.setContentDescription("Close player options"); heading.addView(close); panel.addView(heading);
        final int maximum = (int) (getResources().getDisplayMetrics().heightPixels * (landscape ? .60f : .32f));
        ScrollView scroll = new ScrollView(this) {
            @Override protected void onMeasure(int widthSpec, int heightSpec) { super.onMeasure(widthSpec, View.MeasureSpec.makeMeasureSpec(maximum, View.MeasureSpec.AT_MOST)); }
        }; scroll.addView(content); panel.addView(scroll);
        int width = Math.min(getResources().getDisplayMetrics().widthPixels - Ui.dp(this, 32), Ui.dp(this, landscape ? 340 : 420));
        FrameLayout.LayoutParams position = new FrameLayout.LayoutParams(width, -2, Gravity.BOTTOM | (landscape ? Gravity.END : Gravity.CENTER_HORIZONTAL));
        position.setMargins(Ui.dp(this, 16), Ui.dp(this, 16), Ui.dp(this, 16), Ui.dp(this, 16)); optionsOverlay.addView(panel, position);
        root.addView(optionsOverlay, new FrameLayout.LayoutParams(-1, -1));
    }
    private void closeOptions() { if (optionsOverlay != null) { root.removeView(optionsOverlay); optionsOverlay = null; reveal(); } }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != 200 || result != RESULT_OK || data == null || data.getData() == null) return;
        Uri uri = data.getData(); int type = importType;
        message.setText(R.string.track_importing);
        telegram.io.execute(() -> {
            File copy = null;
            try {
                String name = "track";
                try (android.database.Cursor rows = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) { if (rows != null && rows.moveToFirst()) name = rows.getString(0); }
                String extension = name.contains(".") ? name.substring(name.lastIndexOf('.')).replaceAll("[^.a-zA-Z0-9]", "") : "";
                if (extension.length() > 12) extension = "";
                copy = File.createTempFile("track-", extension, getCacheDir());
                try (InputStream input = getContentResolver().openInputStream(uri); OutputStream output = new FileOutputStream(copy)) {
                    if (input == null) throw new IOException("Could not read track");
                    byte[] buffer = new byte[64 * 1024]; int count; long size = 0;
                    while ((count = input.read(buffer)) != -1) { if (released) throw new InterruptedIOException("Player closed"); size += count; if (size > 512L * 1024 * 1024) throw new IOException("Track exceeds 512 MB import limit"); output.write(buffer, 0, count); }
                }
                File file = copy;
                runOnUiThread(() -> {
                    if (released) { file.delete(); return; }
                    externalFiles.add(file);
                    boolean added = player.addSlave(type, Uri.fromFile(file), true); message.setText(added ? "Track added." : "The player could not open this track."); reveal();
                });
            } catch (Exception e) { if (copy != null) copy.delete(); runOnUiThread(() -> { if (!released) message.setText(getString(R.string.track_import_failed, e.getMessage())); }); }
        });
    }
    @Override protected void onSaveInstanceState(Bundle state) { super.onSaveInstanceState(state); if (player != null) state.putLong("position", recovery.target != null ? recovery.target : recovery.failedTarget != null ? recovery.failedTarget : player.getTime()); state.putBoolean("landscape", landscape); }
    @Override protected void onPause() { foreground = false; if (player != null && !released) { resumeAfterPause = !userPaused && !playbackError && !playbackEnded && recovery.failedTarget == null; player.pause(); save(); } super.onPause(); }
    @Override protected void onResume() { super.onResume(); foreground = true; if (player != null && resumeAfterPause && !released) { resumeAfterPause = false; player.play(); } }
    @Override protected void onDestroy() {
        released = true; handler.removeCallbacksAndMessages(null); save(); progressWriter.shutdown();
        if (bridge != null) bridge.close();
        if (player != null) { player.setEventListener(null); player.stop(); player.detachViews(); player.release(); }
        if (vlc != null) vlc.release();
        for (File file : externalFiles) file.delete();
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); super.onDestroy();
    }
}
