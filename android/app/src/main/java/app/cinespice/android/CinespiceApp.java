package app.cinespice.android;

import android.app.Application;

public final class CinespiceApp extends Application {
    Telegram telegram;
    @Override public void onCreate() { super.onCreate(); telegram = new Telegram(this); }
}
