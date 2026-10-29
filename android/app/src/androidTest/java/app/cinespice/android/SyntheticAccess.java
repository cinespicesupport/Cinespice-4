package app.cinespice.android;

/** Test-only in-memory pass fixture; production has no bypass API. */
final class SyntheticAccess {
    static long[] grant(Telegram telegram) {
        try {
            java.lang.reflect.Field deadline = AccessController.class.getDeclaredField("deadline");
            java.lang.reflect.Field expires = AccessController.class.getDeclaredField("expires");
            deadline.setAccessible(true); expires.setAccessible(true);
            long[] previous = {deadline.getLong(telegram.access), expires.getLong(telegram.access)};
            deadline.setLong(telegram.access, android.os.SystemClock.elapsedRealtime()+3600000);
            expires.setLong(telegram.access, System.currentTimeMillis()/1000+3600);
            return previous;
        } catch (ReflectiveOperationException e) { throw new AssertionError(e); }
    }
    static void restore(Telegram telegram, long[] previous) {
        try {
            java.lang.reflect.Field deadline = AccessController.class.getDeclaredField("deadline");
            java.lang.reflect.Field expires = AccessController.class.getDeclaredField("expires");
            deadline.setAccessible(true); expires.setAccessible(true);
            deadline.setLong(telegram.access,previous[0]); expires.setLong(telegram.access,previous[1]);
        } catch (ReflectiveOperationException e) { throw new AssertionError(e); }
    }
}
