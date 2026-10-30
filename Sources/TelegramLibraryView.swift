import SwiftUI
import UIKit

struct TelegramLibraryView: View {
    @AppStorage("cinespice.theme") private var theme: CinespiceTheme = .dark
    @AppStorage("cinespice.order") private var order: LibraryOrder = .latestRelease
    @Environment(\.scenePhase) private var scenePhase
    @State private var dailySeed = Int(Date().timeIntervalSince1970 / 86400)
    @State private var savedList = "New Releases"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var posterWidth: CGFloat = 136
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var librarySelection
    @State private var lastSearchVideo: TelegramVideo?
    @State private var refreshMessage = ""
    @EnvironmentObject private var telegram: TelegramClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var rangeServer: TelegramRangeServer
    @State private var countryCode = "+91"
    @State private var homeSeed = UUID().uuidString
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var email = ""
    @State private var emailCode = ""
    @State private var tab = 0
    @State private var viewport = CGSize(width: 390, height: 844)
    @State private var heroSelection = 0
    @ScaledMetric(relativeTo: .title2) private var heroDetailsHeight: CGFloat = 184
    @ScaledMetric(relativeTo: .subheadline) private var heroHeadingHeight: CGFloat = 24
    @FocusState private var focusedField: LoginField?
    private enum LoginField: Hashable { case country, phone, code, password, email, emailCode, search }
    private var layout: CinespiceLayout { CinespiceLayout(width: min(viewport.width, CinespiceLayout.maximumWidth)) }
    @State private var detailsVideo: TelegramVideo?
    @State private var playAfterDetails: TelegramVideo?
    @State private var exportAfterDetails: TelegramVideo?
    @State private var query = ""
    @State private var collectionQuery = ""
    @State private var scrolledDestinations: Set<Int> = []
    @State private var focusSearchRequested = false
    @State private var exportFile: VideoExport?
    @State private var exportDirectory: URL?
    @State private var exporting = false
    @State private var collection: TelegramChat?
    @State private var showCollections = false
    @State private var showSettings = false
    @State private var showNotifications = false
    @State private var expandedAnnouncement: AccessAnnouncement?
    @State private var selection: PlaybackSelection?
    @State private var openingToken = UUID()
    @State private var openingID: String?
    @State private var openingTitle = ""
    @State private var openTask: Task<Void, Never>?
    @State private var playbackError = ""

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()
                if telegram.stage == .ready { libraryScreen.disabled(openingID != nil).accessibilityHidden(openingID != nil) }
                else { authentication }
                if openingID != nil {
                    MediaOpeningOverlay(title: openingTitle, cancel: cancelOpening)
                        .zIndex(10)
                }
            }
            .background(GeometryReader { geometry in
                Color.clear.allowsHitTesting(false).onAppear { viewport = geometry.size }.onChange(of: geometry.size) { viewport = $0 }
            })
            .foregroundStyle(theme.text)
            .tint(theme.accent)
            .preferredColorScheme(theme.scheme)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .task { telegram.restoreSession() }
            .onChange(of: scenePhase) { if $0 == .active { telegram.enforceAccess(); dailySeed = Int(Date().timeIntervalSince1970 / 86400) } }
            .safeAreaInset(edge: .top, spacing: 0) {
                if telegram.stage == .ready, let notice = telegram.announcement {
                    AccessAnnouncementBanner(notice: notice, open: { expandedAnnouncement = notice }, dismiss: telegram.dismissAnnouncement)
                        .background(theme.surface).foregroundStyle(theme.text)
                }
            }
            .fullScreenCover(item: $expandedAnnouncement) { notice in
                AccessAnnouncementView(notice: notice) {
                    expandedAnnouncement = nil
                    if telegram.announcement?.id == notice.id { telegram.dismissAnnouncement() }
                }
            }
            .onChange(of: telegram.notifications.map(\.id)) { ids in
                if let current = expandedAnnouncement, !ids.contains(current.id) { expandedAnnouncement = nil }
            }
            .sheet(isPresented: $showNotifications) { AccessNotificationHistoryView() }
            .sheet(isPresented: $showCollections) { CollectionPicker { chat in showCollections = false; openCollection(chat) } }
            .sheet(item: $exportFile, onDismiss: {
                if let directory = exportDirectory {
                    Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
                }
                exportDirectory = nil
            }) { file in VideoExportPicker(file: file) { exportFile = nil } }
            .sheet(item: $detailsVideo, onDismiss: {
                if let video = playAfterDetails { playAfterDetails = nil; play(video) }
                else if let video = exportAfterDetails { exportAfterDetails = nil; exportVideo(video) }
            }) { video in
                VideoDetailsView(play: { playAfterDetails = video; detailsVideo = nil },
                                 download: { rangeServer.stop(); telegram.download(video) },
                                 export: { exportAfterDetails = video; detailsVideo = nil }, video: video)
            }
            .sheet(isPresented: $showSettings) { LibrarySettingsView() }
            .fullScreenCover(item: $selection) { item in
                VLCPlaybackView(selection: item, library: library) { selection = nil }
            }
            .alert("Could not open video", isPresented: Binding(get: { !playbackError.isEmpty }, set: { if !$0 { playbackError = "" } })) {
                Button("OK") { playbackError = "" }
            } message: { Text(playbackError) }
            .onChange(of: telegram.stage) { stage in
                focusedField = nil
                if stage != .code { code = "" }; if stage != .password { password = "" }; if stage != .emailCode { emailCode = "" }

                if stage != .ready {
                    cancelOpening()
                    showCollections = false; showSettings = false; showNotifications = false; expandedAnnouncement = nil
                    playAfterDetails = nil; exportAfterDetails = nil; lastSearchVideo = nil; collectionQuery = ""; focusSearchRequested = false; scrolledDestinations = []; tab = 0; savedList = "New Releases"; selection = nil; exportFile = nil; collection = nil; detailsVideo = nil; query = ""; rangeServer.stop()
                }
            }
        }
    }

    private var browseVideos: [TelegramVideo] {
        order.sort(library.videos)
    }

    private var libraryScreen: some View {
        TabView(selection: $tab) {
            libraryDestination(0).tabItem { Label("Home", systemImage: "house") }.tag(0)
            libraryDestination(2).tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(2)
            libraryDestination(1).tabItem { Label("Library", systemImage: "square.stack") }.tag(1)
            libraryDestination(3).tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag(3)
        }.tabViewStyle(.automatic)
            .toolbarBackground(theme.surface, for: .tabBar)
            .onChange(of: tab) { _ in collection = nil; focusedField = nil }
            .task(id: refreshMessage) {
                guard !refreshMessage.isEmpty else { return }
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                refreshMessage = ""
            }
            .task(id: "\(showCollections)_" + library.selectedCollections.map { String($0.id) }.joined(separator: ",")) {
                guard !showCollections else { return }
                for chat in library.selectedCollections { telegram.ensureChat(chat.id) }
            }
    }

    private func libraryDestination(_ destination: Int) -> some View {
        VStack(spacing: 0) {
            header
            if !refreshMessage.isEmpty { Text(refreshMessage).font(.caption).foregroundStyle(theme.muted).padding(6) }
            if exporting { ProgressView("Preparing export…").font(.caption).tint(theme.accent).padding(10) }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if tab == destination, let collection { collectionPage(collection) }
                        else {
                            switch destination {
                            case 1: personalLibraryPage
                            case 2: searchPage
                            case 3: downloadsPage
                            default: home
                            }
                        }
                        if !library.error.isEmpty { banner(library.error) }
                        if !telegram.status.isEmpty { banner(telegram.status) }
                    }.id("library-top")
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: LibraryScrolledKey.self, value: geometry.frame(in: .named("library-scroll")).minY < -300)
                        }).padding(.bottom, 100).frame(maxWidth: CinespiceLayout.maximumWidth).frame(maxWidth: .infinity)
                }.coordinateSpace(name: "library-scroll")
                    .scrollDismissesKeyboard(.interactively)
                    .id("\(tab)_\(collection?.id ?? 0)_\(library.sessionID)")
                    .onChange(of: savedList) { _ in scroll.scrollTo("library-top", anchor: .top) }
                    .onPreferenceChange(LibraryScrolledKey.self) { away in
                        if away { scrolledDestinations.insert(destination) } else { scrolledDestinations.remove(destination) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if scrolledDestinations.contains(destination) {
                            HStack(spacing: 12) {
                                Button {
                                    if collection != nil || destination == 2 {
                                        scroll.scrollTo("library-top", anchor: .top)
                                        focusedField = .search
                                    } else { focusSearchRequested = true; tab = 2 }
                                } label: { Label("Search", systemImage: "magnifyingglass") }
                                Button { focusedField = nil; scroll.scrollTo("library-top", anchor: .top) } label: { Label("Top", systemImage: "arrow.up.to.line") }
                            }.font(.callout.weight(.semibold)).buttonStyle(.borderedProminent)
                                .controlSize(.large).padding(16)
                        }
                    }
            }
        }.background(theme.background)
    }

    private var header: some View {
        HStack(spacing: 4) {
            if collection != nil {
                Button { collection = nil } label: { Image(systemName: "arrow.left").frame(width: 44, height: 44) }.accessibilityLabel("Back to library")
            }
            Button(action: refreshCurrentPage) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        if collection == nil {
                            Image("BrandMark").resizable().scaledToFit().frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
                        }
                        CinespiceWordmark().fixedSize()
                    }
                    Image("BrandMark").resizable().scaledToFit().frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
                }
            }.accessibilityLabel("Cinespice, refresh current library")
            Spacer(minLength: 0)
            Button { showNotifications = true } label: { Image(systemName: "bell").font(.system(size: 18, weight: .medium)).frame(width: 40, height: 40).background(theme.surface, in: Circle()).frame(width: 44, height: 44) }.accessibilityLabel("Notifications")
            Button { showCollections = true } label: { Image(systemName: "rectangle.stack").font(.system(size: 18, weight: .medium)).frame(width: 40, height: 40).background(theme.surface, in: Circle()).frame(width: 44, height: 44) }.accessibilityLabel("Channels and groups")
            Button { showSettings = true } label: { Image(systemName: "person.crop.circle.fill").font(.system(size: 30, weight: .regular)).foregroundStyle(theme.muted).frame(width: 44, height: 44) }.accessibilityLabel("Profile and settings")
        }.padding(.horizontal, layout.gutter).padding(.vertical, 8).frame(maxWidth: CinespiceLayout.maximumWidth).frame(maxWidth: .infinity).background(theme.background).buttonStyle(.plain)
    }

    private func refreshCurrentPage() {
        if let collection, !collectionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task { await telegram.searchVideos(collectionQuery, chatID: collection.id) }
            return
        }
        if tab == 2, collection == nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                let searched = query
                await telegram.searchVideos(searched)
                guard query == searched else { return }
                lastSearchVideo = telegram.videoSearchResults.first
            }
            refreshMessage = "Refreshing search…"
        } else if let chat = collection {
            telegram.loadChat(chat.id, refresh: true)
            refreshMessage = "Refreshing " + chat.title + "…"
        } else if !library.selectedCollections.isEmpty {
            for chat in library.selectedCollections { telegram.loadChat(chat.id, refresh: true) }
            refreshMessage = "Refreshing selected sources, one page at a time…"
        } else { refreshMessage = "Select sources using the channel icon." }
    }

    private func resultSummary(_ text: String, sorting: Bool = true) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(text).font(.caption).foregroundStyle(theme.muted)
            if sorting {
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                sortControl
            }
        }.padding(.horizontal, self.layout.gutter)
    }

    private var sortControl: some View {
        Menu {
            Picker("Sort videos", selection: $order) { ForEach(LibraryOrder.allCases, id: \.self) { Text($0.title).tag($0) } }
        } label: { Label(order.title, systemImage: "arrow.up.arrow.down").font(.caption.weight(.semibold)).frame(minHeight: 44) }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 32) {
            heroCarousel
            if !library.continueWatching.isEmpty { rail("Continue Watching", subtitle: "", videos: Array(library.continueWatching.prefix(12)), wide: false) }
            if library.selectedCollections.isEmpty {
                LibraryEmptyState(symbol: "rectangle.stack", title: "Your cinema starts here", detail: "Choose channels above to start exploring your videos.")
            }
            ForEach(library.selectedCollections) { chat in
                let videos = homeVideos(chat.id)
                VStack(alignment: .leading, spacing: 12) {
                    Button { openCollection(chat) } label: {
                        HStack {
                            Text(chat.title).font(.title3.weight(.bold)).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(theme.muted)
                        }.foregroundStyle(theme.text).padding(.horizontal, layout.gutter).frame(minHeight: 44)
                    }.accessibilityLabel("Open " + chat.title)
                    if videos.isEmpty {
                        Text("No videos loaded yet. Open this channel to browse.").font(.subheadline).foregroundStyle(theme.muted).padding(.horizontal, layout.gutter)
                    } else { posterRail(videos, wide: false) }
                }
            }
            if !telegram.loadingCollections.isEmpty { ProgressView("Loading a small page…").frame(maxWidth: .infinity).font(.caption).tint(theme.accent) }
        }
    }

    // Stable within a launch, varied on the next launch. Never changes resume ordering.
    private func homeVideos(_ chatID: Int64) -> [TelegramVideo] {
        func rank(_ id: String) -> UInt64 {
            (homeSeed + id).utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        return Array(library.videos.filter { $0.chatID == chatID }.sorted {
            let left = rank($0.id), right = rank($1.id)
            return left == right ? $0.id < $1.id : left < right
        }.prefix(15))
    }

    private var heroArtworkHeight: CGFloat {
        min(440, max(200, layout.innerWidth * (viewport.width > viewport.height ? 0.42 : 0.72)))
    }
    private var dailyVideo: TelegramVideo? {
        let items = library.videos.sorted { $0.id < $1.id }
        guard !items.isEmpty else { return nil }
        var seed = UInt64(dailySeed) &+ 0x9E3779B97F4A7C15
        seed = (seed ^ (seed >> 30)) &* 0xBF58476D1CE4E5B9
        seed = (seed ^ (seed >> 27)) &* 0x94D049BB133111EB
        return items[Int((seed ^ (seed >> 31)) % UInt64(items.count))]
    }
    private var heroCarousel: some View {
        TabView(selection: $heroSelection) {
            heroSlot("Recently added", video: LibraryOrder.newest.sort(library.videos).first, empty: "Add a source to discover your videos.").tag(0)
            heroSlot("Today's pick", video: dailyVideo, empty: "Your daily pick appears when videos are indexed.").tag(1)
            ForEach(0..<4) { index in
                heroSlot("Trending · \(index + 1)", video: nil, empty: "No trending catalogue connected yet.").tag(index + 2)
            }
            heroSlot("Last searched", video: lastSearchVideo.flatMap { library.snapshot.selected.contains($0.chatID) ? $0 : nil }, empty: "Search for a video to fill this spot.").tag(6)
        }.tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .frame(height: heroArtworkHeight + heroDetailsHeight + heroHeadingHeight + 88)
    }
    private func heroSlot(_ title: String, video: TelegramVideo?, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.muted)
                .frame(height: heroHeadingHeight, alignment: .leading)
            if let video { hero(video) }
            else {
                Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity).frame(height: heroArtworkHeight)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.title2.bold())
                    Text(empty).font(.subheadline).foregroundStyle(theme.muted)
                    Spacer(minLength: 0)
                }.frame(height: heroDetailsHeight, alignment: .top)
            }
        }.padding(.horizontal, layout.gutter).padding(.top, 12).padding(.bottom, 44)
            .frame(maxHeight: .infinity, alignment: .top).contentShape(Rectangle())
    }
    @ViewBuilder private var releaseSortHint: some View {
        if order == .latestRelease || order == .earliestRelease {
            Text("Sorted by filename year · Unknown years last").font(.caption).foregroundStyle(theme.muted).padding(.horizontal, layout.gutter)
        }
    }

    private func hero(_ video: TelegramVideo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VideoArtwork(video: video).frame(height: heroArtworkHeight)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(library.snapshot.collections.first(where: { $0.id == video.chatID })?.title ?? "Your library")
                        .font(.caption).foregroundStyle(theme.muted).lineLimit(1)
                    Text(video.displayTitle).font(.title2.bold()).lineLimit(2)
                    Text([video.formatLabel, ByteCountFormatter.string(fromByteCount: video.size, countStyle: .file),
                          video.duration > 0 ? "\(video.duration / 60) min" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(theme.muted)
                    HStack(spacing: 12) {
                        Button { play(video) } label: {
                            MediaPlayPill(progress: library.snapshot.history[video.id]?.fraction)
                        }.disabled(openingID != nil).accessibilityLabel("Play " + video.displayTitle)
                        Text(library.snapshot.history[video.id]?.canResume == true ? "Resume" : "Play").font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Button { detailsVideo = video } label: { MediaInfoIcon() }
                            .accessibilityLabel("More info about " + video.displayTitle)
                    }.buttonStyle(.plain)
                }
            }.frame(height: heroDetailsHeight, alignment: .top)
        }
    }

    private var personalLibraryPage: some View {
        let saved = library.videos.filter { library.snapshot.savedLists[savedList]?.contains($0.id) == true }
        let items = savedList == "New Releases" ? LibraryOrder.latestRelease.sort(library.videos) : order.sort(saved)
        return VStack(alignment: .leading, spacing: 16) {
            pageTitle("Library", subtitle: "")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["New Releases", "Favorites", "Watchlist", "History"], id: \.self) { category in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.85)) { savedList = category }
                        } label: {
                            Text(category).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).frame(minHeight: 44)
                                .foregroundStyle(savedList == category ? theme.text : theme.muted)
                                .background {
                                    if savedList == category {
                                        Capsule().fill(theme.surface).matchedGeometryEffect(id: "library-category", in: librarySelection)
                                    }
                                }
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(savedList == category ? .isSelected : [])
                    }
                }.padding(.horizontal, layout.gutter)
            }
            if savedList == "History" {
                if library.watchedVideos.isEmpty {
                    LibraryEmptyState(symbol: "clock", title: "Your story starts here", detail: "The videos you watch appear here, with your place saved.")
                } else { grid(Array(library.watchedVideos.prefix(5))) }
            } else {
                resultSummary(savedList == "New Releases" ? "\(items.count) titles · Filename year" : "\(items.count) titles", sorting: savedList != "New Releases")
                if savedList != "New Releases" { releaseSortHint }
                if items.isEmpty {
                    LibraryEmptyState(symbol: savedList == "New Releases" ? "film" : "bookmark",
                                      title: savedList == "New Releases" ? "Make room for your next favorite" : "Save something for later",
                                      detail: savedList == "New Releases" ? "Choose channels to bring their videos into your library." : "Touch and hold a video to add it to Favorites or Watchlist.")
                } else { grid(items) }
            }
        }
    }

    private var downloadsPage: some View {
        let items = order.sort(library.videos.filter { library.display($0).isDownloaded || telegram.downloadRecords[$0.id] != nil || telegram.fullDownloads.contains($0.fileID) || telegram.preparingDownloads.contains($0.id) })
        return VStack(alignment: .leading, spacing: 20) {
            pageTitle("Downloads", subtitle: "")
            if items.isEmpty {
                LibraryEmptyState(symbol: "arrow.down.circle", title: "Watch anywhere",
                                  detail: "Open a video’s details or touch and hold it, then choose Download. Your downloads will appear here.")
            } else {
                resultSummary("\(items.count) titles")
                releaseSortHint
                LazyVStack(spacing: 12) { ForEach(items) { card($0, compact: true) } }.padding(.horizontal, layout.gutter)
            }
        }.task { await telegram.reconcileDownloads() }
    }

    private func collectionPage(_ chat: TelegramChat) -> some View {
        let text = collectionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = browseVideos.filter { $0.chatID == chat.id && (text.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(text) || ($0.fileName?.localizedCaseInsensitiveContains(text) == true) || ($0.caption?.localizedCaseInsensitiveContains(text) == true)) }
        let merged = Dictionary((local + (text.isEmpty ? [] : telegram.videoSearchResults.filter { $0.chatID == chat.id })).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let items = order.sort(Array(merged.values))
        let cachedIndex = library.snapshot.indexes[chat.id]
        return VStack(alignment: .leading, spacing: 20) {
            pageTitle(chat.title, subtitle: chat.isOwner == true ? "YOUR CHANNEL" : "YOUR SELECTION")
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search this channel", text: $collectionQuery).textInputAutocapitalization(.never).focused($focusedField, equals: .search).submitLabel(.search)
                if !collectionQuery.isEmpty { Button { collectionQuery = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }.accessibilityLabel("Clear channel search") }
            }.frame(minHeight: 44).padding(.horizontal, 15).background(theme.surface, in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal, layout.gutter)
            resultSummary("\(items.count) " + (text.isEmpty ? "cached titles" : "channel results"))
            if order == .oldest { Text("Oldest loaded titles first. Load another page to include earlier uploads.").font(.caption).foregroundStyle(theme.muted).padding(.horizontal, layout.gutter) }
            releaseSortHint
            grid(items)
            if !text.isEmpty {
                if telegram.isSearchingVideos { ProgressView("Searching this channel…").frame(maxWidth: .infinity) }
                else if !telegram.videoSearchError.isEmpty {
                    Text(telegram.videoSearchError).font(.caption).foregroundStyle(.orange).padding(.horizontal, layout.gutter)
                    Button("Retry channel search") { Task { await telegram.nextVideoSearchPage() } }.padding(.horizontal, layout.gutter)
                } else if telegram.hasMoreVideoResults {
                    Button("Search older messages") { Task { await telegram.nextVideoSearchPage() } }.padding(.horizontal, layout.gutter)
                } else if items.isEmpty { LibraryEmptyState(symbol: "magnifyingglass", title: "No matching videos", detail: "Try another title or filename in this channel.") }
            } else {
            if let error = telegram.collectionErrors[chat.id] { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, layout.gutter) }
            if items.isEmpty && !telegram.loadingCollections.contains(chat.id) { LibraryEmptyState(symbol: "film", title: "No cached titles", detail: "Load a page or tap Cinespice to refresh this channel.") }
            if telegram.loadingCollections.contains(chat.id) { ProgressView("Finding more videos…").frame(maxWidth: .infinity).tint(theme.accent) }
            else if cachedIndex == nil || cachedIndex?.hasMore == true {
                Button { telegram.loadChat(chat.id) } label: { Text("Load more videos").frame(minHeight: 44) }.font(.subheadline.weight(.semibold)).padding(.horizontal, layout.gutter).background(theme.surface, in: Capsule()).tint(theme.text).frame(maxWidth: .infinity)

            }
            }
        }.task(id: "\(chat.id):" + collectionQuery) {
            guard collection?.id == chat.id else { return }
            await telegram.searchVideos(collectionQuery, chatID: chat.id)
        }
    }

    private var searchPage: some View {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = text.isEmpty ? [] : browseVideos.filter { $0.displayTitle.localizedCaseInsensitiveContains(text) || $0.title.localizedCaseInsensitiveContains(text) || ($0.fileName?.localizedCaseInsensitiveContains(text) == true) }
        let merged = Dictionary((local + (text.isEmpty ? [] : telegram.videoSearchResults).filter { library.snapshot.selected.contains($0.chatID) }).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let results = order.sort(Array(merged.values))
        return VStack(alignment: .leading, spacing: 22) {
            pageTitle("Search", subtitle: "Find your next favorite.")
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(theme.muted); TextField("Video title or filename", text: $query).textInputAutocapitalization(.never).focused($focusedField, equals: .search).submitLabel(.search); if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Clear search") } }
                .frame(minHeight: 44).padding(.horizontal, 15).padding(.vertical, 4).background(theme.surface, in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal, layout.gutter)
            if text.isEmpty { LibraryEmptyState(symbol: "magnifyingglass", title: "What are you in the mood for?", detail: "Search video names and filenames in your selected channels and groups.") }
            else {
                resultSummary("\(results.count) results · \(library.selectedCollections.count) selected sources")
                releaseSortHint
                grid(results)
                if telegram.isSearchingVideos { ProgressView("Searching channels…").frame(maxWidth: .infinity).tint(theme.accent) }
                else if !telegram.videoSearchError.isEmpty {
                    Text(telegram.videoSearchError).font(.caption).foregroundStyle(.orange)
                    Button("Retry search") { Task { await telegram.nextVideoSearchPage() } }
                } else if telegram.hasMoreVideoResults {
                    Button("Search older messages") { Task { await telegram.nextVideoSearchPage() } }

                } else if library.selectedCollections.isEmpty {
                    LibraryEmptyState(symbol: "rectangle.stack", title: "Choose channels to search", detail: "Open Channels and select the groups or channels you want to search.")
                } else if results.isEmpty && !text.isEmpty { LibraryEmptyState(symbol: "magnifyingglass", title: "No matching videos", detail: "Try a different filename or select more channels and groups.") }
                LibraryPageTrigger(enabled: tab == 2 && collection == nil && telegram.hasMoreVideoResults && !telegram.isSearchingVideos && telegram.videoSearchError.isEmpty, revision: String(telegram.videoSearchResults.count), viewportHeight: viewport.height) { Task { await telegram.nextVideoSearchPage() } }
            }
        }
        .onAppear {
            if focusSearchRequested { focusedField = .search; focusSearchRequested = false }
        }
        .task(id: "\(tab == 2 && collection == nil)_" + query + library.selectedCollections.map { String($0.id) }.joined(separator: ",")) {
            guard tab == 2, collection == nil else { return }
            let searched = query
            await telegram.searchVideos(searched)
            guard !Task.isCancelled, query == searched, !searched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            lastSearchVideo = order.sort(local + telegram.videoSearchResults.filter { library.snapshot.selected.contains($0.chatID) }).first
        }
    }

    private func posterRail(_ videos: [TelegramVideo], wide: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) { ForEach(videos) { video in card(video, wide: wide).frame(width: wide ? min(320, layout.innerWidth * 0.85) : min(max(160, posterWidth * 1.2), layout.innerWidth * 0.8)) } }.padding(.horizontal, layout.gutter)
        }
    }
    private func rail(_ title: String, subtitle: String, videos: [TelegramVideo], wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle(title, detail: subtitle)
            posterRail(videos, wide: wide)
        }
    }
    private func grid(_ videos: [TelegramVideo]) -> some View {
        LazyVGrid(columns: layout.columns(minimum: posterWidth), alignment: .leading, spacing: 28) {
            ForEach(videos) { video in card(video) }
        }.padding(.horizontal, layout.gutter)
    }
    private func card(_ video: TelegramVideo, wide: Bool = false, compact: Bool = false) -> some View {
        VideoCard(video: video, wide: wide, compact: compact, opening: openingID == video.id, play: { play(video, resume: $0) }, download: { rangeServer.stop(); telegram.download(video) }, export: { exportVideo(video) }, info: { detailsVideo = video })
    }
    private func exportVideo(_ video: TelegramVideo) {
        guard !exporting else { return }; exporting = true
        let session = library.sessionID
        Task {
            defer { exporting = false }
            do {
                let current = try await telegram.prepare(video)
                let file = try await VideoExport.prepare(current)
                telegram.enforceAccess()
                guard session == library.sessionID, telegram.stage == .ready else { try? FileManager.default.removeItem(at: file.directory); return }
                exportDirectory = file.directory; exportFile = file
            } catch { playbackError = "Could not export video: \(error.localizedDescription)" }
        }
    }
    private func openCollection(_ chat: TelegramChat) { collectionQuery = ""; collection = chat; telegram.ensureChat(chat.id) }
    private func play(_ video: TelegramVideo, resume: Bool = true) {
        guard openingID == nil, selection == nil else { return }
        openingTitle = video.displayTitle
        withAnimation(.easeOut(duration: 0.15)) { openingID = video.id }
        let session = library.sessionID
        let token = UUID(); openingToken = token
        openTask = Task {
            defer { if openingToken == token { openingID = nil; openTask = nil } }
            do {
                // Persist after presentation: opening one video must not wait for
                // a full library snapshot to be decoded and published.
                let current = try await telegram.prepareForPlayback(video)
                try Task.checkCancellation()
                let url: URL
                if current.isDownloaded, !current.localPath.isEmpty { rangeServer.stop(); url = URL(fileURLWithPath: current.localPath) }
                else { url = try await rangeServer.open(video: current, using: telegram) }
                try Task.checkCancellation()
                telegram.enforceAccess()
                guard openingToken == token, library.sessionID == session, telegram.stage == .ready else { return }
                selection = PlaybackSelection(video: current, url: url, resume: resume)
                Task {
                    guard library.sessionID == session else { return }
                    if !(await library.ingest([current])), library.sessionID == session {
                        library.report("Playback opened, but its metadata could not be saved. " + library.error)
                    }
                }
            } catch is CancellationError { }
            catch { if openingToken == token { playbackError = "\(error.localizedDescription) If this file cannot stream, use Download from its menu and play the completed file." } }
        }
    }
    private func cancelOpening() {
        openingToken = UUID()
        openTask?.cancel(); openTask = nil
        openingID = nil
        rangeServer.stop()
    }
    private func pageTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.weight(.bold)).tracking(-0.8)
            if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(theme.muted) }
        }.padding(.horizontal, layout.gutter).padding(.top, 12)
    }
    private func sectionTitle(_ title: String, detail: String) -> some View { Text(title).font(.title3.weight(.bold)).padding(.horizontal, layout.gutter) }
    private func banner(_ message: String) -> some View { Text(message).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, layout.gutter).padding(.bottom, 8) }
    @ViewBuilder private var authentication: some View {
        switch telegram.stage {
        case .activation: AccessActivationView()
        case .credentials: authForm("Your private cinema.", subtitle: "Sign in to bring your channels, videos and favorites together.") {
            authButton { telegram.connectUsingBuildCredentials() }
        }
        case .phone: authForm("Sign in", subtitle: "Enter your account phone number, including its country calling code.") {
            phoneFields
            authButton { telegram.submitPhone(countryCode: countryCode, number: phone) }
        }
        case .code: authForm("Check your messages", subtitle: "Enter your login code. Check messages on a device where you are already signed in; the code may arrive there instead of by SMS.") {
            TextField("Login code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).focused($focusedField, equals: .code).frame(minHeight: 44)
            authButton { telegram.submitCode(code) }
            Button("Didn't receive a code? Resend") { telegram.resendCode() }.disabled(telegram.isAuthenticating)
        }
        case .password: authForm("Two-step verification", subtitle: "Enter your account’s two-step verification password. Cinespice does not save it.") { SecureField("Password", text: $password).focused($focusedField, equals: .password).frame(minHeight: 44); authButton { let input = password; password = ""; telegram.submitPassword(input) } }
        case .email: authForm("Your sign-in email", subtitle: "Your account requires an email address for this login.") { TextField("Email", text: $email).keyboardType(.emailAddress).focused($focusedField, equals: .email).frame(minHeight: 44); authButton { telegram.submitEmail(email) } }
        case .emailCode: authForm("Check your email", subtitle: "Enter your sign-in verification code.") { TextField("Email code", text: $emailCode).keyboardType(.numberPad).focused($focusedField, equals: .emailCode).frame(minHeight: 44); authButton { telegram.submitEmailCode(emailCode) } }
        case .loading: VStack(spacing: 32) { CinespiceWordmark(); ProgressView("Opening your library…").tint(theme.accent) }.padding(layout.gutter)
        case let .error(message): authForm("Connection needs attention", subtitle: message) { Button { telegram.resetAuth() } label: { Text("Retry connection").frame(minHeight: 44) }.buttonStyle(.borderedProminent).controlSize(.large).tint(theme.action) }
        case .ready: EmptyView()
        }
    }
    private var phoneFields: some View {
        let fields = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return fields {
            VStack(alignment: .leading, spacing: 8) {
                Text("Country code").font(.caption).foregroundStyle(theme.muted)
                TextField("+91", text: $countryCode).keyboardType(.phonePad).focused($focusedField, equals: .country).frame(minHeight: 44).accessibilityLabel("Country calling code")
            }.frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 112)
            VStack(alignment: .leading, spacing: 8) {
                Text("Phone number").font(.caption).foregroundStyle(theme.muted)
                TextField("Phone number", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber).focused($focusedField, equals: .phone).frame(minHeight: 44)
            }.frame(maxWidth: .infinity)
        }
    }
    private func authButton(_ action: @escaping () -> Void) -> some View {
        Button { focusedField = nil; action() } label: {
            HStack(spacing: 10) {
                if telegram.isAuthenticating { ProgressView().tint(theme.onAction) }
                Text(telegram.isAuthenticating ? "Connecting…" : "Continue").font(.headline)
            }.frame(maxWidth: .infinity, minHeight: 28).foregroundStyle(theme.onAction)
        }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
            .tint(theme.action).disabled(telegram.isAuthenticating)
    }
    private func authForm<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if telegram.stage != .credentials {
                        Button { focusedField = nil; telegram.restartLogin() } label: {
                            Label("Back to sign in", systemImage: "chevron.left").frame(minHeight: 44)
                        }.disabled(telegram.isAuthenticating)
                    }
                    CinespiceWordmark().padding(.bottom, 4)
                    Text(title).font(.title.bold()).tracking(-0.5)
                    Text(subtitle).font(.subheadline).foregroundStyle(theme.muted).lineSpacing(3)
                    VStack(alignment: .leading, spacing: 16) {
                        content().font(.body).textFieldStyle(.roundedBorder).controlSize(.large)
                            .textInputAutocapitalization(.never).disableAutocorrection(true)
                    }.frame(maxWidth: .infinity).id("auth-fields")
                    if !telegram.status.isEmpty {
                        Text(telegram.status).font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Color.clear.frame(height: 1).id("auth-bottom")
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(layout.gutter).padding(.top, 8).padding(.bottom, 24)
                    .frame(maxWidth: 500).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
                .onChange(of: focusedField) { field in
                    guard field != nil else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scroll.scrollTo("auth-fields", anchor: .top) }
                }
                .onChange(of: telegram.status) { _ in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scroll.scrollTo("auth-bottom", anchor: .bottom) }
                }
        }
    }
}

private struct LibraryScrolledKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
