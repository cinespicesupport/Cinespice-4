package app.cinespice.android

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import android.view.KeyEvent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.AnnotatedString
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.*
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class ChannelUiTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private lateinit var telegram: Telegram
    private lateinit var originalStage: String
    private var originalLibrary: Library? = null
    private lateinit var previousAccess: LongArray
    private lateinit var scenario: ActivityScenario<MainActivity>
    private var previousTheme: String? = null
    @Before fun setup() {
        telegram = (context.applicationContext as CinespiceApp).telegram
        previousAccess = SyntheticAccess.grant(telegram)
        originalStage = telegram.stage; originalLibrary = telegram.library
        previousTheme = context.getSharedPreferences("cinespice", 0).getString("cinespice.theme", "Crimson Cinema")
        context.getSharedPreferences("cinespice", 0).edit().putString("cinespice.theme", "Crimson Cinema").commit()
        context.deleteDatabase("library_-95.db"); context.deleteDatabase("saved_-95.db")
        telegram.stage = "ready"; telegram.library = Library(context, -95)
        telegram.library!!.chat(-101, "Cinema archive", true, 1); telegram.library!!.select(-101, true)
        telegram.library!!.chat(-102, "Documentary club", false, 2)
        val titles = listOf("The Quiet Horizon.2024.mkv", "After the Rain.2021.mp4", "A Place in the Sun.1951.mp4", "Ocean Stories.2023.mp4", "Midnight Train.2019.mkv", "The Long Goodbye.1973.mp4", "Parallel Worlds.2025.mkv", "One Summer.2020.mp4", "A Distant Light.2018.mp4", "City of Dreams.2022.mkv", "Northern Skies.2017.mp4", "The Last Frame.2026.mp4")
        titles.forEachIndexed { index, title ->
            val video = Video(Json.obj("chatId", -101, "messageId", index+1, "name", title, "duration", 5400, "size", 1073741824, "date", 1000 + index))
            telegram.library!!.save(video)
            if (index < 7) { telegram.library!!.progress(video, 120000L + index, 5400000, false); SystemClock.sleep(2) }
        }
        scenario = ActivityScenario.launch(MainActivity::class.java)
        compose.waitForIdle()
        awaitModel { it.videos.size == 12 }
    }
    private fun awaitModel(predicate: (LibraryModel) -> Boolean) {
        compose.waitUntil(10000) { var ready = false; scenario.onActivity { ready = predicate(it.model) }; ready }
    }
    @After fun cleanup() {
        scenario.close(); SyntheticAccess.restore(telegram, previousAccess); telegram.stage = originalStage; telegram.library = originalLibrary
        context.deleteDatabase("library_-95.db"); context.deleteDatabase("saved_-95.db")
        context.getSharedPreferences("cinespice", 0).edit().putString("cinespice.theme", previousTheme).commit()
    }
    private fun screenshot(name: String) {
        compose.waitForIdle()
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        File(context.getExternalFilesDir(null), "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    @Test fun passwordIsNotRestoredAfterActivityRecreation() {
        scenario.onActivity { telegram.stage = "password"; telegram.library = null; it.model.changed() }
        compose.onNodeWithText("Two-step verification password").performTextInput("synthetic-password")
        scenario.recreate()
        compose.onNodeWithText("Two-step verification password").assert(
            SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")))
    }
    @Test fun favoritesWatchlistAndSelectionAreIndependent() {
        scenario.onActivity { it.model.toggle(it.model.videos.first(), "Favorites") }
        awaitModel { it.favorites.size == 1 }
        scenario.onActivity { it.model.toggle(it.model.videos.first(), "Watchlist") }
        awaitModel { it.watchlist.size == 1 }
        scenario.onActivity { it.model.select(it.model.channels.first { c -> c.id() == -101L }) }
        awaitModel { it.videos.isEmpty() }
        scenario.onActivity { it.model.select(it.model.channels.first { c -> c.id() == -101L }) }
        awaitModel { it.videos.size == 12 }
        scenario.onActivity { assertEquals(1, it.model.favorites.size); it.model.navigate("library") }
        compose.onNodeWithText("Library").assertIsDisplayed()
        compose.onNodeWithText("Watchlist", useUnmergedTree = true).performClick()
        scenario.recreate(); awaitModel { it.videos.size == 12 }; compose.onNodeWithText("Library").assertIsDisplayed()
        screenshot("compose-favorites")
        scenario.onActivity { assertEquals("Watchlist", it.model.savedList); assertEquals(1, it.model.watchlist.size) }
    }
    @Test fun channelSearchKeepsFocusAndKeyboardDuringMetadataRefresh() {
        compose.onNodeWithContentDescription("Channels").performClick()
        compose.onNodeWithText("Search channels and groups").performClick().performTextInput("Cinema")
        scenario.onActivity { activity ->
            telegram.library!!.chat(-104, "Cinema discoveries", false, 4); activity.model.reload()
        }
        awaitModel { it.channels.any { c -> c.id() == -104L } }
        compose.onNodeWithText("Search channels and groups").assertIsFocused()
        compose.onNodeWithText("Cinema discoveries").assertIsDisplayed()
        compose.onNodeWithText("Documentary club").assertDoesNotExist()
        screenshot("compose-keyboard")
        instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.onNodeWithText("Done").assertIsDisplayed().performClick()
        compose.onNodeWithContentDescription("Home tab").assertIsDisplayed()
    }
    @Test fun emptySearchDraftRecreationHistoryAndPalette() {
        compose.onNodeWithContentDescription("Search tab").performClick()
        compose.onNodeWithText("Search your selected channels").assertIsDisplayed()
        compose.onNodeWithText("Search videos").performClick().performTextInput("Quiet")
        compose.onNodeWithText("Search videos").assertTextContains("Quiet")
        scenario.onActivity { assertEquals("Quiet", it.model.query) }
        scenario.recreate()
        compose.onNodeWithText("Search videos").assertTextContains("Quiet")
        compose.onNodeWithContentDescription("Clear search").performClick()
        scenario.onActivity { activity -> assertEquals("", activity.model.query); assertTrue(activity.model.searchResults.isEmpty()); assertEquals(5, activity.model.history.size) }
        compose.onNodeWithTag("library-grid").performScrollToIndex(1)
        compose.onNodeWithText("Search your selected channels").assertIsDisplayed()
        compose.onNodeWithContentDescription("Profile").performClick()
        scenario.onActivity { it.model.theme("Cinespice Glass") }
        compose.onNodeWithText("Your space").assertIsDisplayed(); screenshot("compose-pearl-profile")
        scenario.recreate(); scenario.onActivity { assertEquals("Cinespice Glass", it.model.palette); it.model.navigate("home") }
        compose.onNodeWithContentDescription("Hero 1 of 7: Recently added").assertIsDisplayed(); screenshot("compose-pearl-home")
        scenario.onActivity { it.model.theme("Silver Screen") }; screenshot("compose-midnight-home")
        scenario.onActivity { it.model.theme("Cinespice Dark") }; screenshot("compose-sage-home")
        scenario.onActivity { it.model.theme("Crimson Cinema") }; screenshot("compose-ember-home")
        val roles = listOf("Recently added", "Today's pick", "Trending · 1", "Trending · 2", "Trending · 3", "Trending · 4", "Last searched")
        for (index in 0..5) {
            compose.onNodeWithContentDescription("Hero ${index+1} of 7: ${roles[index]}").performTouchInput { swipeLeft() }
            compose.onNodeWithContentDescription("Hero ${index+2} of 7: ${roles[index+1]}").assertIsDisplayed()
        }
        compose.onNodeWithTag("library-grid").performScrollToIndex(0)
        compose.onNodeWithContentDescription("Library tab").performClick()
        compose.onNodeWithText("History", useUnmergedTree = true).performClick()
        compose.onNodeWithContentDescription("Home tab").performClick()
        compose.onNodeWithContentDescription("Hero 1 of 7: Recently added").assertIsDisplayed()
    }
    @Test fun savedMembershipPersistsAcrossDatabaseReopenAndAccountsStayIsolated() {
        val video = Video(Json.obj("chatId", -101, "messageId", 1, "name", "Film.mp4"))
        val first = SavedStore.open(context, -96)
        first.entries().put(SavedStore.Member(SavedStore.id(video), "Favorites")); first.close()
        val reopened = SavedStore.open(context, -96); val second = SavedStore.open(context, -97)
        try { assertEquals(listOf("-101:1"), reopened.entries().members("Favorites")); assertTrue(second.entries().members("Favorites").isEmpty()) }
        finally { reopened.close(); second.close(); context.deleteDatabase("saved_-96.db"); context.deleteDatabase("saved_-97.db") }
    }
}
