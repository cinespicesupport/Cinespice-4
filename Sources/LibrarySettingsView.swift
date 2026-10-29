import SwiftUI

struct CollectionPicker: View {
    @AppStorage("cinespice.theme") private var theme: CinespiceTheme = .dark
    @EnvironmentObject private var telegram: TelegramClient
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""
    @State private var scope = 2
    @FocusState private var searchFocused: Bool
    var openCollection: (TelegramChat) -> Void = { _ in }
    @State private var changing: Set<Int64> = []
    @State private var visibleLimit = 30
    @State private var scanning = false
    @State private var scanRevision = 0
    private var collections: [TelegramChat] {
        TelegramChat.ownerFirst(library.snapshot.collections.filter {
            let matches = $0.isCollection && $0.matches(query)
            switch scope {
            case 0: return matches && $0.isOwner == true && $0.isChannel == true
            case 1: return matches && library.snapshot.selected.contains($0.id)
            default: return matches
            }
        })
    }
    var body: some View {
        NavigationView {
            ZStack {
                theme.background.ignoresSafeArea()
                ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        Text("Choose the channels and groups for your library.").font(.subheadline).foregroundStyle(theme.muted)
                        if dynamicTypeSize.isAccessibilitySize {
                            sourcePicker.pickerStyle(.menu).frame(minHeight: 44)
                        } else { sourcePicker.pickerStyle(.segmented) }
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(theme.muted)
                            TextField("Search your channels", text: $query).focused($searchFocused).textInputAutocapitalization(.never).disableAutocorrection(true)
                            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("Clear channel search") }
                        }.frame(minHeight: 44).padding(.horizontal, 14).padding(.vertical, 4).background(theme.surface, in: RoundedRectangle(cornerRadius: 18))
                        if telegram.isSearchingChats { ProgressView("Searching channels…").tint(theme.accent) }
                        if collections.isEmpty && !telegram.isSearchingChats {
                            Text("No matching sources yet. Search by name or scan another batch, including archived chats.")
                                .font(.subheadline).foregroundStyle(theme.muted).padding(.vertical, 12)
                        }
                        ForEach(Array(collections.prefix(visibleLimit))) { chat in
                            HStack(spacing: 0) {
                                channel(chat)
                                if library.snapshot.selected.contains(chat.id) {
                                    Button { dismiss(); openCollection(chat) } label: {
                                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                                            .foregroundStyle(theme.muted).frame(width: 44, height: 60)
                                    }.accessibilityLabel("Browse " + chat.title).disabled(!changing.isEmpty)
                                }
                            }.padding(.trailing, 8).background(theme.surface, in: RoundedRectangle(cornerRadius: 18))
                                .onAppear { if chat.id == collections.prefix(visibleLimit).last?.id { visibleLimit += 30 } }
                        }
                        if collections.count > visibleLimit { Button("Show 30 more cached results") { visibleLimit += 30 } }
                        Divider().overlay(theme.separator)
                        Text("\(library.selectedCollections.count) selected · Only selected sources appear in your library").font(.caption).foregroundStyle(theme.muted)
                        if scanning || telegram.isLoadingChats { ProgressView("Finding channels and groups…").tint(theme.accent) }
                        else if telegram.hasMoreChats {
                            Button { scanRevision += 1 } label: { Label("Continue finding sources", systemImage: "arrow.clockwise").frame(maxWidth: .infinity).padding(14).background(theme.surface, in: RoundedRectangle(cornerRadius: 18)) }
                        }
                        Text("Tap a channel to select it. Use its arrow to browse. Your own channels appear first.").font(.caption).foregroundStyle(theme.muted)
                        if !telegram.chatSearchError.isEmpty { Text(telegram.chatSearchError).foregroundStyle(.orange).font(.caption) }
                        if !library.error.isEmpty { Text(library.error).foregroundStyle(.orange).font(.caption) }
                        if !telegram.status.isEmpty { Text(telegram.status).foregroundStyle(.orange).font(.caption) }
                    }.id("channels-top").padding(24).padding(.bottom, 70).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
                    .overlay(alignment: .bottomTrailing) {
                        if collections.count > 10 {
                            HStack {
                                Button { scroll.scrollTo("channels-top", anchor: .top); searchFocused = true } label: { Label("Search", systemImage: "magnifyingglass") }
                                Button { searchFocused = false; scroll.scrollTo("channels-top", anchor: .top) } label: { Label("Top", systemImage: "arrow.up.to.line") }
                            }.buttonStyle(.borderedProminent).controlSize(.large).padding(16)
                        }
                    }
                }
            }
            .navigationTitle("Channels").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { dismiss() } label: { Text("Done").fixedSize().frame(minWidth: 52, minHeight: 44) }.buttonStyle(.plain).tint(theme.accent).disabled(!changing.isEmpty) } }
            .task(id: scanRevision) {
                scanning = true
                defer { scanning = false }
                await telegram.discoverCollections()
            }
            .task(id: "\(scope)_\(query)") { await telegram.searchCollections(query, channelsOnly: scope == 0) }
            .onChange(of: scope) { _ in visibleLimit = 30 }
            .onChange(of: query) { _ in visibleLimit = 30 }
        }.foregroundStyle(theme.text).tint(theme.accent).navigationViewStyle(.stack).preferredColorScheme(theme.scheme).presentationDragIndicator(.visible)
    }
    private var sourcePicker: some View {
        Picker("Channels to display", selection: $scope) {
            Text("My channels").tag(0); Text("Selected").tag(1); Text("All sources").tag(2)
        }
    }
    private func channel(_ chat: TelegramChat) -> some View {
        let selected = library.snapshot.selected.contains(chat.id)
        return Button {
            guard !changing.contains(chat.id) else { return }
            changing.insert(chat.id)
            Task {
                _ = await library.select(chat, selected: !selected)
                changing.remove(chat.id)
            }
        } label: {
            HStack(spacing: 14) {
                if !dynamicTypeSize.isAccessibilitySize {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(selected ? theme.accent.opacity(0.12) : theme.background)
                        Image(systemName: chat.isOwner == true ? "crown.fill" : "play.rectangle").foregroundStyle(selected ? theme.accent : theme.muted)
                    }.frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(chat.title).font(.body.weight(.semibold)).foregroundStyle(theme.text).lineLimit(2)
                    Text(chat.isOwner == true ? "Your channel" : (chat.isChannel == true ? "Channel" : "Group"))
                        .font(.caption).foregroundStyle(theme.muted)
                    if let date = chat.telegramDate, date > 0 {
                        Text(Date(timeIntervalSince1970: Double(date)), style: .date)
                            .font(.caption2).foregroundStyle(theme.muted)
                    }
                }
                Spacer()
                if changing.contains(chat.id) { ProgressView() }
                else { Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle").font(.title2).foregroundStyle(selected ? theme.accent : theme.muted) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(CinespicePressStyle()).disabled(changing.contains(chat.id))
            .accessibilityLabel("\(chat.title), \(selected ? "selected" : "not selected")")
    }
}

struct LibrarySettingsView: View {
    @AppStorage("cinespice.theme") private var theme: CinespiceTheme = .dark
    @EnvironmentObject private var telegram: TelegramClient
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var rangeServer: TelegramRangeServer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var mediaBytes: Int64 = 0
    @State private var artworkBytes = 0
    @State private var working = false
    @State private var status = ""
    @State private var confirmation: Action?
    private enum Action: String, Identifiable {
        case media, artwork, history, logout
        var id: String { rawValue }
        var title: String {
            switch self {
            case .media: return "Clear downloaded media?"
            case .artwork: return "Clear cached artwork?"
            case .history: return "Clear watch history?"
            case .logout: return "Sign out?"
            }
        }
        var detail: String {
            switch self {
            case .media: return "Removes local downloaded videos and documents. Your cloud messages, library metadata and watch history stay intact."
            case .artwork: return "Removes locally cached thumbnails. Artwork can download again as you browse."
            case .history: return "Removes saved playback positions on this iPhone. Your collections and videos are kept."
            case .logout: return "Signs out of your account. Account-specific local library history remains on this iPhone."
            }
        }
    }
    var body: some View {
        NavigationView {
            List {
                Section("Profile") {
                    HStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 48, weight: .light)).foregroundStyle(theme.muted)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(telegram.profileName.isEmpty ? "Your account" : telegram.profileName).font(.title3.weight(.semibold))
                            if !telegram.profileUsername.isEmpty { Text("@" + telegram.profileUsername).font(.subheadline).foregroundStyle(theme.muted) }
                        }
                    }.padding(.vertical, 10)
                }.listRowBackground(theme.surface)
                Section("Appearance") {
                    Picker("Color palette", selection: $theme) {
                        ForEach(CinespiceTheme.allCases) { palette in Text(palette.title).tag(palette) }
                    }
                    Text("Warm glass, cinema dark, rich crimson or cool silver. Your layout stays the same.").font(.caption).foregroundStyle(theme.muted)
                }.listRowBackground(theme.surface)
                Section("Requests") {
                    Label("Request a feature · Coming later", systemImage: "bubble.left.and.bubble.right").font(.subheadline).foregroundStyle(theme.muted)
                }.listRowBackground(theme.surface)
                Section("On this iPhone") {
                    usage("Downloaded media", bytes: mediaBytes)
                    Button("Clear downloaded media") { confirmation = .media }.disabled(working)
                    usage("Cached artwork", bytes: Int64(artworkBytes))
                    Button("Clear cached artwork") { confirmation = .artwork }.disabled(working)
                }.listRowBackground(theme.surface)
                Section("Your library") {
                    Text("\(library.videos.count) indexed videos · \(library.selectedCollections.count) collections")
                    Text("Your channels and watch history are saved on this iPhone for your account.").font(.caption).foregroundStyle(theme.muted)
                    Button("Clear watch history", role: .destructive) { confirmation = .history }.disabled(working)
                }.listRowBackground(theme.surface)
                Section("Playback") {
                    Text("Playback pauses while away and returns to the same player when you reopen the app. Force-quitting starts a fresh screen; your saved watch progress remains.").font(.caption).foregroundStyle(theme.muted)
                }.listRowBackground(theme.surface)
                Section("Cinespice") {
                    HStack(spacing: 12) {
                        Image("BrandMark").resizable().scaledToFit().frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                        Text("Created by Masalaots")
                    }
                    let links = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                    links {
                        Link(destination: URL(string: "https://instagram.com/notmasalaoats")!) { Label("Instagram", systemImage: "camera") }
                        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                        Link(destination: URL(string: "https://t.me/notmasalaoats")!) { Label("Community", systemImage: "paperplane") }
                    }
                    Text("@notmasalaoats").font(.caption).foregroundStyle(theme.muted)
                }.listRowBackground(theme.surface)
                Section("Account") {
                    Text("Your session stays encrypted on this device so you can stay signed in. Cinespice does not save login codes or passwords.").font(.caption).foregroundStyle(theme.muted)
                    Button("Sign out", role: .destructive) { confirmation = .logout }.disabled(working)
                }.listRowBackground(theme.surface)
                if working { ProgressView("Working…") }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.orange) }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(theme.background)
            .navigationTitle("Account").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { dismiss() } label: { Text("Done").fixedSize().frame(minWidth: 52, minHeight: 44) }.buttonStyle(.plain).tint(theme.accent) } }
            .task { await refreshUsage() }
            .alert(item: $confirmation) { action in
                Alert(title: Text(action.title), message: Text(action.detail), primaryButton: .destructive(Text(action == .logout ? "Sign out" : "Clear")) { perform(action) }, secondaryButton: .cancel())
            }
        }.foregroundStyle(theme.text).tint(theme.accent).navigationViewStyle(.stack).preferredColorScheme(theme.scheme).presentationDragIndicator(.visible)
    }
    private func usage(_ title: String, bytes: Int64) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(title)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).foregroundStyle(theme.muted).font(.caption.monospacedDigit())
        }
    }
    private func refreshUsage() async {
        do { mediaBytes = try await telegram.storageBytes(); artworkBytes = try await library.thumbnailBytes() }
        catch { status = "Could not read storage usage: \(error.localizedDescription)" }
    }
    private func perform(_ action: Action) {
        working = true
        Task {
            defer { working = false }
            do {
                switch action {
                case .media: rangeServer.stop(); try await telegram.clearMediaCache()
                case .artwork: try await library.clearThumbnails(); VideoArtwork.clearMemory()
                case .history:
                    guard await library.clearHistory() else { status = library.error; return }
                case .logout: rangeServer.stop(); telegram.logOut(); dismiss(); return
                }
                status = "Done."
                await refreshUsage()
            } catch { status = "Could not complete that action: \(error.localizedDescription)" }
        }
    }
}
