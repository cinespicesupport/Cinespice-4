# These names and members are accessed by the prebuilt native libraries.
-keep class io.github.up9cloud.td.JsonClient { *; }
-keep class org.videolan.libvlc.** { *; }

# The external instrumentation runner calls this shared API by its original name.
-keep class androidx.tracing.** { *; }

# Instrumentation runs in a separate APK. Preserve the shared Kotlin runtime ABI
# and the app's small metadata/UI API so its calls survive main-APK optimization.
# Unused AndroidX and Material code and resources can still be removed.
-keep class kotlin.** { *; }
-keep class app.cinespice.android.** { *; }
