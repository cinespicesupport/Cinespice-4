package app.cinespice.android

import android.app.Application
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

class LibraryModel(application: Application, private val saved: SavedStateHandle) : AndroidViewModel(application), Telegram.Listener {
    internal val telegram = (application as CinespiceApp).telegram
    private val preferences = application.getSharedPreferences("cinespice", 0)
    var stage by mutableStateOf(telegram.stage); private set
    var accessMessage by mutableStateOf(telegram.access.message); private set
    var accessMissing by mutableStateOf<Set<Int>>(emptySet()); private set
    var accessNeedsPaid by mutableStateOf(false); private set
    var accessRevoked by mutableStateOf(false); private set
    var accessBusy by mutableStateOf(false); private set
    internal var announcement by mutableStateOf<org.json.JSONObject?>(null); private set
    internal var notifications by mutableStateOf<List<org.json.JSONObject>>(emptyList()); private set
    var notificationsVisible by mutableStateOf(false); private set
    var notificationsLoading by mutableStateOf(false); private set
    var notificationsMore by mutableStateOf(true); private set
    var notificationsError by mutableStateOf(""); private set
    fun showNotifications() { notificationsVisible = true; loadNotifications(true) }
    fun closeNotifications() { notificationsVisible = false }
    fun loadNotifications(refresh: Boolean) = viewModelScope.launch { withContext(Dispatchers.IO) { telegram.access.loadAnnouncements(refresh) } }
    fun dismissAnnouncement() { telegram.access.dismiss(); announcement = null }
    fun accessAction(start: Boolean) = viewModelScope.launch { withContext(Dispatchers.IO) { telegram.access.verify(start) } }
    fun joinCommunity(url: String) = viewModelScope.launch { withContext(Dispatchers.IO) { telegram.access.join(url) } }
    var page by mutableStateOf((saved.get<String>("page") ?: "home").let { when (it) { "channels" -> "home"; "favorites", "history" -> "library"; else -> it } }); private set
    var chat by mutableLongStateOf(saved.get<Long>("chat") ?: 0); private set
    var chatTitle by mutableStateOf(saved.get<String>("chatTitle") ?: ""); private set
    var query by mutableStateOf(saved.get<String>("query") ?: ""); private set
    var collectionQuery by mutableStateOf(saved.get<String>("collectionQuery") ?: ""); private set
    var channelQuery by mutableStateOf(saved.get<String>("channelQuery") ?: ""); private set
    var savedList by mutableStateOf(saved.get<String>("savedList") ?: "New Releases"); private set
    var palette by mutableStateOf(canonicalTheme(preferences.getString("cinespice.theme", "Cinespice Dark")!!)); private set
    var sort by mutableIntStateOf(preferences.getInt("sort", 0)); private set
    var channelsVisible by mutableStateOf(false); private set
    var status by mutableStateOf(""); private set
    var busy by mutableStateOf(false); private set
    var searching by mutableStateOf(false); private set
    var collectionSearching by mutableStateOf(false); private set
    var scanning by mutableStateOf(false); private set
    var discoveryMore by mutableStateOf(true); private set
    var searchError by mutableStateOf(""); private set
    var searchMore by mutableStateOf(true); private set
    var collectionSearchMore by mutableStateOf(true); private set
    var collectionSearchError by mutableStateOf(""); private set
    var collectionMore by mutableStateOf(true); private set
    internal var videos by mutableStateOf<List<Video>>(emptyList()); private set
    internal var channels by mutableStateOf<List<Library.Chat>>(emptyList()); private set
    internal var history by mutableStateOf<List<Video>>(emptyList()); private set
    internal var continuing by mutableStateOf<List<Video>>(emptyList()); private set
    internal var searchResults by mutableStateOf<List<Video>>(emptyList()); private set
    internal var collectionSearchResults by mutableStateOf<List<Video>>(emptyList()); private set
    internal var lastSearch by mutableStateOf<Video?>(null); private set
    var favorites by mutableStateOf<Set<String>>(emptySet()); private set
    var watchlist by mutableStateOf<Set<String>>(emptySet()); private set
    var downloadStates by mutableStateOf<Map<String, String>>(emptyMap()); private set
    var preparing by mutableStateOf<Set<String>>(emptySet()); private set
    var account by mutableLongStateOf(-1); private set
    var day by mutableLongStateOf(System.currentTimeMillis() / 86_400_000); private set
    private var store: SavedStore? = null
    private var reloadJob: Job? = null
    private var downloadTick: Job? = null
    private var reloadEpoch = 0L
    private val launchSeed = java.util.UUID.randomUUID().toString()
    internal var homeRails by mutableStateOf<Map<Long, List<Video>>>(emptyMap()); private set
    internal var positions by mutableStateOf<Map<String, Long>>(emptyMap()); private set
    private data class LibraryRows(val channels: List<Library.Chat>, val videos: List<Video>, val history: List<Video>, val continuing: List<Video>, val favorites: Set<String>, val watchlist: Set<String>, val downloads: Map<String, String>, val rails: Map<Long, List<Video>>, val positions: Map<String, Long>)
    internal var artwork: Artwork? = null; private set
    private var scan: Job? = null
    private var channelSearchJob: Job? = null
    private var channelSearchEpoch = 0L
    private var queryJob: Job? = null
    private var collectionQueryJob: Job? = null
    private var session: SearchSession? = null
    private var collectionSession: SearchSession? = null
    private var queryEpoch = 0L
    private var collectionQueryEpoch = 0L
    private val loader = Mutex()
    private val sourceLoader = Mutex()
    var channelSearchLoading by mutableStateOf(false); private set
    var channelSearchError by mutableStateOf(""); private set
    var channelScanError by mutableStateOf(""); private set
    var channelSearchMatches by mutableStateOf<Set<Long>>(emptySet()); private set
    init { telegram.listen(this); changed() }
    override fun changed() {
        if (stage != telegram.stage) status = ""
        stage = telegram.stage
        notifications = telegram.access.notifications; notificationsLoading = telegram.access.notificationsLoading; notificationsMore = telegram.access.notificationsMore; notificationsError = telegram.access.notificationsError
        if (stage != "ready") notificationsVisible = false
        accessMissing = telegram.access.missing; accessNeedsPaid = telegram.access.needsPaid; accessRevoked = telegram.access.revoked
        accessMessage = telegram.access.message; accessBusy = telegram.access.busy; announcement = telegram.access.announcement
        if (stage == "ready" && account != telegram.library?.accountId) {
            scan?.cancel(); queryJob?.cancel(); collectionQueryJob?.cancel(); session = null; collectionSession = null; queryEpoch++; collectionQueryEpoch++
            store?.close(); artwork?.close()
            account = telegram.requireLibrary().accountId
            store = SavedStore.open(getApplication(), account)
            artwork = Artwork(telegram, File(getApplication<Application>().cacheDir, "artwork_$account"))
            discoveryMore = true; lastSearch = null; collectionSearchResults = emptyList(); collectionSearchError = ""
            reload { reconcileDownloads() }
        } else if (stage != "ready" && account != -1L) {
            scan?.cancel(); queryJob?.cancel(); collectionQueryJob?.cancel(); store?.close(); store = null; artwork?.close(); artwork = null
            reloadEpoch++; reloadJob?.cancel(); homeRails = emptyMap(); positions = emptyMap(); account = -1; videos = emptyList(); history = emptyList(); continuing = emptyList(); channels = emptyList()
            favorites = emptySet(); watchlist = emptySet(); downloadStates = emptyMap(); lastSearch = null
            channelsVisible = false; navigate("home"); searchResults = emptyList(); collectionSearchResults = emptyList(); preparing = emptySet()
        }
        if (telegram.error.isNotEmpty()) status = telegram.error
    }
    fun foreground() { telegram.access.enforce(); if (stage != telegram.stage) changed(); day = System.currentTimeMillis() / 86_400_000; if (stage == "ready") reload() }
    internal fun reload(onLoaded: (() -> Unit)? = null) {
        telegram.access.enforce()
        if (stage != "ready" || telegram.stage != "ready") return
        val library = telegram.requireLibrary()
        val entries = store?.entries()
        val owner = account
        val token = ++reloadEpoch
        reloadJob?.cancel()
        reloadJob = viewModelScope.launch {
            try {
                val rows = withContext(Dispatchers.IO) {
                    val sources = library.chats(false)
                    val media = library.videos(0, "", false, 10000)
                    val recent = library.recentHistory(5)
                    val resume = library.videos(0, "", true, 12)
                    LibraryRows(sources, media, recent, resume,
                        entries?.members("Favorites")?.toSet().orEmpty(), entries?.members("Watchlist")?.toSet().orEmpty(),
                        entries?.downloads()?.associate { it.id to it.state }.orEmpty(),
                        media.groupBy { it.chatId }.mapValues { (_, titles) -> titles.sortedWith(compareBy<Video> { (launchSeed + it.key()).hashCode() }.thenBy { it.key() }).take(15) },
                        resume.associate { it.key() to library.position(it.key()) })
                }
                if (owner != account || token != reloadEpoch || stage != "ready") return@launch
                channels = rows.channels; videos = rows.videos; history = rows.history; continuing = rows.continuing
                favorites = rows.favorites; watchlist = rows.watchlist; downloadStates = rows.downloads
                homeRails = rows.rails; positions = rows.positions
                val selected = rows.channels.filter { it.selected() }.map { it.id() }.toSet()
                searchResults = searchResults.filter { it.chatId in selected }
                if (lastSearch?.chatId !in selected) lastSearch = null
                onLoaded?.invoke()
                if (page == "search" && query.isNotBlank() && session == null && !searching) search(query)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (owner == account && token == reloadEpoch) status = e.message ?: "Could not load your library." }
        }
    }
    // Changed on the main thread before every explicit transfer action.
    // A status reply from an older pause/resume cycle cannot overwrite the new one.
    private var transferRevision = 0L
    fun tick() {
        telegram.access.enforce()
        if (stage != telegram.stage) changed()
        if (stage != "ready" || downloadTick?.isActive == true) return
        val pending = videos.filter { downloadStates[SavedStore.id(it)] == "Downloading" }
        if (pending.isEmpty()) return
        val owner = account; val generation = telegram.generation; val entries = store?.entries() ?: return
        val revision = transferRevision
        downloadTick = viewModelScope.launch {
            try {
                val results = withContext(Dispatchers.IO) {
                    pending.map { video ->
                        telegram.check(generation)
                        SavedStore.id(video) to telegram.downloadStatus(video, "Downloading")
                    }
                }
                if (owner != account || generation != telegram.generation || revision != transferRevision) return@launch
                // Apply on main, atomically with respect to user actions and their revision changes.
                var modified = false
                results.forEach { (id, next) ->
                    if (next != "Downloading" && entries.updateDownloadIfCurrent(id, "Downloading", next) > 0) modified = true
                }
                if (modified) reload()
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (owner == account && revision == transferRevision) status = "Could not update downloads." }
        }
    }
    fun navigate(destination: String) {
        page = destination; saved["page"] = destination
        if (destination != "search") { queryJob?.cancel(); searching = false }
        if (destination != "collection") { collectionQueryEpoch++; collectionQueryJob?.cancel(); collectionSearching = false }
        if (destination == "downloads") reconcileDownloads()
        if (destination == "search" && query.isNotBlank() && session == null) search(query)
        if (destination == "collection" && collectionQuery.isNotBlank() && collectionSession == null) searchCollection(collectionQuery)
    }
    internal fun browse(source: Library.Chat) {
        closeChannels(false); chat = source.id(); chatTitle = source.title()
        collectionQuery = ""; saved["collectionQuery"] = ""; collectionSearchResults = emptyList(); collectionSearchMore = true
        collectionSearchError = ""; collectionSession = null; collectionQueryEpoch++; collectionQueryJob?.cancel(); collectionSearching = false
        saved["chat"] = chat; saved["chatTitle"] = chatTitle; collectionMore = true; navigate("collection")
        val target = chat
        work("Loading collection…") { collectionMore = network { loader.withLock { telegram.page(target, false) } }; reload() }
    }
    fun setList(value: String) { savedList = value; saved["savedList"] = value }
    fun theme(value: String) { palette = value; preferences.edit().putString("cinespice.theme", value).apply() }
    fun order(value: Int) { sort = value; preferences.edit().putInt("sort", value).apply() }
    internal fun sorted(input: List<Video>) = VideoSort.sorted(input, sort)
    internal fun toggle(video: Video, list: String) {
        val library = telegram.requireLibrary()
        val id = SavedStore.id(video); val entries = store?.entries() ?: return
        val removing = id in if (list == "Favorites") favorites else watchlist
        work("Updating $list…") {
            network { library.save(video); if (removing) entries.remove(id, list) else entries.put(SavedStore.Member(id, list)) }
            val members = if (list == "Favorites") favorites else watchlist
            val updated = if (removing) members - id else members + id
            if (list == "Favorites") favorites = updated else watchlist = updated
            if (videos.none { it.key() == video.key() }) reload()
            status = if (removing) "Removed from $list" else "Saved to $list"
        }
    }
    fun showChannels() { channelsVisible = true; scanSources(); if (channelQuery.isNotBlank()) searchChannels(channelQuery) }
    fun closeChannels() = closeChannels(true)
    private fun closeChannels(loadSelected: Boolean) {
        channelsVisible = false; scan?.cancel(); scan = null; scanning = false
        channelSearchEpoch++; channelSearchJob?.cancel(); channelSearchJob = null
        channelSearchLoading = false
        if (loadSelected && stage == "ready") {
            val targets = channels.filter { it.selected() }
            if (targets.isNotEmpty()) work("Loading selected channels…") {
                val failed = mutableListOf<String>()
                for (source in targets) {
                    try { network { loader.withLock { telegram.page(source.id(), false) } } }
                    catch (e: CancellationException) { throw e }
                    catch (_: Exception) { failed += source.title() }
                }
                reload()
                if (failed.isNotEmpty()) status = "Could not load videos from ${failed.size} selected source${if (failed.size == 1) "" else "s"}. Open a source to retry."
            }
        }
    }
    fun channelFilter(value: String) {
        channelQuery = value; saved["channelQuery"] = value
        searchChannels(value)
    }
    internal fun select(source: Library.Chat) { work("Updating sources…") {
        network { telegram.requireLibrary().select(source.id(), !source.selected()) }
        queryEpoch++; queryJob?.cancel(); session = null; searching = false; searchError = ""
        reload()
    } }
    fun scanSources() {
        if (scan?.isActive == true || !discoveryMore) return
        val generation = telegram.generation
        scan = viewModelScope.launch {
            scanning = true; channelScanError = ""
            try {
                while (channelsVisible && discoveryMore) {
                    discoveryMore = withContext(Dispatchers.IO) { sourceLoader.withLock { telegram.discover() } }
                    if (generation != telegram.generation) return@launch
                    reload(); delay(500)
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { channelScanError = "Could not load channels: ${e.message ?: "Try again."}"; status = "${e.message} · Retry finding channels" }
            finally { scanning = false }
        }
    }
    fun searchChannels() = searchChannels(channelQuery)
    private fun searchChannels(value: String) {
        val filter = value.trim()
        channelSearchEpoch++
        val token = channelSearchEpoch
        channelSearchJob?.cancel()
        channelSearchError = ""
        channelSearchMatches = emptySet()
        if (filter.isEmpty() || stage != "ready") { channelSearchLoading = false; return }
        channelSearchLoading = true
        channelSearchJob = viewModelScope.launch {
            try {
                delay(450)
                val matches = withContext(Dispatchers.IO) { sourceLoader.withLock { telegram.searchChats(filter) } }
                if (token == channelSearchEpoch && channelsVisible) { channelSearchMatches = matches; reload() }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                if (token == channelSearchEpoch) channelSearchError = "Channel search failed: ${e.message ?: "Try again."}"
            } finally {
                if (token == channelSearchEpoch) channelSearchLoading = false
            }
        }
    }
    fun search(value: String) {
        val sameQuery = query.trim() == value.trim()
        query = value; saved["query"] = value; session = null; queryEpoch++
        val token = queryEpoch; queryJob?.cancel(); if (!sameQuery || value.isBlank()) searchResults = emptyList(); searchError = ""; searching = value.isNotBlank(); searchMore = true
        if (value.isBlank()) { searching = false; return }
        queryJob = viewModelScope.launch {
            delay(450)
            val selected = channels.filter { it.selected() }
            val current = SearchSession(telegram, selected, value.trim()); session = current
            if (!sameQuery) searchResults = sorted(videos.filter { it.displayTitle.contains(value.trim(), true) || it.name.contains(value.trim(), true) || it.caption.contains(value.trim(), true) })
            try {
                searchMore = withContext(Dispatchers.IO) { loader.withLock { current.next() } }
                if (token == queryEpoch) { reload { if (token == queryEpoch) { mergeSearch(current); lastSearch = searchResults.firstOrNull() } } }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (token == queryEpoch) { mergeSearch(current); searchError = "Search could not finish. Results already found are kept. Check your connection and retry." } }
            finally { if (token == queryEpoch) searching = false }
        }
    }
    private fun mergeSearch(current: SearchSession) {
        val selected = channels.filter { it.selected() }.map { it.id() }.toSet()
        searchResults = sorted((searchResults + videos.filter { it.displayTitle.contains(query.trim(), true) || it.name.contains(query.trim(), true) || it.caption.contains(query.trim(), true) } + current.results.values).filter { it.chatId in selected }.distinctBy { it.key() })
    }
    fun moreSearch() {
        if (searching) return
        val current = session ?: run { search(query); return }
        val token = queryEpoch
        searching = true; searchError = ""
        queryJob = viewModelScope.launch {
            try {
                searchMore = withContext(Dispatchers.IO) { loader.withLock { current.next() } }
                if (token == queryEpoch) { reload { if (token == queryEpoch) { mergeSearch(current); lastSearch = searchResults.firstOrNull() } } }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (token == queryEpoch) { mergeSearch(current); searchError = "Search could not finish. Results already found are kept. Check your connection and retry." } }
            finally { if (token == queryEpoch) searching = false }
        }
    }
    fun searchCollection(value: String) {
        val sameQuery = collectionQuery.trim() == value.trim()
        collectionQuery = value; saved["collectionQuery"] = value; collectionSession = null; collectionQueryEpoch++
        val token = collectionQueryEpoch; collectionQueryJob?.cancel(); if (!sameQuery || value.isBlank()) collectionSearchResults = emptyList()
        collectionSearching = value.isNotBlank(); collectionSearchMore = true; collectionSearchError = ""
        if (value.isBlank()) { collectionSearching = false; return }
        val targetChat = chat
        val source = channels.firstOrNull { it.id() == targetChat } ?: run { collectionSearching = false; return }
        collectionQueryJob = viewModelScope.launch {
            delay(450)
            val current = SearchSession(telegram, listOf(source), value.trim()); collectionSession = current
            if (!sameQuery) collectionSearchResults = sorted(videos.filter { it.displayTitle.contains(value.trim(), true) || it.name.contains(value.trim(), true) || it.caption.contains(value.trim(), true) }.filter { it.chatId == targetChat })
            try {
                collectionSearchMore = withContext(Dispatchers.IO) { loader.withLock { current.next() } }
                if (token == collectionQueryEpoch && page == "collection" && chat == targetChat) { reload { if (token == collectionQueryEpoch && page == "collection" && chat == targetChat) mergeCollectionSearch(current) } }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (token == collectionQueryEpoch) { mergeCollectionSearch(current); collectionSearchError = "Search could not finish. Results already found are kept. Check your connection and retry." } }
            finally { if (token == collectionQueryEpoch) collectionSearching = false }
        }
    }
    private fun mergeCollectionSearch(current: SearchSession) {
        val targetChat = chat
        val cached = videos.filter { it.displayTitle.contains(collectionQuery.trim(), true) || it.name.contains(collectionQuery.trim(), true) || it.caption.contains(collectionQuery.trim(), true) }.filter { it.chatId == targetChat }
        collectionSearchResults = sorted((collectionSearchResults + cached + current.results.values).filter { it.chatId == targetChat }.distinctBy { it.key() })
    }
    fun moreCollectionSearch() {
        if (collectionSearching) return
        val current = collectionSession ?: run { searchCollection(collectionQuery); return }
        val token = collectionQueryEpoch; val targetChat = chat; collectionSearching = true; collectionSearchError = ""
        collectionQueryJob = viewModelScope.launch {
            try {
                collectionSearchMore = withContext(Dispatchers.IO) { loader.withLock { current.next() } }
                if (token == collectionQueryEpoch && page == "collection" && chat == targetChat) { reload { if (token == collectionQueryEpoch && page == "collection" && chat == targetChat) mergeCollectionSearch(current) } }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (token == collectionQueryEpoch) { mergeCollectionSearch(current); collectionSearchError = "Search could not finish. Results already found are kept. Check your connection and retry." } }
            finally { if (token == collectionQueryEpoch) collectionSearching = false }
        }
    }
    fun refresh() {
        if (page == "search") { if (query.isNotBlank()) search(query); return }
        if (page == "collection" && collectionQuery.isNotBlank()) { searchCollection(collectionQuery); return }
        val selected = channels.filter { it.selected() }.map { it.id() }
        val target = if (page == "collection") listOf(chat) else selected
        work("Refreshing newest videos…") { network { loader.withLock { target.forEach { telegram.page(it, true) } } }; reload(); status = "Newest videos refreshed" }
    }
    fun older() {
        val target = chat
        if (page == "collection" && collectionMore) work("Loading older videos…") { collectionMore = network { loader.withLock { telegram.page(target, false) } }; reload() }
    }
    internal fun download(video: Video) {
        val id = SavedStore.id(video)
        if (busy || id in preparing || downloadStates[id] == "Downloading") return
        transferRevision++
        preparing = preparing + id
        store!!.entries().putDownload(SavedStore.Download(id, "Preparing")); reload()
        val owner = account; val generation = telegram.generation
        viewModelScope.launch {
            try {
                network { telegram.download(video) }
                if (owner == account) { store?.entries()?.putDownload(SavedStore.Download(id, if (telegram.completedPath(video).isNotEmpty()) "Downloaded" else "Downloading")); status = "Download started. Keep Cinespice open." }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (owner == account && generation == telegram.generation) { store?.entries()?.putDownload(SavedStore.Download(id, "Retry download")); status = e.message ?: "Download failed" } }
            finally { if (owner == account && generation == telegram.generation) { preparing = preparing - id; reload() } }
        }
    }
    // Main-thread ownership closes the gap before a Room reload publishes Pausing.
    private val pausing = mutableMapOf<String, Long>()
    internal suspend fun preparePlayback(video: Video): Video {
        val generation = telegram.generation
        val id = SavedStore.id(video)
        while (id in preparing || pausing[id] == generation) {
            delay(50); telegram.check(generation)
        }
        val current = network { telegram.prepare(video) }
        telegram.check(generation)
        if (telegram.completedPath(current).isEmpty() && (telegram.downloads.contains(current.fileId) || downloadStates[id] in listOf("Downloading", "Preparing", "Pausing"))) {
            transferRevision++
            store?.entries()?.putDownload(SavedStore.Download(id, "Pausing"))
            try {
                network { telegram.cancelDownload(current) }
                store?.entries()?.putDownload(SavedStore.Download(id, "Paused"))
            } catch (e: Exception) {
                if (generation == telegram.generation) store?.entries()?.putDownload(SavedStore.Download(id, "Retry download"))
                throw e
            }
            reload()
        }
        return current
    }
    internal fun pauseDownload(video: Video) {
        if (busy || SavedStore.id(video) in preparing) return
        val id = SavedStore.id(video)
        transferRevision++
        store?.entries()?.putDownload(SavedStore.Download(id, "Pausing")); reload()
        val generation = telegram.generation
        pausing[id] = generation
        work("Pausing download…") {
            try { network { telegram.cancelDownload(video) }; store?.entries()?.putDownload(SavedStore.Download(id, "Paused")) }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (generation == telegram.generation) store?.entries()?.putDownload(SavedStore.Download(id, "Retry download")); throw e }
            finally {
                if (pausing[id] == generation) pausing.remove(id)
                if (generation == telegram.generation) reload()
            }
        }
    }
    internal fun mark(video: Video) { work("Updating history…") { network { telegram.requireLibrary().progress(video, video.duration * 1000L, video.duration * 1000L, true) }; reload() } }
    internal fun removeHistory(video: Video) { work("Updating history…") { network { telegram.requireLibrary().removeHistory(video.key()) }; reload() } }
    private fun reconcileDownloads() = work("Checking saved downloads…") {
        val revision = transferRevision
        val records = store?.entries()?.downloads().orEmpty()
        for (record in records) {
            val video = videos.find { SavedStore.id(it) == record.id } ?: continue
            if (record.id in preparing) continue
            try {
                val current = network { telegram.prepare(video) }
                val state = network { telegram.downloadStatus(current, record.state) }
                if (revision == transferRevision) store?.entries()?.updateDownloadIfCurrent(record.id, record.state, state)
            } catch (e: CancellationException) { throw e }
            catch (_: Exception) { if (revision == transferRevision && record.state !in listOf("Paused", "Cancelled")) store?.entries()?.updateDownloadIfCurrent(record.id, record.state, "Retry download") }
        }
        reload()
    }
    fun signOut() = work("Signing out…") { withContext(Dispatchers.IO) { telegram.signOut() } }
    fun clear(kind: String) {
        if (kind == "downloads" && preparing.isNotEmpty()) { status = "Wait for download preparation to finish, then clear downloads."; return }
        if (kind == "session") { signOut(); return }
        work("Clearing $kind…") {
            when (kind) {
                "history" -> telegram.requireLibrary().clearHistory()
                "downloads" -> { transferRevision++; network { telegram.clearDownloads() }; store?.entries()?.clearDownloads() }
                "artwork" -> { network { telegram.request(Json.obj("@type", "optimizeStorage", "size", 0, "ttl", 0, "count", 0, "immunity_delay", 0, "file_types", org.json.JSONArray().put(Json.obj("@type", "fileTypeThumbnail")))) }; artwork?.clear() }
            }
            reload(); status = "$kind cleared"
        }
    }
    internal suspend fun <T> network(block: suspend () -> T): T {
        val generation = telegram.generation
        val result = withContext(Dispatchers.IO) {
            if (generation != telegram.generation) throw CancellationException("Account changed")
            block()
        }
        if (generation != telegram.generation) throw CancellationException("Account changed")
        return result
    }
    internal fun work(message: String, block: suspend () -> Unit) {
        if (busy) return
        busy = true; status = message
        val owner = telegram.generation
        viewModelScope.launch {
            try {
                block()
                if (owner != telegram.generation) return@launch
                if (status == message) status = ""
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { if (owner == telegram.generation) status = e.message ?: "Operation failed. Try again." }
            finally { busy = false }
        }
    }
    fun message(value: String) { status = value }
    override fun onCleared() { reloadEpoch++; reloadJob?.cancel(); telegram.unlisten(this); scan?.cancel(); channelSearchJob?.cancel(); queryJob?.cancel(); collectionQueryJob?.cancel(); store?.close(); artwork?.close() }
}
