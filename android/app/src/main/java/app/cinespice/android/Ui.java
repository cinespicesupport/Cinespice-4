package app.cinespice.android;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.widget.*;
import androidx.appcompat.widget.AppCompatEditText;
import com.google.android.material.button.MaterialButton;

final class Ui {
    static final int BG = Color.rgb(21,20,22), PANEL = Color.rgb(34,32,34), ACCENT = 0xFFE11D2E, TEXT = Color.rgb(244,240,236), MUTED = Color.rgb(189,182,176);
    static String theme(Activity activity) { return activity.getSharedPreferences("cinespice", 0).getString("cinespice.theme", "Cinespice Dark"); }
    static int accent(Activity activity) { return switch (theme(activity)) {
        case "Crimson Cinema", "Ember" -> 0xFFE85A64;
        case "Silver Screen", "Midnight" -> 0xFFD6DDE7;
        default -> 0xFFFF3340;
    }; }
    static int action(Activity activity) { return switch (theme(activity)) {
        case "Crimson Cinema", "Ember" -> 0xFFA32C44;
        case "Silver Screen", "Midnight" -> 0xFFD6DDE7;
        default -> 0xFFE11D2E;
    }; }
    static int onAction(Activity activity) { return theme(activity).equals("Silver Screen") || theme(activity).equals("Midnight") ? 0xFF14171C : Color.WHITE; }
    static int panel(Activity activity) { return switch (theme(activity)) {
        case "Crimson Cinema", "Ember" -> 0xFF311D27;
        case "Silver Screen", "Midnight" -> 0xFF272C34;
        default -> 0xFF1C1C22;
    }; }
    static int dp(Activity activity, float value) { return (int) (value * activity.getResources().getDisplayMetrics().density + .5f); }
    static LinearLayout column(Activity activity) {
        LinearLayout layout = new LinearLayout(activity); layout.setOrientation(LinearLayout.VERTICAL); layout.setPadding(dp(activity, 20), dp(activity, 12), dp(activity, 20), dp(activity, 12)); return layout;
    }
    static LinearLayout row(Activity activity) { LinearLayout row = new LinearLayout(activity); row.setGravity(android.view.Gravity.CENTER_VERTICAL); return row; }
    static TextView text(Activity activity, String value, int size, int color) {
        TextView text = new TextView(activity); text.setText(value); text.setTextSize(size); text.setTextColor(color); text.setLineSpacing(dp(activity, 2), 1); text.setPadding(0, dp(activity, 6), 0, dp(activity, 6)); return text;
    }
    static TextView heading(Activity activity, String value) { TextView text = text(activity, value, 24, TEXT); text.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL)); text.setPadding(0, dp(activity, 10), 0, dp(activity, 6)); return text; }
    static MaterialButton button(Activity activity, String label, Runnable action) {
        MaterialButton button = new MaterialButton(activity); button.setText(label); button.setAllCaps(false); button.setTextSize(13); button.setMinHeight(dp(activity, 48)); button.setMinimumWidth(0); button.setMinWidth(0); button.setMaxLines(2); button.setCornerRadius(dp(activity, 12)); button.setInsetTop(dp(activity, 2)); button.setInsetBottom(dp(activity, 2)); button.setPadding(dp(activity, 12), dp(activity, 6), dp(activity, 12), dp(activity, 6)); button.setBackgroundTintList(ColorStateList.valueOf(panel(activity))); button.setTextColor(ColorStateList.valueOf(TEXT)); button.setOnClickListener(v -> action.run()); return button;
    }
    static MaterialButton primary(Activity activity, String label, Runnable action) { MaterialButton button = button(activity, label, action); button.setBackgroundTintList(ColorStateList.valueOf(action(activity))); button.setTextColor(onAction(activity)); return button; }
    static MaterialButton quiet(Activity activity, String label, Runnable action) { MaterialButton button = button(activity, label, action); button.setBackgroundTintList(ColorStateList.valueOf(Color.TRANSPARENT)); button.setTextColor(accent(activity)); return button; }
    static EditText input(Activity activity, String hint, int type) {
        EditText input = new AppCompatEditText(activity); input.setHint(hint); input.setContentDescription(hint); input.setTextColor(TEXT); input.setHintTextColor(MUTED); input.setTextSize(16); input.setInputType(type); input.setSingleLine(true); input.setMinHeight(dp(activity, 56)); input.setPadding(dp(activity, 16), dp(activity, 14), dp(activity, 16), dp(activity, 14)); input.setBackground(card(activity)); input.setBackgroundTintList(null); input.setImeOptions(EditorInfo.IME_ACTION_DONE); LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2); params.setMargins(0, dp(activity, 8), 0, dp(activity, 8)); input.setLayoutParams(params); return input;
    }
    static void weighted(LinearLayout row, View child) { LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, -2, 1); params.setMargins(dp((Activity) row.getContext(), 3), 0, dp((Activity) row.getContext(), 3), 0); row.addView(child, params); }
    static GradientDrawable card(Activity activity) { GradientDrawable background = new GradientDrawable(); background.setColor(panel(activity)); background.setCornerRadius(dp(activity, 20)); background.setStroke(dp(activity, 1), 0xFF393437); return background; }
    static String time(long milliseconds) { long seconds = Math.max(0, milliseconds / 1000); return String.format(java.util.Locale.ROOT, "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60); }
}
