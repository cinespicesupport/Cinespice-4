@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
package app.cinespice.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.pager.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.*
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.*
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.platform.*
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.*
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import androidx.core.view.WindowCompat
import kotlinx.coroutines.launch
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale

internal data class CinePalette(val name: String, val bg: Color, val surface: Color, val accent: Color, val dark: Boolean)
internal fun canonicalTheme(name: String): String = when (name) {
    "Ember", "Crimson Cinema" -> "Crimson Cinema"
    "Midnight", "Silver Screen" -> "Silver Screen"
    "Pearl", "Sage", "Cinespice Glass" -> "Cinespice Glass"
    else -> "Cinespice Dark"
}
internal val palettes = listOf(
    CinePalette("Cinespice Glass", Color(0xFFF8F6F4), Color.White, Color(0xFFD11325), false),
    CinePalette("Cinespice Dark", Color(0xFF0B0B0F), Color(0xFF1C1C22), Color(0xFFFF3340), true),
    CinePalette("Crimson Cinema", Color(0xFF1B0D14), Color(0xFF311D27), Color(0xFFE85A64), true),
    CinePalette("Silver Screen", Color(0xFF14171C), Color(0xFF272C34), Color(0xFFD6DDE7), true)
)
internal data class Destination(val id: String, val title: String, val icon: ImageVector)
internal val destinations = listOf(Destination("home", "Home", Icons.Default.Home), Destination("search", "Search", Icons.Default.Search), Destination("library", "Library", CineIcons.VideoLibrary), Destination("downloads", "Downloads", CineIcons.Download))

@Composable internal fun Cinespice(activity: MainActivity, model: LibraryModel) {
    val palette = palettes.firstOrNull { it.name == model.palette } ?: palettes[1]
    val text = if (palette.dark) Color.White.copy(alpha = .96f) else Color(0xFF171717)
    val muted = if (palette.dark) Color.White.copy(alpha = .69f) else Color(0xFF5C5C5C)
    val scheme = (if (palette.dark) darkColorScheme() else lightColorScheme()).copy(
        primary = palette.accent, onPrimary = if (palette.dark) Color(0xFF14171C) else Color.White,
        background = palette.bg, onBackground = text, surface = palette.surface, onSurface = text,
        surfaceVariant = palette.surface, onSurfaceVariant = muted, outline = muted.copy(alpha = .3f),
        primaryContainer = palette.accent.copy(alpha = .15f), onPrimaryContainer = text,
        secondaryContainer = palette.accent.copy(alpha = .15f), onSecondaryContainer = palette.accent,
        surfaceContainer = palette.surface, surfaceContainerHigh = palette.surface, surfaceContainerHighest = palette.surface,
        surfaceTint = Color.Transparent
    )
    val inputAreas = remember { mutableMapOf<Any, androidx.compose.ui.geometry.Rect>() }
    CompositionLocalProvider(LocalInputAreas provides inputAreas) {
    MaterialTheme(colorScheme = scheme) {
        val keyboard = LocalSoftwareKeyboardController.current
        val focus = LocalFocusManager.current
        val view = LocalView.current
        val density = LocalDensity.current
        val ime = WindowInsets.ime.getBottom(density) > 0
        SideEffect { WindowCompat.getInsetsController(activity.window, view).apply { isAppearanceLightStatusBars = !palette.dark; isAppearanceLightNavigationBars = !palette.dark } }
        LaunchedEffect(model.account) { while (true) { delay(1000); model.tick() } }
        fun navigate(destination: String) { keyboard?.hide(); focus.clearFocus(); model.navigate(destination) }
        BackHandler(model.channelsVisible || model.page != "home") {
            if (ime) { keyboard?.hide(); focus.clearFocus() }
            else if (model.channelsVisible) model.closeChannels() else navigate("home")
        }
        BoxWithConstraints(Modifier.fillMaxSize().background(palette.bg).outsideKeyboard()) {
            val rail = maxWidth >= 840.dp && model.stage == "ready"
            Scaffold(containerColor = palette.bg, contentWindowInsets = WindowInsets.safeDrawing,
                topBar = {
                    Column(Modifier.statusBarsPadding().background(palette.surface)) {
                        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            if (model.page == "collection" && model.stage == "ready") IconButton(onClick = { navigate("home") }) { Icon(Icons.Default.ArrowBack, "Back") }
                            TextButton(onClick = { if (model.stage == "ready") model.refresh() }, enabled = !model.busy) { Text("CINESPICE", letterSpacing = 2.sp, fontWeight = FontWeight.Bold, fontSize = 17.sp) }
                            Spacer(Modifier.weight(1f))
                            if (model.stage == "ready") {
                                IconButton(onClick = { keyboard?.hide(); model.showNotifications() }) { Icon(Icons.Default.Notifications, "Notifications") }
                                IconButton(onClick = { keyboard?.hide(); model.showChannels() }) { Icon(CineIcons.VideoLibrary, "Channels") }
                                IconButton(onClick = { navigate("profile") }) { Icon(CineIcons.PersonOutline, "Profile") }
                            }
                        }
                        if (model.busy || model.searching) LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp))
                        if (model.stage == "ready" && model.status.isNotBlank()) Text(model.status, Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp).semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.bodySmall)
                        if (model.stage == "ready" && model.announcement != null) AccessNotice(model)
                        HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = .3f))
                    }
                }, bottomBar = {
                    if (model.stage == "ready" && !rail && !ime) NavigationBar(modifier = Modifier.navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp).clip(RoundedCornerShape(30.dp)).heightIn(min = 72.dp), windowInsets = WindowInsets(0), containerColor = palette.surface, tonalElevation = 0.dp) {
                        destinations.forEach { dest -> NavigationBarItem(selected = model.page == dest.id, onClick = { navigate(dest.id) }, icon = { Icon(dest.icon, null) }, label = { Text(dest.title, maxLines = if (LocalDensity.current.fontScale > 1.4f) 2 else 1, fontSize = 11.sp, softWrap = false, textAlign = androidx.compose.ui.text.style.TextAlign.Center) }, modifier = Modifier.semantics { contentDescription = "${dest.title} tab" }) }
                    }
                }
            ) { padding ->
                // Scaffold already applies the safe-drawing insets. A second IME
                // inset here double-counted the keyboard when edge-to-edge was on.
                Row(Modifier.fillMaxSize().padding(padding)) {
                    if (rail) NavigationRail(containerColor = palette.surface) { destinations.forEach { dest -> NavigationRailItem(modifier = Modifier.semantics { contentDescription = "${dest.title} tab" }, selected = model.page == dest.id, onClick = { navigate(dest.id) }, icon = { Icon(dest.icon, dest.title) }, label = { Text(dest.title) }) } }
                    Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.TopCenter) {
                        if (model.stage == "ready") LibraryPage(activity, model, Modifier.widthIn(max = 1200.dp).fillMaxSize()) else if (model.stage == "activation") AccessActivation(model) else Authentication(activity, model)
                    }
                }
            }
        }
        if (model.notificationsVisible && model.stage == "ready") NotificationHistory(model)
        if (model.channelsVisible && model.stage == "ready") ChannelPicker(model)
        activity.opening?.let { video -> AlertDialog(onDismissRequest = activity::cancelOpening, title = { Text("Opening video") }, text = { Column { Text(video.displayTitle); LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 16.dp)) } }, confirmButton = { TextButton(onClick = activity::cancelOpening) { Text("Cancel") } }) }
    }
}

}

/** Observe taps without consuming them, so the same tap can activate a button. */
@Composable private fun Modifier.outsideKeyboard(): Modifier {
    val keyboard = LocalSoftwareKeyboardController.current
    val areas = LocalInputAreas.current
    val focus = LocalFocusManager.current
    var coordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
    return onGloballyPositioned { coordinates = it }.pointerInput(keyboard) {
        awaitPointerEventScope {
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Final)
                if (event.type == PointerEventType.Press) {
                    // Observe without consuming, including taps already handled by a button.
                    if (event.changes.none { change -> areas.values.any { it.contains(coordinates?.localToRoot(change.position) ?: change.position) } }) { keyboard?.hide(); focus.clearFocus() }
                }
            }
        }
    }
}

@Composable private fun LibraryPage(activity: MainActivity, model: LibraryModel, modifier: Modifier) {
    if (model.page == "profile") { Profile(activity, model, modifier); return }
    key(model.account, model.page, model.chat, model.savedList) {
        val grid = rememberLazyGridState()
        val scope = rememberCoroutineScope()
        val searchFocus = remember { FocusRequester() }
        val awayFromTop by remember { derivedStateOf { grid.firstVisibleItemIndex > 0 || grid.firstVisibleItemScrollOffset > 300 } }
        LaunchedEffect(model.page) {
            if (model.page == "search") { withFrameNanos { }; searchFocus.requestFocus() }
        }
        val videos = when (model.page) {
            "collection" -> model.sorted((model.videos.filter { it.chatId == model.chat && (model.collectionQuery.isBlank() || it.name.contains(model.collectionQuery, true)) } + model.collectionSearchResults).distinctBy { it.key() })
            "library" -> when (model.savedList) {
                "New Releases" -> VideoSort.sorted(model.videos, 0)
                "History" -> model.history
                else -> model.sorted(model.videos.filter { SavedStore.id(it) in if (model.savedList == "Favorites") model.favorites else model.watchlist })
            }
            "search" -> if (model.query.isBlank()) emptyList() else model.sorted(model.searchResults)
            "downloads" -> model.sorted(model.videos.filter { model.downloadStates[SavedStore.id(it)] != null })
            "history" -> model.history
            else -> emptyList()
        }
        Box(modifier) {
        LazyVerticalGrid(columns = GridCells.Adaptive(140.dp), state = grid, modifier = Modifier.fillMaxSize().testTagCompat("library-grid"), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 100.dp), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            if (model.page == "home") {
                item(span = { GridItemSpan(maxLineSpan) }) { Hero(activity, model) }
                if (model.continuing.isNotEmpty()) item(span = { GridItemSpan(maxLineSpan) }) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        SectionTitle("Continue watching")
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) { items(model.continuing, key = { it.key() }) { video -> ContinueCard(activity, model, video) } }
                    }
                }
                val selectedChannels = model.channels.filter { it.selected() }
                if (selectedChannels.isEmpty()) item(span = { GridItemSpan(maxLineSpan) }) {
                    EmptyState("Choose your channels", "Select channels and groups using the Channels button.")
                }
                selectedChannels.forEach { source ->
                    item(key = "channel-${source.id()}", span = { GridItemSpan(maxLineSpan) }) {
                        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                            Row(Modifier.fillMaxWidth().clickable { model.browse(source) }.heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(source.title(), Modifier.weight(1f), style = MaterialTheme.typography.titleLarge, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Bold)
                                Icon(CineIcons.ChevronRight, "Browse ${source.title()}")
                            }
                            val titles = model.homeRails[source.id()].orEmpty()
                            if (titles.isEmpty()) Text("Open this channel to load videos", style = MaterialTheme.typography.bodySmall)
                            LazyRow(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                                items(titles, key = { it.key() }) { video -> Box(Modifier.width(164.dp)) { Poster(activity, model, video) } }
                            }
                        }
                    }
                }
            }

            if (model.page != "home") item(span = { GridItemSpan(maxLineSpan) }) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(when(model.page) { "library" -> "Library"; "search" -> "Find your next watch"; "downloads" -> "Downloads"; "history" -> "Recently watched"; else -> model.chatTitle }, style = MaterialTheme.typography.headlineMedium, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                    if (model.page == "library") LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(listOf("New Releases", "Favorites", "Watchlist", "History")) { list ->
                            FilterChip(selected = model.savedList == list, onClick = { model.setList(list) }, label = { Text(list) })
                        }
                    }
                    if (model.page == "search") {
                        OutlinedTextField(model.query, model::search, Modifier.fillMaxWidth().focusRequester(searchFocus).inputArea(), label = { Text("Search videos") }, singleLine = true, leadingIcon = { Icon(Icons.Default.Search, null) }, trailingIcon = { if (model.query.isNotEmpty()) IconButton(onClick = { model.search("") }) { Icon(Icons.Default.Close, "Clear search") } else Spacer(Modifier.size(48.dp)) }, keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { model.search(model.query) }))
                    }
                    if (model.page == "collection") OutlinedTextField(model.collectionQuery, model::searchCollection, Modifier.fillMaxWidth().focusRequester(searchFocus).inputArea(), label = { Text("Search this channel") }, singleLine = true, leadingIcon = { Icon(Icons.Default.Search, null) }, trailingIcon = { if (model.collectionQuery.isNotEmpty()) IconButton(onClick = { model.searchCollection("") }) { Icon(Icons.Default.Close, "Clear channel search") } else Spacer(Modifier.size(48.dp)) }, keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { model.searchCollection(model.collectionQuery) }))
                    if (model.page == "history") Text("Your five most recent watches. Older resume positions stay saved.", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    else if (model.page == "downloads") Text("Pause keeps cached data for Resume. Keep the app open while downloading. Completed files can be saved to your device.", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    if (model.page !in listOf("search", "history") || model.query.isNotBlank()) if (model.page != "history" && !(model.page == "library" && model.savedList in listOf("New Releases", "History"))) SortControl(model)
                }
            }
            if (videos.isEmpty() && model.page != "home" && !(model.page == "search" && model.query.isNotBlank())) item(span = { GridItemSpan(maxLineSpan) }) {
                EmptyState(when (model.page) { "search" -> if (model.query.isBlank()) "Search your selected channels" else if (model.searching) "Searching…" else "No matching videos"; "collection" -> if (model.collectionQuery.isBlank()) "No videos loaded yet" else if (model.collectionSearching) "Searching this channel…" else "No matching videos"; "library" -> "A little inspiration for later"; "downloads" -> "Nothing downloaded yet"; "history" -> "Your next film starts here"; else -> "Your cinema starts here" }, when (model.page) { "search" -> "Enter a title or filename. Only channels you select are searched."; "collection" -> if (model.collectionQuery.isBlank()) "Load this channel's videos to start browsing." else "Search is limited to this channel."; "library" -> when (model.savedList) { "New Releases" -> "Load videos from your selected channels to see recent additions."; "History" -> "Videos you watch will appear here."; else -> "Use a video's details to add it to ${model.savedList}." }; "downloads" -> "Choose Download from a video's details or menu."; "history" -> "Videos you watch will appear here."; else -> "Select your channels using the Channels button." })
            }
            items(videos, key = { it.key() }) { video -> Poster(activity, model, video) }
            if (model.page == "search" && model.query.isNotBlank()) item(span = { GridItemSpan(maxLineSpan) }) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("${model.searchResults.size} results · ${model.channels.count { it.selected() }} selected sources", style = MaterialTheme.typography.bodySmall)
                    if (model.searchError.isNotBlank()) Text(model.searchError, color = MaterialTheme.colorScheme.error)
                    else if (!model.searching && !model.searchMore && model.searchResults.isEmpty()) Text(if (model.channels.none { it.selected() }) "Select channels in Channels before searching." else "No matching videos. Try another title or filename.")
                    else if (model.searchMore && !model.searching) Text("Older messages have not all been searched yet.", style = MaterialTheme.typography.bodySmall)
                }
            }
            if (model.page == "search" && model.query.isNotBlank()) item(span = { GridItemSpan(maxLineSpan) }) { OutlinedButton(onClick = model::moreSearch, enabled = !model.searching && (model.searchMore || model.searchError.isNotBlank()), modifier = Modifier.fillMaxWidth()) { Text(if (model.searching) "Searching channels…" else if (model.searchError.isNotBlank()) "Retry search" else "Search older messages") } }
            if (model.page == "collection" && model.collectionQuery.isNotBlank() && model.collectionSearchError.isNotBlank()) item(span = { GridItemSpan(maxLineSpan) }) { Text(model.collectionSearchError, color = MaterialTheme.colorScheme.error) }
            if (model.page == "collection") item(span = { GridItemSpan(maxLineSpan) }) {
                if (model.collectionQuery.isNotBlank()) OutlinedButton(onClick = model::moreCollectionSearch, enabled = !model.collectionSearching && model.collectionSearchMore, modifier = Modifier.fillMaxWidth()) { Text(if (model.collectionSearching) "Searching…" else if (model.collectionSearchError.isNotBlank()) "Retry channel search" else "More channel results") }
                else OutlinedButton(onClick = model::older, enabled = !model.busy && model.collectionMore, modifier = Modifier.fillMaxWidth()) { Text(if (model.collectionMore) "Load older videos / Retry" else "All available pages loaded") }
            }
        }
        if (awayFromTop) Row(Modifier.align(Alignment.BottomEnd).padding(16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(onClick = {
                if (model.page == "collection" || model.page == "search") scope.launch {
                    grid.scrollToItem(0); withFrameNanos { }; searchFocus.requestFocus()
                } else model.navigate("search")
            }) { Icon(Icons.Default.Search, null); Spacer(Modifier.width(6.dp)); Text("Search") }
            Button(onClick = { scope.launch { grid.scrollToItem(0) } }) { Text("↑ Top") }
        }
        }
    }
}

@Composable private fun ChannelTile(model: LibraryModel, source: Library.Chat) {
    val videos = model.videos.filter { it.chatId == source.id() }
    Card(onClick = { model.browse(source) }, modifier = Modifier.width(230.dp), shape = RoundedCornerShape(14.dp)) {
        Row(Modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(CineIcons.VideoLibrary, null, tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) { Text(source.title(), maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold); Text(if (videos.isEmpty()) "Loading videos…" else "${videos.size} cached videos", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall) }
            Icon(CineIcons.ChevronRight, "Browse ${source.title()}")
        }
    }
}

@Composable private fun Modifier.testTagCompat(tag: String) = this.semantics { testTag = tag }
@Composable private fun SectionTitle(text: String) { Text(text, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold) }
@Composable private fun EmptyState(title: String, detail: String) {
    Surface(shape = RoundedCornerShape(18.dp), border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = .4f))) {
        Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) { Icon(CineIcons.Movie, null, tint = MaterialTheme.colorScheme.primary); Text(title, style = MaterialTheme.typography.titleLarge); Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium) }
    }
}
@Composable private fun SortControl(model: LibraryModel) {
    var expanded by remember { mutableStateOf(false) }
    Column {
        Box { TextButton(onClick = { expanded = true }, contentPadding = PaddingValues(horizontal = 0.dp)) { Icon(CineIcons.Sort, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(VideoSort.LABELS[model.sort]) }; DropdownMenu(expanded, { expanded = false }) { VideoSort.LABELS.forEachIndexed { index, label -> DropdownMenuItem(text = { Text(if (index == model.sort) "✓ $label" else label) }, onClick = { model.order(index); expanded = false }) } } }
        if (model.sort < 2) Text("Filename years · loaded results only", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall)
    }
}
@Composable private fun Hero(activity: MainActivity, model: LibraryModel) {
    val pager = rememberPagerState { 7 }
    val latest = remember(model.videos) { model.videos.maxByOrNull { it.data.optLong("date") } }
    val daily = remember(model.videos, model.day) { VideoSort.daily(model.videos, model.day) }
    BoxWithConstraints {
        val artworkHeight = (maxWidth * .72f).coerceIn(200.dp, 440.dp)
        val detailsHeight = 190.dp * LocalDensity.current.fontScale
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            HorizontalPager(pager, pageSpacing = 16.dp, modifier = Modifier.fillMaxWidth()) { slot ->
                val video = when (slot) { 0 -> latest; 1 -> daily; 6 -> model.lastSearch; else -> null }
                val label = when (slot) { 0 -> "Recently added"; 1 -> "Today's pick"; 6 -> "Last searched"; else -> "Trending · ${slot - 1}" }
                var details by remember { mutableStateOf(false) }
                Column(Modifier.semantics { contentDescription = "Hero ${slot + 1} of 7: $label" }, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(label, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Box(Modifier.fillMaxWidth().height(artworkHeight).clip(RoundedCornerShape(24.dp)).background(MaterialTheme.colorScheme.surface), contentAlignment = Alignment.Center) {
                        if (video != null) ArtworkImage(model, video, Modifier.fillMaxSize()) else Icon(CineIcons.Movie, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Column(Modifier.fillMaxWidth().height(detailsHeight).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(video?.displayTitle ?: label, style = MaterialTheme.typography.headlineSmall, maxLines = 2, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Bold)
                        Text(if (video != null) videoDetails(video) else if (slot in 2..5) "No trending catalogue connected yet." else "Choose channels or complete a search to discover videos.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (video != null) VideoControls(activity, video) { details = true }
                    }
                }
                if (details && video != null) VideoDetails(activity, model, video) { details = false }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) { repeat(7) { index ->
                Box(Modifier.padding(horizontal = 3.dp).size(6.dp).clip(RoundedCornerShape(6.dp)).background(if (pager.currentPage == index) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline))
            } }
        }
    }
}
@Composable private fun ContinueCard(activity: MainActivity, model: LibraryModel, video: Video) {
    Column(Modifier.width(164.dp)) {
        Poster(activity, model, video)
        Text("Resume at ${Ui.time(model.positions[video.key()] ?: 0)}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
@Composable private fun Poster(activity: MainActivity, model: LibraryModel, video: Video) {
    var details by remember(video.key()) { mutableStateOf(false) }
    var menu by remember(video.key()) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(.73f).clip(RoundedCornerShape(14.dp)).background(MaterialTheme.colorScheme.surface)
            .combinedClickable(onClickLabel = "Details for ${video.displayTitle}", onClick = { details = true }, onLongClickLabel = "Video options", onLongClick = { menu = true })) {
            ArtworkImage(model, video, Modifier.matchParentSize())
            VideoMenu(activity, model, video, menu) { menu = false }
        }
        Text(video.displayTitle, fontSize = 14.sp, minLines = 2, maxLines = 2, lineHeight = 19.sp, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold)
        VideoControls(activity, video) { details = true }
        model.downloadStates[SavedStore.id(video)]?.let { state ->
            Text(state, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
            if (state == "Retry download") Text("Check your connection and available storage, then retry.", style = MaterialTheme.typography.bodySmall)
            DownloadAction(activity, model, video)
        }
    }
    if (details) VideoDetails(activity, model, video) { details = false }
}
@Composable private fun DownloadAction(activity: MainActivity, model: LibraryModel, video: Video, showInitial: Boolean = false) {
    val id = SavedStore.id(video)
    val state = if (id in model.preparing) "Preparing" else model.downloadStates[id]
    val label = when (state) {
        null -> if (showInitial) "Download" else return
        "Downloading" -> "Pause download"
        "Paused", "Cancelled" -> "Resume download"
        "Retry download" -> "Retry download"
        "Downloaded" -> "Save to device"
        "Preparing" -> "Preparing…"
        "Pausing" -> "Pausing…"
        else -> return
    }
    val icon = when (state) {
        "Downloading" -> CineIcons.Pause
        "Paused", "Cancelled" -> Icons.Default.PlayArrow
        else -> CineIcons.Download
    }
    Button(
        onClick = {
            when (state) {
                "Downloading" -> model.pauseDownload(video)
                "Downloaded" -> activity.export(video)
                else -> model.download(video)
            }
        },
        enabled = state !in listOf("Preparing", "Pausing") && !model.busy,
        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).semantics { contentDescription = "$label ${video.displayTitle}" },
        shape = RoundedCornerShape(12.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Color(Ui.action(activity)), contentColor = Color(Ui.onAction(activity))),
        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 8.dp)
    ) {
        Icon(icon, null, Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(label)
    }
}
@Composable private fun VideoControls(activity: MainActivity, video: Video, info: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Button(colors = ButtonDefaults.buttonColors(containerColor = Color(Ui.action(activity)), contentColor = Color(Ui.onAction(activity))), onClick = { activity.open(video) }, shape = RoundedCornerShape(50), contentPadding = PaddingValues(0.dp), modifier = Modifier.width(56.dp).heightIn(min = 48.dp)) {
            Icon(Icons.Default.PlayArrow, "Play ${video.displayTitle}", Modifier.size(20.dp))
        }
        Spacer(Modifier.weight(1f))
        IconButton(onClick = info) { Icon(Icons.Default.Info, "More info about ${video.displayTitle}") }
    }
}
@Composable private fun VideoDetails(activity: MainActivity, model: LibraryModel, video: Video, close: () -> Unit) {
    val id = SavedStore.id(video)
    ModalBottomSheet(onDismissRequest = close, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = MaterialTheme.colorScheme.background) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) { Text("Details", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge); TextButton(onClick = close) { Text("Done") } }
            ArtworkImage(model, video, Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(20.dp)), ContentScale.Fit)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Button(colors = ButtonDefaults.buttonColors(containerColor = Color(Ui.action(activity)), contentColor = Color(Ui.onAction(activity))), onClick = { close(); activity.open(video) }, shape = RoundedCornerShape(50), contentPadding = PaddingValues(0.dp), modifier = Modifier.width(56.dp).heightIn(min = 48.dp)) { Icon(Icons.Default.PlayArrow, "Play") }
                IconToggleButton(checked = id in model.favorites, enabled = !model.busy, onCheckedChange = { model.toggle(video, "Favorites") }) { Icon(if (id in model.favorites) Icons.Default.Favorite else Icons.Default.FavoriteBorder, if (id in model.favorites) "Remove from Favorites" else "Add to Favorites") }
                IconToggleButton(checked = id in model.watchlist, enabled = !model.busy, onCheckedChange = { model.toggle(video, "Watchlist") }) { Icon(if (id in model.watchlist) Icons.Default.Check else Icons.Default.Add, if (id in model.watchlist) "Remove from Watchlist" else "Add to Watchlist") }
            }
            DownloadAction(activity, model, video, showInitial = true)
            Text("About this video", style = MaterialTheme.typography.titleMedium)
            Text(video.name)
            if (video.caption.isNotBlank() && video.caption.trim() != video.name.trim()) Text(video.caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(videoDetails(video), style = MaterialTheme.typography.bodySmall)
        }
    }
}
internal fun videoDetails(video: Video): String = listOfNotNull(VideoSort.year(video)?.let { "$it · filename year" }, if (video.duration > 0) Ui.time(video.duration * 1000L) else null, if (video.size > 0) String.format(Locale.ROOT, "%.0f MB", video.size / 1048576.0) else null).joinToString(" · ")
@Composable private fun ArtworkImage(model: LibraryModel, video: Video, modifier: Modifier, scale: ContentScale = ContentScale.Crop) {
    var bitmap by remember(model.account, video.key()) { mutableStateOf<Bitmap?>(model.artwork?.cached(video)) }
    LaunchedEffect(model.account, video.key()) {
        if (bitmap == null) {
            val mini = withContext(Dispatchers.Default) { runCatching { val bytes = Base64.decode(video.data.optString("mini"), Base64.DEFAULT); BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }.getOrNull() }
            if (bitmap == null) bitmap = mini
        }
    }
    DisposableEffect(model.account, video.key()) {
        var active = true
        model.artwork?.load(video) { image -> if (active) bitmap = image }
        onDispose { active = false }
    }
    if (bitmap != null) Image(bitmap!!.asImageBitmap(), null, modifier, contentScale = scale)
    else Box(modifier.background(Brush.linearGradient(listOf(Color(0xFF343843), Color(0xFF191A21)))), contentAlignment = Alignment.Center) { Icon(CineIcons.LocalMovies, null, tint = Color.White.copy(alpha = .18f), modifier = Modifier.size(50.dp)) }
}
@Composable private fun VideoMenu(activity: MainActivity, model: LibraryModel, video: Video, expanded: Boolean, dismiss: () -> Unit) {
    val id = SavedStore.id(video)
    Box {
        DropdownMenu(expanded, dismiss) {
            fun action(run: () -> Unit) { dismiss(); run() }
            DropdownMenuItem(text = { Text(if (id in model.favorites) "Remove from Favorites" else "Add to Favorites") }, onClick = { action { model.toggle(video, "Favorites") } })
            DropdownMenuItem(text = { Text(if (id in model.watchlist) "Remove from Watchlist" else "Add to Watchlist") }, onClick = { action { model.toggle(video, "Watchlist") } })
            HorizontalDivider()
            DropdownMenuItem(text = { Text("Play / Resume") }, onClick = { action { activity.open(video) } })
            DropdownMenuItem(text = { Text("Start over") }, onClick = { action { activity.open(video, false) } })
            DropdownMenuItem(text = { Text(if (model.downloadStates[id] in listOf("Paused", "Cancelled")) "Resume download" else "Download") }, enabled = !model.busy && id !in model.preparing && model.downloadStates[id] != "Downloading", onClick = { action { model.download(video) } })
            DropdownMenuItem(text = { Text("Pause download") }, enabled = model.downloadStates[id] == "Downloading", onClick = { action { model.pauseDownload(video) } })
            DropdownMenuItem(text = { Text("Save to device…") }, enabled = !model.busy, onClick = { action { activity.export(video) } })
            DropdownMenuItem(text = { Text("Mark watched") }, onClick = { action { model.mark(video) } })
            DropdownMenuItem(text = { Text("Remove history") }, onClick = { action { model.removeHistory(video) } })
        }
    }
}

@Composable private fun ChannelPicker(model: LibraryModel) {
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()
    ModalBottomSheet(modifier = Modifier.fillMaxHeight(.95f), sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), onDismissRequest = model::closeChannels, containerColor = MaterialTheme.colorScheme.surface, tonalElevation = 0.dp) {
        val dialogView = LocalView.current
        val light = MaterialTheme.colorScheme.surface.luminance() > .5f
        fun applyBars() { (dialogView.parent as? androidx.compose.ui.window.DialogWindowProvider)?.window?.let { window ->
            WindowCompat.getInsetsController(window, dialogView).apply { isAppearanceLightStatusBars = light; isAppearanceLightNavigationBars = light }
        } }
        SideEffect { applyBars() }
        DisposableEffect(dialogView, light) {
            val listener = android.view.ViewTreeObserver.OnWindowFocusChangeListener { if (it) applyBars() }
            dialogView.viewTreeObserver.addOnWindowFocusChangeListener(listener)
            onDispose { if (dialogView.viewTreeObserver.isAlive) dialogView.viewTreeObserver.removeOnWindowFocusChangeListener(listener) }
        }
        Column(Modifier.fillMaxSize().outsideKeyboard().padding(horizontal = 20.dp)) {
            Row(Modifier.heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) { Text("Channels", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold); TextButton(onClick = { scope.launch { list.scrollToItem(0) } }, enabled = list.canScrollBackward) { Text("Top") }; TextButton(onClick = model::closeChannels) { Text("Done") } }
            Text("Select sources for your library. Use the arrow to browse an added source.", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
            OutlinedTextField(model.channelQuery, model::channelFilter, Modifier.fillMaxWidth().padding(vertical = 10.dp).inputArea(), singleLine = true, label = { Text("Search channels and groups") }, leadingIcon = { Icon(Icons.Default.Search, null) }, trailingIcon = { if (model.channelQuery.isNotEmpty()) IconButton(onClick = { model.channelFilter("") }) { Icon(Icons.Default.Close, "Clear channel search") } else Spacer(Modifier.size(48.dp)) }, keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { model.searchChannels() }))
            if (model.channelSearchLoading) Row(Modifier.fillMaxWidth().padding(bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) { CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp); Text("  Searching channels…", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall) }
            if (model.channelSearchError.isNotBlank()) Text(model.channelSearchError, Modifier.fillMaxWidth().padding(bottom = 8.dp), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            if (model.channelScanError.isNotBlank()) Text(model.channelScanError, Modifier.fillMaxWidth().padding(bottom = 8.dp), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            if (model.scanning) LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp))
            val sources = model.channels.filter { it.title().contains(model.channelQuery, ignoreCase = true) || it.id() in model.channelSearchMatches }
            LazyColumn(Modifier.weight(1f), state = list, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                items(sources, key = { it.id() }) { source ->
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable(role = Role.Checkbox, onClickLabel = if (source.selected()) "Remove ${source.title()}" else "Add ${source.title()}") { model.select(source) }.padding(start = 4.dp, end = 0.dp, top = 4.dp, bottom = 4.dp).semantics { stateDescription = if (source.selected()) "Selected" else "Not selected" }, verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(source.selected(), onCheckedChange = null)
                        Text(source.title(), Modifier.weight(1f).padding(horizontal = 10.dp), fontSize = 15.sp)
                        if (source.selected()) IconButton(onClick = { model.browse(source) }) { Icon(CineIcons.ChevronRight, "Browse ${source.title()}") } else Spacer(Modifier.size(48.dp))
                    }
                }
                if (sources.isEmpty()) item { Text(if (model.channelSearchLoading) "Looking for matching channels and groups…" else if (model.scanning) "Finding channels and groups…" else if (model.channelQuery.isBlank()) "No channels found yet" else "No matching channels yet. Try another name or continue scanning.", Modifier.padding(vertical = 20.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                item {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        TextButton(onClick = model::scanSources, enabled = !model.scanning && model.discoveryMore) { Text(if (model.scanning) "Finding sources…" else "Find more / Retry") }
                        if (model.channelQuery.isNotBlank()) TextButton(onClick = model::searchChannels, enabled = !model.channelSearchLoading) { Text(if (model.channelSearchLoading) "Searching…" else "Search channels") }
                    }
                }
            }
            Spacer(Modifier.height(20.dp))
        }
    }
}
@Composable private fun Profile(activity: MainActivity, model: LibraryModel, modifier: Modifier) {
    var confirmation by remember { mutableStateOf<String?>(null) }
    var notices by remember { mutableStateOf(false) }
    Column(modifier.verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text("Your space", fontSize = 24.sp, fontWeight = FontWeight.Bold)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Surface(shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.primaryContainer) { Icon(CineIcons.PersonOutline, null, Modifier.padding(16.dp).size(32.dp), tint = MaterialTheme.colorScheme.primary) }
            Column(Modifier.padding(start = 16.dp)) {
                Text(model.telegram.displayName.ifBlank { "Your account" }, style = MaterialTheme.typography.titleLarge)
                if (model.telegram.username.isNotBlank()) Text("@${model.telegram.username}", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        SectionTitle("Make it yours")
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            palettes.chunked(2).forEach { row -> Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { row.forEach { palette ->
                OutlinedButton(onClick = { model.theme(palette.name) }, modifier = Modifier.weight(1f), shape = RoundedCornerShape(16.dp), border = BorderStroke(if (model.palette == palette.name) 2.dp else 1.dp, if (model.palette == palette.name) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline)) {
                    Box(Modifier.size(16.dp).clip(RoundedCornerShape(8.dp)).background(palette.accent)); Spacer(Modifier.width(8.dp)); Text(palette.name, maxLines = 1)
                }
            } } }
        }
        HorizontalDivider()
        SectionTitle("Local storage")
        listOf("downloads" to "Clear downloaded media", "artwork" to "Clear artwork cache", "history" to "Clear watch history").forEach { (kind, label) -> OutlinedButton(onClick = { confirmation = kind }, enabled = !model.busy, modifier = Modifier.fillMaxWidth()) { Text(label) } }
        Text("Cleanup leaves your Favorites, Watchlist and cloud messages intact.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        HorizontalDivider()
        OutlinedButton(onClick = {}, enabled = false, modifier = Modifier.fillMaxWidth()) { Text("Request feature · unavailable") }
        Text("Created by Masalaots · @notmasalaoats", style = MaterialTheme.typography.bodyMedium)
        Row {
            TextButton(onClick = { activity.link("https://instagram.com/notmasalaoats") }) { Icon(CineIcons.CameraAlt, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Instagram") }
            TextButton(onClick = { activity.link("https://t.me/notmasalaoats") }) { Icon(Icons.Default.Send, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Community") }
        }
        TextButton(onClick = { notices = true }) { Text("Open source notices") }
        Text("Cinespice 1.2.0", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("Your session stays encrypted on this device so you can stay signed in. Cinespice does not save login codes or passwords.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedButton(onClick = { confirmation = "session" }, enabled = !model.busy, modifier = Modifier.fillMaxWidth()) { Text("Sign out") }
    }
    confirmation?.let { kind -> AlertDialog(onDismissRequest = { confirmation = null }, title = { Text(if (kind == "session") "Sign out?" else "Clear $kind?") }, text = { Text(if (kind == "session") "This ends your session and clears downloaded media on this device. Sign in again to access your account. Your account-specific library stays on this device." else "This changes local device storage. Cloud messages and saved-list membership are preserved.") }, confirmButton = { TextButton(onClick = { confirmation = null; model.clear(kind) }) { Text("Continue") } }, dismissButton = { TextButton(onClick = { confirmation = null }) { Text("Cancel") } }) }
    if (notices) {
        val text = remember { buildString {
            append("TDLib 1.8.65 · Boost Software License 1.0\nlibVLC 3.6.5 · LGPL 2.1 or later\nAndroidX, Compose, Room and Material Components · Apache 2.0\n\nNative sources are unmodified; builds strip debug symbols. Dependency sources and build instructions: android/THIRD_PARTY.md in Cinespice/Cinespice.\n\n")
            listOf("TDLib.txt", "TDLib-JNI.txt", "libVLC.txt", "Apache-2.0.txt").forEach { name -> append(activity.assets.open("licenses/$name").bufferedReader().use { it.readText() }); append("\n\n") }
        } }
        AlertDialog(onDismissRequest = { notices = false }, title = { Text("Open source notices") }, text = { Text(text, Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState()), fontSize = 12.sp) }, confirmButton = { TextButton(onClick = { notices = false }) { Text("Close") } })
    }
}
@Composable private fun Authentication(activity: MainActivity, model: LibraryModel) {
    var value by remember(model.stage) { mutableStateOf("") }
    var country by rememberSaveable { mutableStateOf("+91") }
    val focus = LocalFocusManager.current
    Column(Modifier.widthIn(max = 500.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        if (model.stage in setOf("phone", "code", "password", "email", "emailCode")) {
            TextButton(onClick = { value = ""; focus.clearFocus(); model.signOut() }, enabled = !model.busy) { Icon(Icons.Default.ArrowBack, null); Text("Back to sign in") }
        }
        Text(when (model.stage) { "phone" -> "Sign in"; "code" -> "Check your messages"; "password" -> "Two-step verification"; "email", "emailCode" -> "Check your email"; "credentials" -> "Connection needs attention"; "signoutError" -> "Sign-out needs attention"; else -> if (model.telegram.isSigningOut) "Signing out…" else "Opening your library…" }, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        if (model.stage == "signoutError") {
            Button(onClick = model::signOut, enabled = !model.busy) { Text("Retry sign-out") }
        } else if (model.stage == "credentials") {
            Text("Reconnect using this app’s sign-in configuration.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick = { model.work("Connecting…") { model.network { model.telegram.connectUsingBuildCredentials() } } }, enabled = !model.busy) { Text("Retry connection") }
        } else if (model.stage in setOf("phone", "code", "password", "email", "emailCode")) {
            if (model.stage == "phone") {
                Text("Enter your account phone number.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(country, { country = it }, Modifier.width(140.dp).inputArea(), label = { Text("Country code") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone))
            }
            val label = when(model.stage) { "phone" -> "Phone number"; "code" -> "Login code"; "password" -> "Two-step verification password"; "email" -> "Email address"; else -> "Email verification code" }
            OutlinedTextField(value, { value = it }, Modifier.fillMaxWidth().inputArea(), label = { Text(label) }, enabled = !model.busy, singleLine = true, visualTransformation = if (model.stage == "password") PasswordVisualTransformation() else VisualTransformation.None, keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = when(model.stage) { "phone" -> KeyboardType.Phone; "code", "emailCode" -> KeyboardType.Number; "email" -> KeyboardType.Email; "password" -> KeyboardType.Password; else -> KeyboardType.Text }, imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }))
            if (model.stage == "password") Text("Enter your account’s two-step verification password. Cinespice does not save it.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (model.stage == "code") Text("Check messages on a device where you are already signed in; the code may arrive there instead of by SMS.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(onClick = {
                val input = if (model.stage == "phone") country.trim() + value.filter { it in '0'..'9' } else value
                if (model.stage == "phone" && (!country.trim().matches(Regex("\\+[1-9][0-9]{0,2}")) || input.length !in 4..16)) model.message("Enter a valid country code and phone number.")
                else {
                    if (model.stage in setOf("password", "code", "emailCode")) value = ""
                    focus.clearFocus(); model.work("Checking sign-in…") { model.network { model.telegram.authenticate(input) } }
                }
            }, enabled = !model.busy && value.isNotBlank(), modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), shape = RoundedCornerShape(50)) { Text(if (model.busy) "Connecting…" else "Continue") }
            if (model.stage == "code") TextButton(onClick = { model.work("Requesting another code…") { model.network { model.telegram.request(Json.obj("@type", "resendAuthenticationCode")) } } }, enabled = !model.busy) { Text("Didn't receive a code? Resend") }
        } else { LinearProgressIndicator(Modifier.fillMaxWidth()) }
        if (model.status.isNotBlank()) Text(model.status, color = MaterialTheme.colorScheme.error, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        Spacer(Modifier.height(24.dp))
    }
}

private val LocalInputAreas = staticCompositionLocalOf { mutableMapOf<Any, androidx.compose.ui.geometry.Rect>() }
@Composable private fun Modifier.inputArea(): Modifier {
    val areas = LocalInputAreas.current
    val token = remember { Any() }
    DisposableEffect(token) { onDispose { areas.remove(token) } }
    return this.onGloballyPositioned { areas[token] = it.boundsInRoot() }
}
