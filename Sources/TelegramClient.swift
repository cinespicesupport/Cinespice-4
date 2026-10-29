import Foundation
import Combine
import TDLibFramework

@MainActor
final class TelegramClient: ObservableObject {
    enum Stage: Equatable { case credentials, phone, code, password, email, emailCode, loading, activation, ready, error(String) }
    @Published private(set) var stage: Stage = .credentials
    @Published private(set) var status = ""
    @Published private(set) var isLoadingChats = false
    @Published private(set) var hasMoreChats = true
    @Published private(set) var loadingCollections: Set<Int64> = []
    @Published private(set) var collectionErrors: [Int64: String] = [:]
    @Published private(set) var discoveryError = ""
    @Published private(set) var moreCollections: Set<Int64> = []
    @Published private(set) var isClearingCache = false
    @Published private(set) var profileName = ""
    @Published private(set) var profileUsername = ""
    let accessConfiguration = AccessConfiguration.load()
    @Published private(set) var accessMessage = "Tap Activate to verify your membership."
    @Published private(set) var accessBusy = false
    @Published private(set) var announcement: AccessAnnouncement?
    @Published private(set) var notifications: [AccessAnnouncement] = []
    @Published private(set) var notificationsLoading = false
    @Published private(set) var notificationsMore = true
    @Published private(set) var notificationsError = ""
    private var noticeHistory = NoticeHistory()
    private var notificationsCursor: Int64 = 0
    @Published private(set) var accessMissing: Set<Int> = []
    @Published private(set) var accessNeedsPaid = false
    @Published private(set) var accessDenied = false
    private var accessDevice = ""
    private var accessRevision: Int64 = 0
    private var accessActivated = false
    private var accessRefresh: Task<Void, Never>?
    private var accessNonce = ""
    private var accessBotChat: Int64 = 0
    private var accessDeadline: ContinuousClock.Instant?
    private var accessExpiry: Int64 = 0
    private var accessTimer: Task<Void, Never>?
    let library: LibraryStore

    private var clientID = td_create_client_id()
    private let receiver = DispatchQueue(label: "app.tevee.tdlib.receive", qos: .userInitiated)
    private var running = false
    private let rangeReader = TelegramRangeReader()
    private var rangeWindows: [Int32: Range<Int64>] = [:]
    private var requestTimeouts: [Int: Task<Void, Never>] = [:]
    private var completions: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var requestID = 1
    private var authorizationSetup = TelegramAuthorizationSetup()
    private var apiID = 0
    private var apiHash = ""
    private var restored = false
    private var startingAccount = false
    private var loggingOut = false
    private var accountSession = UUID()
    private var pendingDiscoveryPage: TelegramDiscovery.Page?
    private var discovery: TelegramDiscovery?
    private var mediaQueue: [(id: Int64, refresh: Bool)] = []
    private var mediaWorker: Task<Void, Never>?
    @Published private(set) var isSearchingChats = false
    @Published private(set) var chatSearchError = ""
    private var searchGeneration = UUID()
    private var thumbnailRequests: [String: Task<Data, Error>] = [:]
    @Published private(set) var downloadRecords: [String: DownloadRecord] = [:]
    private var restoredDownloads: UUID?
    private var reconcilingDownloads: UUID?
    @Published private(set) var fullDownloads: Set<Int32> = []
    @Published private(set) var preparingDownloads: Set<String> = []
    @Published private(set) var cancellingDownloads: Set<Int32> = []
    @Published private(set) var isAuthenticating = false
    private var authenticationRequest = UUID()

    @Published private(set) var videoSearchResults: [TelegramVideo] = []
    @Published private(set) var isSearchingVideos = false
    @Published private(set) var hasMoreVideoResults = false
    @Published private(set) var videoSearchError = ""
    private var videoSearch: TelegramVideoSearch?
    private var videoSearchGeneration = UUID()
    private var videoSearchQuery = ""
    private var videoSearchScope: Set<Int64> = []
    private var videoSearchChatID: Int64?

    /// While the picker is visible, gradually discover all sources without loading messages.
    func discoverCollections() async {
        while !Task.isCancelled, stage == .ready, hasMoreChats {
            loadMoreChats()
            while isLoadingChats, !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            guard discoveryError.isEmpty, library.error.isEmpty else { return }
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
        }
    }

    func searchVideos(_ query: String, chatID: Int64? = nil) async {
        let generation = UUID(); videoSearchGeneration = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = chatID.map { Set([$0]) } ?? Set(library.selectedCollections.map(\.id))
        if text != videoSearchQuery || scope != videoSearchScope { videoSearchResults = [] }
        videoSearchScope = scope; videoSearchChatID = chatID
        videoSearchQuery = text; videoSearchError = ""; hasMoreVideoResults = false
        videoSearch = nil; isSearchingVideos = false
        guard !text.isEmpty, stage == .ready else { videoSearchResults = []; return }
        isSearchingVideos = true; hasMoreVideoResults = !scope.isEmpty
        let session = accountSession
        let search = TelegramVideoSearch(chatIDs: scope.sorted(), query: text) { [weak self] request in
            guard let self else { throw CancellationError() }
            return try await self.sessionRequest(request, session: session)
        }
        videoSearch = search
        do { try await Task.sleep(nanoseconds: 350_000_000) }
        catch { if videoSearchGeneration == generation { isSearchingVideos = false }; return }
        guard videoSearchGeneration == generation else { return }
        isSearchingVideos = false
        await nextVideoSearchPage()
    }

    func nextVideoSearchPage() async {
        guard let videoSearch, !isSearchingVideos, stage == .ready else { return }
        let token = videoSearchGeneration; let session = accountSession
        isSearchingVideos = true; videoSearchError = ""
        defer { if videoSearchGeneration == token { isSearchingVideos = false } }
        do {
            let page = try await videoSearch.next()
            try Task.checkCancellation()
            guard token == videoSearchGeneration, session == accountSession else { return }
            let videos = page.videos.filter { videoSearchScope.contains($0.chatID) && (videoSearchChatID != nil || library.snapshot.selected.contains($0.chatID)) }
            var seen = Set(videoSearchResults.map(\.id))
            videoSearchResults += videos.filter { seen.insert($0.id).inserted }
            hasMoreVideoResults = page.hasMore
            _ = await library.ingest(videos)
        } catch is CancellationError { }
        catch { if token == videoSearchGeneration { videoSearchError = "Search could not finish. Results already found are kept. Check your connection and retry." } }
    }

    init(library: LibraryStore) { self.library = library }

    func restoreSession() {
        guard !restored else { return }; restored = true
        connectUsingBuildCredentials()
    }

    func connectUsingBuildCredentials() {
        guard let url = Bundle.main.url(forResource: "TelegramBuildCredentials", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let credentials = try? PropertyListDecoder().decode(TelegramCredentials.self, from: data) else {
            stage = .error("This build is missing its sign-in configuration. Please install a configured build.")
            return
        }
        connect(apiID: credentials.apiID, apiHash: credentials.apiHash)
    }

    func connect(apiID: String, apiHash: String) {
        let hash = apiHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int32(apiID), value > 0, hash.count == 32, hash.allSatisfy({ $0.isHexDigit }) else {
            stage = .error("This build has invalid sign-in configuration. Please install a configured build."); return
        }
        do { try SecureStore.save(JSONEncoder().encode(TelegramCredentials(apiID: String(value), apiHash: hash)), key: "telegram_api_credentials") }
        catch { stage = .error(error.localizedDescription); return }
        self.apiID = Int(value); self.apiHash = hash; stage = .loading; status = ""
        startReceiver()
        let revision = authorizationSetup.revision
        let client = clientID
        send(["@type": "getAuthorizationState"]) { [weak self] result in
            guard let self, self.clientID == client, self.authorizationSetup.revision == revision, !self.loggingOut else { return }
            switch result {
            case .success(let state): self.handle(state)
            case .failure(let error): self.stage = .error("Could not check sign-in: \(error.localizedDescription)")
            }
        }
    }

    func submitPhone(countryCode: String, number: String) {
        let callingCode = countryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = number.filter { $0 >= "0" && $0 <= "9" }
        guard callingCode.hasPrefix("+"), (2...4).contains(callingCode.count),
              callingCode.dropFirst().allSatisfy({ $0 >= "0" && $0 <= "9" }),
              callingCode.dropFirst().first != "0", !digits.isEmpty,
              callingCode.count - 1 + digits.count <= 15 else {
            status = "Enter a country code such as +91 and a valid phone number."; return
        }
        submitAuthentication(["@type": "setAuthenticationPhoneNumber", "phone_number": callingCode + digits])
    }
    func resendCode() {
        guard stage == .code else { return }
        submitAuthentication(["@type": "resendAuthenticationCode"])
    }

    /// Restart the server-side authorization flow, rather than only changing the visible screen.
    func restartLogin() {
        guard stage != .ready, stage != .activation, stage != .loading, !isAuthenticating else { return }
        let previous = stage
        authenticationRequest = UUID(); loggingOut = true; isAuthenticating = true; stage = .loading; status = ""
        let session = accountSession
        send(["@type": "logOut"]) { [weak self] result in
            guard let self, self.accountSession == session else { return }
            if case let .failure(error) = result {
                self.loggingOut = false; self.isAuthenticating = false; self.stage = previous; self.status = error.localizedDescription
            }
        }
    }
    func submitCode(_ code: String) { submitAuthentication(["@type": "checkAuthenticationCode", "code": code]) }
    func submitPassword(_ password: String) { submitAuthentication(["@type": "checkAuthenticationPassword", "password": password]) }
    func submitEmail(_ email: String) { submitAuthentication(["@type": "setAuthenticationEmailAddress", "email_address": email]) }
    func submitEmailCode(_ code: String) { submitAuthentication(["@type": "checkAuthenticationEmailCode", "code": ["@type": "emailAddressAuthenticationCode", "code": code]]) }
    private func submitAuthentication(_ request: [String: Any]) {
        guard !isAuthenticating else { return }
        isAuthenticating = true; status = "Checking sign-in…"
        let session = accountSession
        let token = UUID(); authenticationRequest = token
        send(request) { [weak self] result in
            guard let self, self.accountSession == session, self.authenticationRequest == token else { return }
            self.isAuthenticating = false
            switch result {
            case .success: self.status = ""
            case .failure(let error): self.status = error.localizedDescription
            }
        }
    }
    func resetAuth() { connectUsingBuildCredentials() }

    func refreshChats() { loadMoreChats() }
    func loadMoreChats() {
        guard stage == .ready, !isLoadingChats, let discovery else { return }
        isLoadingChats = true; status = ""; discoveryError = ""
        let session = accountSession
        Task {
            defer { if accountSession == session { isLoadingChats = false } }
            do {
                let page: TelegramDiscovery.Page
                if let pendingDiscoveryPage { page = pendingDiscoveryPage }
                else { page = try await discovery.next(cached: library.snapshot.collections, accountID: library.accountID) }
                guard accountSession == session, stage == .ready else { return }
                pendingDiscoveryPage = page
                let saved = await library.register(page.chats)
                guard accountSession == session else { return }
                guard saved else { status = library.error; return }
                pendingDiscoveryPage = nil; hasMoreChats = page.hasMore
            } catch { if accountSession == session { discoveryError = "Could not find channels: \(error.localizedDescription)"; status = discoveryError } }
        }
    }

    func searchCollections(_ query: String, channelsOnly: Bool = true) async {
        let token = UUID(); searchGeneration = token
        chatSearchError = ""
        guard stage == .ready, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let discovery else { isSearchingChats = false; return }
        isSearchingChats = true
        let session = accountSession
        defer { if searchGeneration == token { isSearchingChats = false } }
        do {
            try await Task.sleep(nanoseconds: 400_000_000)
            let chats = try await discovery.search(query, accountID: library.accountID, channelsOnly: channelsOnly)
            try Task.checkCancellation()
            guard accountSession == session, searchGeneration == token else { return }
            _ = await library.register(chats)
        } catch is CancellationError { }
        catch { if accountSession == session, searchGeneration == token { chatSearchError = "Channel search failed: \(error.localizedDescription)" } }
    }

    /// Opening a cached collection never advances its remote cursor.
    func ensureChat(_ id: Int64) {
        if let index = library.snapshot.indexes[id] {
            if index.hasMore { moreCollections.insert(id) }
            return
        }
        loadChat(id)
    }

    func loadChat(_ id: Int64, refresh: Bool = false) {
        guard stage == .ready, library.snapshot.selected.contains(id), !loadingCollections.contains(id) else { return }
        if !refresh, library.snapshot.indexes[id]?.hasMore == false { return }
        collectionErrors[id] = nil
        loadingCollections.insert(id)
        mediaQueue.append((id, refresh))
        guard mediaWorker == nil else { return }
        let session = accountSession
        mediaWorker = Task {
            defer { if accountSession == session { mediaWorker = nil } }
            while !mediaQueue.isEmpty, accountSession == session, stage == .ready {
                let job = mediaQueue.removeFirst()
                await loadPage(job.id, refresh: job.refresh, session: session)
                if accountSession == session { loadingCollections.remove(job.id) }
            }
        }
    }

    private func loadPage(_ id: Int64, refresh: Bool, session: UUID) async {
        let existing = library.snapshot.indexes[id]
        let requests = refresh ? CollectionIndex().cursors : (existing ?? CollectionIndex()).cursors
        for filter in CollectionIndex.filters {
            guard let cursor = requests[filter], accountSession == session, stage == .ready, library.snapshot.selected.contains(id) else { continue }
            do {
                let data = try await requestJSON(["@type": "searchChatMessages", "chat_id": id, "query": "", "from_message_id": cursor,
                    "offset": 0, "limit": CollectionIndex.pageLimit, "filter": ["@type": filter]])
                guard accountSession == session, stage == .ready, library.snapshot.selected.contains(id) else { return }
                let videos = (data["messages"] as? [[String: Any]] ?? []).compactMap { TelegramVideo.from(message: $0, chatID: id) }
                var index = library.snapshot.indexes[id] ?? CollectionIndex()
                // Refresh the newest page without losing the saved position for older pages.
                if !refresh || existing == nil { index.advance(filter: filter, from: cursor, next: data["next_from_message_id"] as? Int64 ?? 0) }
                let saved = await library.savePage(videos, chatID: id, index: index)
                guard accountSession == session else { return }
                guard saved else { collectionErrors[id] = library.error; status = library.error; return }
            } catch { if accountSession == session { collectionErrors[id] = "Could not load videos: \(error.localizedDescription)"; status = collectionErrors[id] ?? "" }; return }
        }
        guard accountSession == session else { return }
        if library.snapshot.indexes[id]?.hasMore == true { moreCollections.insert(id) } else { moreCollections.remove(id) }
    }

    func refreshLibrary() {
        if let first = library.selectedCollections.first { loadChat(first.id, refresh: true) }
    }

    private func sessionRequest(_ request: [String: Any], session: UUID) async throws -> [String: Any] {
        enforceAccess()
        guard accountSession == session, stage == .ready else { throw CancellationError() }
        let response = try await requestJSON(request)
        guard accountSession == session, stage == .ready else { throw CancellationError() }
        return response
    }

    /// Refresh the actual message and TDLib file state before trusting a saved path.
    func prepare(_ saved: TelegramVideo, persist: Bool = true) async throws -> TelegramVideo {
        enforceAccess()
        guard stage == .ready, !isClearingCache else { throw URLError(.userAuthenticationRequired) }
        let session = accountSession
        let message = try await requestJSON(["@type": "getMessage", "chat_id": saved.chatID, "message_id": saved.messageID])
        guard accountSession == session, stage == .ready else { throw CancellationError() }
        try Task.checkCancellation()
        guard let current = TelegramVideo.from(message: message, chatID: saved.chatID) else {
            throw NSError(domain: "Tevee.Media", code: 1, userInfo: [NSLocalizedDescriptionKey: "This message no longer contains an accessible video."])
        }
        // getMessage already includes TDLib's current File state. A second
        // getFile request adds a serial round trip without refreshing the message.
        guard accountSession == session, stage == .ready, !isClearingCache else { throw CancellationError() }
        if persist {
            guard await library.ingest([current]) else {
                throw NSError(domain: "Tevee.Library", code: 1, userInfo: [NSLocalizedDescriptionKey: library.error])
            }
        }
        try Task.checkCancellation()
        guard accountSession == session, stage == .ready, !isClearingCache else { throw CancellationError() }
        return current
    }

    /// TDLib has one download window per file. Streaming takes over that window,
    /// leaving the explicit full download paused and its cached bytes intact.
    func prepareForPlayback(_ video: TelegramVideo) async throws -> TelegramVideo {
        let session = accountSession
        while preparingDownloads.contains(video.id) || cancellingDownloads.contains(video.fileID) {
            try await Task.sleep(nanoseconds: 50_000_000)
            guard accountSession == session, stage == .ready else { throw CancellationError() }
        }
        let current = try await prepare(video, persist: false)
        let intent = downloadRecords[video.id]?.state
        if !current.isDownloaded, fullDownloads.contains(current.fileID) || intent == .downloading || intent == .preparing {
            try await pauseTransfer(current)
        }
        return current
    }

    func download(_ video: TelegramVideo) {
        guard stage == .ready, !isClearingCache, !fullDownloads.contains(video.fileID), !preparingDownloads.contains(video.id), !cancellingDownloads.contains(video.fileID) else { return }
        preparingDownloads.insert(video.id)
        setDownload(video.id, state: .preparing)
        status = "Preparing download…"
        let session = accountSession
        Task {
            defer { if accountSession == session { preparingDownloads.remove(video.id) } }
            var requestedID: Int32?
            do {
                let current = try await prepare(video)
                requestedID = current.fileID
                rangeWindows.removeValue(forKey: current.fileID)
                fullDownloads.insert(current.fileID)
                setDownload(video.id, state: .downloading)
                status = "Downloading. You can pause and resume without clearing cached data."
                let file = try await requestJSON(["@type": "downloadFile", "file_id": current.fileID, "priority": 32, "offset": 0, "limit": 0, "synchronous": false])
                guard accountSession == session, stage == .ready else { return }
                preparingDownloads.remove(video.id)
                updateFile(file)
            } catch {
                if accountSession == session {
                    if let requestedID { fullDownloads.remove(requestedID) }
                    setDownload(video.id, state: .retry, error: "Download failed. Check your connection and available storage, then retry.")
                    status = "Could not download: \(error.localizedDescription)"
                }
            }
        }
    }

    func pauseDownload(_ video: TelegramVideo) async {
        let session = accountSession
        do { let current = try await prepare(video); try await pauseTransfer(current) }
        catch { if accountSession == session { status = "Could not pause download: \(error.localizedDescription)" } }
    }

    private func pauseTransfer(_ video: TelegramVideo) async throws {
        guard stage == .ready, !isClearingCache, !preparingDownloads.contains(video.id), !cancellingDownloads.contains(video.fileID) else { throw CancellationError() }
        cancellingDownloads.insert(video.fileID)
        let session = accountSession
        defer { if accountSession == session { cancellingDownloads.remove(video.fileID) } }
        // Cancel the transfer only. Never deleteFile/optimizeStorage on pause.
        _ = try await requestJSON(["@type": "cancelDownloadFile", "file_id": video.fileID, "only_if_pending": false])
        guard accountSession == session, stage == .ready else { throw CancellationError() }
        rangeWindows.removeValue(forKey: video.fileID)
        fullDownloads.remove(video.fileID)
        setDownload(video.id, state: .paused)
        status = "Download paused. Cached data is kept; Resume continues it later."
    }

    private var downloadsKey: String? { library.accountID.map { "downloads.\($0)" } }
    private func setDownload(_ id: String, state: DownloadRecord.State, error: String = "") {
        downloadRecords[id] = DownloadRecord(state: state, error: error)
        persistDownloads()
    }
    private func persistDownloads() {
        guard let key = downloadsKey, let data = try? JSONEncoder().encode(downloadRecords) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    func reconcileDownloads() async {
        guard stage == .ready, !isClearingCache, reconcilingDownloads == nil else { return }
        let session = accountSession
        reconcilingDownloads = session
        defer { if reconcilingDownloads == session { reconcilingDownloads = nil } }
        if restoredDownloads != session {
            restoredDownloads = session
            if let key = downloadsKey, let data = UserDefaults.standard.data(forKey: key) {
                downloadRecords = (try? JSONDecoder().decode([String: DownloadRecord].self, from: data)) ?? [:]
            }
        }
        for video in library.snapshot.videos where downloadRecords[video.id] != nil {
            guard accountSession == session, stage == .ready, !isClearingCache else { return }
            if preparingDownloads.contains(video.id) || cancellingDownloads.contains(video.fileID) { continue }
            let previous = downloadRecords[video.id]!
            do {
                let current: TelegramVideo
                if fullDownloads.contains(video.fileID) { current = video }
                else { current = try await prepare(video) }
                let file = try await requestJSON(["@type": "getFile", "file_id": current.fileID])
                guard accountSession == session, stage == .ready, !isClearingCache else { return }
                // A newer download/cancel action wins over this reconciliation.
                guard downloadRecords[video.id] == previous, !preparingDownloads.contains(video.id), !cancellingDownloads.contains(video.fileID) else { continue }
                let local = file["local"] as? [String: Any] ?? [:]
                let state = DownloadRecord.reconciled(previous: previous.state,
                    complete: local["is_downloading_completed"] as? Bool == true,
                    exists: FileManager.default.fileExists(atPath: local["path"] as? String ?? ""),
                    active: local["is_downloading_active"] as? Bool == true)
                if state == .downloading { fullDownloads.insert(current.fileID) }
                else { fullDownloads.remove(current.fileID) }
                setDownload(video.id, state: state, error: state == .retry ? "Download interrupted or unavailable locally. Tap Retry download." : "")
                updateFile(file)
            } catch {
                guard accountSession == session else { return }
                if downloadRecords[video.id] == previous, previous.state != .paused, previous.state != .cancelled {
                    setDownload(video.id, state: .retry, error: "Could not check this download. Check your connection and retry.")
                }
            }
        }
    }

    func thumbnail(_ video: TelegramVideo) async throws -> Data? {
        guard stage == .ready, !isClearingCache, let cache = library.thumbnails else { return video.minithumbnail }
        let session = accountSession
        let cached = try await cache.read(video.thumbnailKey)
        guard accountSession == session, stage == .ready, !isClearingCache else { throw CancellationError() }
        if let cached { return cached }
        guard video.thumbnailFileID != nil else { return video.minithumbnail }
        let key = video.thumbnailKey
        let requestKey = "\(session.uuidString)_\(key)"
        if let existing = thumbnailRequests[requestKey] { return try await existing.value }
        let task = Task<Data, Error> {
            let fileID: Int32
            if let remoteID = video.thumbnailRemoteID, !remoteID.isEmpty {
                let file = try await requestJSON(["@type": "getRemoteFile", "remote_file_id": remoteID, "file_type": ["@type": "fileTypeThumbnail"]])
                guard let id = file["id"] as? Int32, (file["size"] as? Int64 ?? 0) <= 2 * 1024 * 1024 else { throw URLError(.cannotDecodeContentData) }
                fileID = id
            } else {
                // Legacy rows only contain session-local IDs. Refresh the message
                // before downloading so an ID reused after logout cannot fetch a video.
                let message = try await requestJSON(["@type": "getMessage", "chat_id": video.chatID, "message_id": video.messageID])
                guard let current = TelegramVideo.from(message: message, chatID: video.chatID), let id = current.thumbnailFileID else { throw URLError(.fileDoesNotExist) }
                guard accountSession == session else { throw CancellationError() }
                _ = await library.ingest([current])
                fileID = id
            }
            guard accountSession == session, stage == .ready, !isClearingCache else { throw CancellationError() }
            let result = try await requestJSON(["@type": "downloadFile", "file_id": fileID, "priority": 1, "offset": 0, "limit": 0, "synchronous": true])
            guard accountSession == session, stage == .ready, !isClearingCache else { throw CancellationError() }
            guard (result["local"] as? [String: Any])?["is_downloading_completed"] as? Bool == true,
                  let size = result["size"] as? Int64, size > 0, size <= 2 * 1024 * 1024 else { throw URLError(.cannotDecodeContentData) }
            let response = try await requestJSON(["@type": "readFilePart", "file_id": fileID, "offset": 0, "count": size])
            guard let encoded = response["data"] as? String else { throw URLError(.cannotDecodeContentData) }
            let data = try await Task.detached(priority: .utility) {
                guard let bytes = Data(base64Encoded: encoded), bytes.count == size else { throw URLError(.cannotDecodeContentData) }
                return bytes
            }.value
            try Task.checkCancellation()
            guard accountSession == session, stage == .ready, !isClearingCache else { throw CancellationError() }
            try await cache.write(data, key: key)
            return data
        }
        thumbnailRequests[requestKey] = task
        defer { thumbnailRequests.removeValue(forKey: requestKey) }
        return try await task.value
    }

    func storageBytes() async throws -> Int64 {
        let stats = try await requestJSON(["@type": "getStorageStatisticsFast"])
        return stats["files_size"] as? Int64 ?? 0
    }

    /// Only TDLib local-cache APIs are called. No cloud-message deletion request.
    func clearMediaCache() async throws {
        guard !isClearingCache else { return }
        let session = accountSession
        isClearingCache = true
        defer { if accountSession == session { isClearingCache = false } }
        let pending = Array(thumbnailRequests.values)
        pending.forEach { $0.cancel() }
        for task in pending { _ = try? await task.value }
        for file in fullDownloads { _ = try await requestJSON(["@type": "cancelDownloadFile", "file_id": file, "only_if_pending": false]) }
        guard accountSession == session, stage == .ready else { throw CancellationError() }
        fullDownloads.removeAll(); rangeWindows.removeAll()
        _ = try await requestJSON(["@type": "optimizeStorage", "size": 0, "ttl": 0, "count": 0, "immunity_delay": 0,
            "file_types": [["@type": "fileTypeVideo"], ["@type": "fileTypeDocument"], ["@type": "fileTypeThumbnail"]],
            "chat_ids": [], "exclude_chat_ids": [], "return_deleted_file_statistics": false, "chat_limit": 0])
        guard accountSession == session, stage == .ready else { throw CancellationError() }
        downloadRecords = [:]; persistDownloads()
        guard await library.invalidateMediaCache() else {
            throw NSError(domain: "Tevee.Library", code: 1, userInfo: [NSLocalizedDescriptionKey: library.error])
        }
        status = "Downloaded media cleared. Your cloud videos and watch history are kept."
    }

    func logOut() {
        guard stage == .ready || stage == .activation else { return }
        let previous = stage
        loggingOut = true; stage = .loading
        let session = accountSession
        send(["@type": "logOut"]) { [weak self] result in
            guard let self, self.accountSession == session else { return }
            if case let .failure(error) = result { self.loggingOut = false; self.stage = previous; self.status = error.localizedDescription; self.enforceAccess() }
        }
    }
    func readRange(video: TelegramVideo, offset: Int64, length: Int) async throws -> Data {
        enforceAccess()
        guard length > 0, offset >= 0, offset < video.size else { return Data() }
        guard stage == .ready, !isClearingCache else { throw CancellationError() }
        let session = accountSession
        let count = Int(min(Int64(length), video.size - offset))
        return try await rangeReader.read(fileID: video.fileID) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.fetchRange(fileID: video.fileID, offset: offset, count: count, size: video.size, session: session)
        }
    }

    private func fetchRange(fileID: Int32, offset: Int64, count: Int, size: Int64, session: UUID) async throws -> Data {
        let deadline = Date().addingTimeInterval(45)
        var requested = false
        while Date() < deadline {
            enforceAccess()
            try Task.checkCancellation()
            guard accountSession == session, stage == .ready, !isClearingCache else { throw CancellationError() }
            let prefix = try await requestJSON(["@type": "getFileDownloadedPrefixSize", "file_id": fileID, "offset": offset])
            try Task.checkCancellation()
            guard accountSession == session, stage == .ready, !isClearingCache else { throw CancellationError() }
            let ready = StreamReadPolicy.readyCount(available: prefix["size"] as? Int64 ?? 0, requested: count)
            if ready > 0 {
                let result = try await requestJSON(["@type": "readFilePart", "file_id": fileID, "offset": offset, "count": ready])
                guard accountSession == session, stage == .ready else { throw CancellationError() }
                guard let encoded = result["data"] as? String else { throw URLError(.cannotDecodeContentData) }
                // TDLib performs cache I/O on its own workers. Decode the JSON
                // bytes off the main actor too; never infer validity from disk size.
                return try await Task.detached(priority: .userInitiated) {
                    guard let data = Data(base64Encoded: encoded), data.count == ready else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    return data
                }.value
            }
            if !requested {
                var reuse = false
                if let window = rangeWindows[fileID], window.lowerBound <= offset, window.upperBound >= offset + Int64(count) {
                    let file = try await requestJSON(["@type": "getFile", "file_id": fileID])
                    try Task.checkCancellation()
                    guard accountSession == session, stage == .ready, !isClearingCache else { throw CancellationError() }
                    reuse = (file["local"] as? [String: Any])?["is_downloading_active"] as? Bool == true
                }
                if !reuse {
                    let ahead = min(size - offset, max(Int64(count), 8 * 1024 * 1024))
                    _ = try await requestJSON(["@type": "downloadFile", "file_id": fileID, "priority": 32,
                                               "offset": offset, "limit": ahead, "synchronous": false])
                    guard accountSession == session else { throw CancellationError() }
                    rangeWindows[fileID] = offset..<(offset + ahead)
                }
                requested = true
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw URLError(.timedOut)
    }

    private func requestJSON(_ request: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in send(request) { continuation.resume(with: $0) } }
    }

    private func startReceiver() {
        guard !running else { return }; running = true
        receiver.async { [weak self] in
            while self != nil {
                guard let pointer = td_receive(1.0) else { continue }
                let text = String(cString: pointer)
                // readFilePart responses contain large base64 strings. Parse their
                // JSON on the receive worker so larger reads do not block controls.
                let parsed = Result { try Self.parse(text) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    switch parsed {
                    case .success(let value): self.handle(value)
                    case .failure(let error): self.status = "Could not read the account response: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func updateFile(_ file: [String: Any]) {
        library.updateFile(file)
        guard let state = LocalFileStatus(file), fullDownloads.contains(state.id) else { return }
        let local = file["local"] as? [String: Any] ?? [:]
        let active = local["is_downloading_active"] as? Bool == true
        for video in library.snapshot.videos where video.fileID == state.id && downloadRecords[video.id] != nil {
            if state.complete {
                fullDownloads.remove(state.id); setDownload(video.id, state: .downloaded)
                status = "Download complete. Open the video to play the local file."
            } else if !active, !preparingDownloads.contains(video.id), !cancellingDownloads.contains(state.id) {
                fullDownloads.remove(state.id)
                setDownload(video.id, state: .retry, error: "Download interrupted. Check your connection and storage, then retry.")
            }
        }
    }

    private func handle(_ value: [String: Any]) {
        if let client = value["@client_id"] as? Int32, client != clientID { return }
        if let id = value["@extra"] as? Int, let completion = completions.removeValue(forKey: id) {
            requestTimeouts.removeValue(forKey: id)?.cancel()
            if value["@type"] as? String == "error" {
                completion(.failure(NSError(domain: "TDLib", code: value["code"] as? Int ?? -1, userInfo: [NSLocalizedDescriptionKey: value["message"] as? String ?? "Account error"])))
            } else { completion(.success(value)) }
            return
        }
        if value["@type"] as? String == "updateDeleteMessages" { deleteNotifications(value); return }
        if value["@type"] as? String == "updateNewMessage", let message = value["message"] as? [String: Any] { receiveAccess(message); return }
        if value["@type"] as? String == "updateFile", let file = value["file"] as? [String: Any] { updateFile(file); return }
        if value["@type"] as? String == "error" { status = value["message"] as? String ?? "Account request failed"; return }
        let responseType = value["@type"] as? String ?? ""
        let type = responseType == "updateAuthorizationState" ? (value["authorization_state"] as? [String: Any])?["@type"] as? String : responseType
        if loggingOut, type != "authorizationStateClosed" { return }
        if let type, type.hasPrefix("authorizationState") { authorizationSetup.observe(type) }
        switch type {
        case "authorizationStateWaitTdlibParameters": configure()
        case "authorizationStateWaitPhoneNumber": stage = .phone
        case "authorizationStateWaitCode": stage = .code
        case "authorizationStateWaitPassword": stage = .password
        case "authorizationStateWaitEmailAddress": stage = .email
        case "authorizationStateWaitEmailCode": stage = .emailCode
        case "authorizationStateReady": startAccount()
        case "authorizationStateWaitOtherDeviceConfirmation": stage = .error("Confirm sign-in on a device where you are already signed in, or restart phone sign-in.")
        case "authorizationStateClosed": finishClosedClient()
        default: break
        }
    }

    private func startAccount() {
        guard !startingAccount, !loggingOut, stage != .ready, stage != .activation else { return }; startingAccount = true
        let session = accountSession
        Task {
            defer { if accountSession == session { startingAccount = false } }
            do {
                let me = try await requestJSON(["@type": "getMe"])
                guard let id = me["id"] as? Int64 else { throw URLError(.cannotParseResponse) }
                guard accountSession == session else { return }
                try await library.activate(accountID: id)
                guard accountSession == session else { return }
                let data = try await requestJSON(["@type": "createPrivateChat", "user_id": id, "force": false])
                guard accountSession == session else { return }
                if let chat = TelegramChat.from(data, accountID: id) {
                    guard await library.register(chat, savedMessages: false) else {
                        throw NSError(domain: "Tevee.Library", code: 1, userInfo: [NSLocalizedDescriptionKey: library.error])
                    }
                }
                guard accountSession == session else { return }
                profileName = [me["first_name"] as? String, me["last_name"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                profileUsername = ((me["usernames"] as? [String: Any])?["active_usernames"] as? [String])?.first ?? ""
                stage = .activation
                restoreAccess()
                discovery = TelegramDiscovery { [weak self] request in
                    guard let self else { throw CancellationError() }
                    return try await self.sessionRequest(request, session: session)
                }
                // Cached library is immediately available. Discovery and indexing are
                // started explicitly by the channel picker/opened collection only.
            } catch { if accountSession == session { stage = .error("Could not restore your library: \(error.localizedDescription)") } }
        }
    }

    private var accessCacheKey: String? {
        guard let account = library.accountID, let config = accessConfiguration else { return nil }
        return "access.\(account).\(config.fingerprint)"
    }

    private func saveAccess(token: String = "", nonce: String = "") {
        guard let key = accessCacheKey, !accessDevice.isEmpty, accessActivated else { return }
        let snapshot = AccessSnapshot(token: token, nonce: nonce, device: accessDevice, revision: accessRevision)
        do { try SecureStore.save(JSONEncoder().encode(snapshot), key: key) }
        catch { accessMessage = "Could not save activation. You may need to activate again after restarting." }
    }

    private func restoreAccess() {
        guard let config = accessConfiguration, let account = library.accountID, let key = accessCacheKey else { return }
        do {
            accessDevice = try SecureStore.installationID()
            guard let data = try SecureStore.read(key), let snapshot = try? JSONDecoder().decode(AccessSnapshot.self, from: data), snapshot.device == accessDevice else { return }
            accessActivated = true; accessRevision = snapshot.revision
            if let receipt = try? config.receipt(snapshot.token, account: account, nonce: snapshot.nonce, device: accessDevice),
               receipt.status == "authorized", (receipt.revision ?? -1) >= accessRevision {
                grantAccess(receipt)
            } else { checkAccess() }
        } catch { accessMessage = "Unlock your device to restore activation from secure storage." }
    }

    private func grantAccess(_ receipt: AccessReceipt) {
        accessExpiry = receipt.exp
        accessDeadline = ContinuousClock().now.advanced(by: .seconds(max(0, receipt.exp - Int64(Date().timeIntervalSince1970))))
        accessMessage = "Verified. Welcome to Cinespice."; stage = .ready
        accessRefresh?.cancel()
        let session = accountSession
        accessRefresh = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(1, receipt.exp - Int64(Date().timeIntervalSince1970) - 30)) * 1_000_000_000) } catch { return }
            guard let self, self.accountSession == session else { return }
            self.checkAccess()
        }
        loadAnnouncements()
        if restoredDownloads != session { Task { await reconcileDownloads() } }
    }

    private var hasValidAccess: Bool {
        stage == .ready && accessExpiry > Int64(Date().timeIntervalSince1970) &&
            (accessDeadline.map { ContinuousClock().now < $0 } ?? false)
    }
    private func accessConnectionFailed() {
        if !hasValidAccess {
            stage = .activation
            accessMessage = accessExpiry > 0
                ? "Your access pass expired. Connect to Telegram and tap Activate to renew it."
                : "Could not reach the access bot. Check your connection and tap Activate."
            return
        }
        accessMessage = "Connection interrupted. Your current access remains valid while renewal retries."
        let session = accountSession
        accessRefresh?.cancel()
        accessRefresh = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, self.accountSession == session else { return }
            self.enforceAccess()
            if self.stage == .ready { self.checkAccess() }
        }
    }

    func enforceAccess() {
        if stage == .ready && ((accessDeadline.map { ContinuousClock().now >= $0 } ?? true) || Int64(Date().timeIntervalSince1970) >= accessExpiry) {
            stage = .activation
            accessMessage = "Your access pass expired. Connecting to Telegram to renew it…"
            if !accessBusy { checkAccess() }
        }
    }

    func checkAccess(start: Bool = false) {
        guard !loggingOut, stage == .activation || stage == .ready, !accessBusy, let config = accessConfiguration else { return }
        do { accessDevice = try SecureStore.installationID() }
        catch { accessMessage = "Secure storage is unavailable. Unlock your device and retry."; return }
        let session = accountSession
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        accessNonce = nonce; accessBusy = true; accessMessage = "Verifying membership…"
        accessTimer?.cancel()
        accessTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 75_000_000_000) } catch { return }
            guard let self, self.accountSession == session, self.accessNonce == nonce, self.accessBusy else { return }
            self.accessNonce = ""; self.accessBusy = false
            self.accessConnectionFailed()
        }
        Task {
            do {
                let chat = try await requestJSON(["@type": "searchPublicChat", "username": config.botUsername])
                guard accountSession == session, accessNonce == nonce else { return }
                guard let type = chat["type"] as? [String: Any], type["@type"] as? String == "chatTypePrivate",
                      type["user_id"] as? Int64 == Int64(config.botUserID), let chatID = chat["id"] as? Int64 else { throw URLError(.userAuthenticationRequired) }
                accessBotChat = chatID
                if start || !accessActivated {
                    _ = try await requestJSON(["@type": "sendBotStartMessage", "bot_user_id": Int64(config.botUserID)!, "chat_id": chatID, "parameter": "cs2_" + accessDevice + "_" + nonce])
                } else {
                    _ = try await requestJSON(["@type": "sendMessage", "chat_id": chatID, "input_message_content": ["@type": "inputMessageText", "text": ["@type": "formattedText", "text": "/check " + nonce + " " + accessDevice]]])
                }
            } catch {
                guard accountSession == session, accessNonce == nonce else { return }
                accessTimer?.cancel(); accessNonce = ""; accessBusy = false
                accessConnectionFailed()
            }
        }
    }

    private func receiveAccess(_ message: [String: Any], allowBanner: Bool = true) {
        guard !loggingOut, stage == .ready || stage == .activation, let config = accessConfiguration,
              let account = library.accountID, message["is_outgoing"] as? Bool != true,
              let sender = message["sender_id"] as? [String: Any], sender["@type"] as? String == "messageSenderUser",
              sender["user_id"] as? Int64 == Int64(config.botUserID), message["chat_id"] as? Int64 == Int64(config.botUserID),
              let content = message["content"] as? [String: Any] else { return }
        if let revision = AccessSnapshot.eventRevision(message), revision > accessRevision {
            accessRevision = revision; accessNonce = ""; accessBusy = false; accessExpiry = 0; accessDeadline = nil
            accessTimer?.cancel(); accessRefresh?.cancel(); announcement = nil
            saveAccess(); stage = .activation
            accessMessage = "Membership changed. Verifying…"
            if accessActivated {
                let session = accountSession
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_100_000_000)
                    guard let self, self.accountSession == session else { return }
                    self.checkAccess()
                }
            }
            return
        }
        if let text = (content["text"] as? [String: Any])?["text"] as? String, text.hasPrefix("CSP1."),
           accessBusy, !accessNonce.isEmpty, message["chat_id"] as? Int64 == accessBotChat {
            guard let receipt = try? config.receipt(text, account: account, nonce: accessNonce, device: accessDevice),
                  let revision = receipt.revision, revision >= accessRevision else { return }
            let nonce = accessNonce
            accessNonce = ""; accessBusy = false; accessTimer?.cancel(); accessRefresh?.cancel()
            accessActivated = true
            accessRevision = revision; accessNeedsPaid = receipt.paid ?? false; accessMissing = Set(receipt.missing ?? [])
            accessDenied = receipt.status == "revoked"
            if receipt.status == "authorized" {
                accessActivated = true; saveAccess(token: text, nonce: nonce); grantAccess(receipt)
            } else {
                accessExpiry = 0; accessDeadline = nil; stage = .activation; announcement = nil; saveAccess()
                switch receipt.status {
                case "unpaid": accessMessage = "Request paid-group approval, then Activate. Join any required channels shown below."
                case "join_required": accessMessage = "Join the required channels below. We'll verify again after joining."
                case "revoked": accessMessage = "Access was revoked by an administrator. Contact us for help."
                case "not_started": accessMessage = "Tap Activate to start the bot and verify membership."
                default: accessMessage = "Verification is temporarily unavailable. Retry Activate."
                }
            }
            // Acknowledgement allows the bot to replace the raw receipt only after validation.
            send(["@type": "sendMessage", "chat_id": accessBotChat, "input_message_content": ["@type": "inputMessageText", "text": ["@type": "formattedText", "text": "/verified " + nonce]]])
        } else if stage == .ready {
            noticeHistory.ingest(message)
            notifications = noticeHistory.ordered.compactMap(AccessAnnouncement.init)
            if let current = announcement, !notifications.contains(where: { $0.id == current.id }) { announcement = nil }
            if allowBanner, let notice = AccessAnnouncement(message: message), noticeHistory.messages[notice.id] != nil {
                considerBanner(notice, account: account)
            }
        }
    }

    func dismissAnnouncement() {
        if let announcement, let account = library.accountID {
            UserDefaults.standard.set(true, forKey: announcement.dismissalKey(account))
        }
        announcement = nil
    }

    private func considerBanner(_ notice: AccessAnnouncement, account: Int64) {
        let key = "access.notice.latest.\(account).\(accessConfiguration?.botUserID ?? "")"
        let previous = Int64(UserDefaults.standard.string(forKey: key) ?? "") ?? 0
        guard notice.id >= previous else { return }
        UserDefaults.standard.set(String(notice.id), forKey: key)
        if !UserDefaults.standard.bool(forKey: notice.dismissalKey(account)) { announcement = notice }
    }

    func loadAnnouncements(refresh: Bool = true) {
        guard let config = accessConfiguration, stage == .ready, !notificationsLoading, refresh || notificationsMore else { return }
        if refresh { notificationsCursor = 0; notificationsMore = true }
        let from = notificationsCursor
        let session = accountSession
        notificationsLoading = true; notificationsError = ""
        Task {
            defer { if accountSession == session { notificationsLoading = false } }
            do {
                let response = try await requestJSON(["@type": "getChatHistory", "chat_id": Int64(config.botUserID)!, "from_message_id": from, "offset": 0, "limit": 100, "only_local": false])
                guard accountSession == session, stage == .ready else { return }
                let messages = response["messages"] as? [[String: Any]] ?? []
                for message in messages { receiveAccess(message, allowBanner: false) }
                if from == 0, let latest = notifications.first, let account = library.accountID { considerBanner(latest, account: account) }
                let oldest = messages.compactMap { $0["id"] as? Int64 }.min() ?? 0
                notificationsMore = oldest > noticeHistory.clearedThrough && oldest > 0 && oldest != from
                notificationsCursor = oldest
            } catch { if accountSession == session { notificationsError = "Could not load notifications. Please retry." } }
        }
    }

    private func deleteNotifications(_ update: [String: Any]) {
        guard let config = accessConfiguration, update["chat_id"] as? Int64 == Int64(config.botUserID), update["is_permanent"] as? Bool == true,
              let ids = update["message_ids"] as? [Int64] else { return }
        noticeHistory.remove(ids); notifications = noticeHistory.ordered.compactMap(AccessAnnouncement.init)
        if let current = announcement, ids.contains(current.id) { announcement = nil }
    }

    func announcementMedia(_ notice: AccessAnnouncement) async -> URL? {
        guard stage == .ready, let fileID = notice.fileID else { return nil }
        let session = accountSession
        guard let file = try? await requestJSON(["@type": "downloadFile", "file_id": fileID, "priority": 8, "synchronous": true]),
              !Task.isCancelled, accountSession == session, stage == .ready, let local = file["local"] as? [String: Any],
              local["is_downloading_completed"] as? Bool == true, let path = local["path"] as? String else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000 else { return nil }
        return url
    }

    func joinCommunity(_ channel: AccessConfiguration.Channel) {
        guard stage == .activation, accessConfiguration?.channels.contains(where: { $0.url == channel.url }) == true,
              let url = AccessConfiguration.safeLink(channel.url) else { return }
        guard !accessBusy else { return }
        accessBusy = true
        let session = accountSession
        Task {
            do {
                let path = String(url.path.dropFirst())
                if path.hasPrefix("+") || path.hasPrefix("joinchat/") {
                    _ = try await requestJSON(["@type": "joinChatByInviteLink", "invite_link": channel.url])
                } else {
                    let chat = try await requestJSON(["@type": "searchPublicChat", "username": path])
                    guard accountSession == session, stage == .activation, let id = chat["id"] as? Int64 else { return }
                    _ = try await requestJSON(["@type": "joinChat", "chat_id": id])
                }
                if accountSession == session, accessNonce.isEmpty { accessBusy = false }
                try await Task.sleep(nanoseconds: 2_100_000_000)
                if accountSession == session { checkAccess(start: true) }
            } catch { if accountSession == session, accessNonce.isEmpty { accessBusy = false; accessMessage = "Join may require approval. Open the channel or retry after approval." } }
        }
    }

    private func finishClosedClient() {
        noticeHistory = NoticeHistory(); notifications = []; notificationsCursor = 0; notificationsMore = true; notificationsLoading = false; notificationsError = ""
        authorizationSetup.reset()
        if let key = accessCacheKey { try? SecureStore.remove(key) }
        accessRefresh?.cancel(); accessActivated = false; accessDevice = ""; accessRevision = 0
        accessMissing = []; accessNeedsPaid = false; accessDenied = false
        accessTimer?.cancel(); accessNonce = ""; accessBusy = false; accessDeadline = nil; accessExpiry = 0; accessBotChat = 0; announcement = nil
        accountSession = UUID(); library.deactivate(); profileName = ""; profileUsername = ""
        for task in thumbnailRequests.values { task.cancel() }
        thumbnailRequests.removeAll(); loadingCollections.removeAll(); moreCollections.removeAll()
        isLoadingChats = false; collectionErrors = [:]; discoveryError = ""; isClearingCache = false; startingAccount = false
        downloadRecords = [:]; restoredDownloads = nil; reconcilingDownloads = nil
        fullDownloads.removeAll(); preparingDownloads.removeAll(); cancellingDownloads.removeAll(); rangeWindows.removeAll(); isAuthenticating = false
        videoSearchGeneration = UUID(); videoSearchQuery = ""; videoSearchScope = []; videoSearchChatID = nil; videoSearch = nil; videoSearchResults = []; isSearchingVideos = false; hasMoreVideoResults = false
        discovery = nil; pendingDiscoveryPage = nil; mediaWorker?.cancel(); mediaWorker = nil; mediaQueue.removeAll()
        searchGeneration = UUID(); isSearchingChats = false; chatSearchError = ""; hasMoreChats = true
        for task in requestTimeouts.values { task.cancel() }
        requestTimeouts.removeAll()
        let callbacks = Array(completions.values); completions.removeAll()
        callbacks.forEach { $0(.failure(CancellationError())) }
        clientID = td_create_client_id()
        if loggingOut {
            loggingOut = false; apiID = 0; apiHash = ""
            do { try SecureStore.remove("telegram_api_credentials") }
            catch { stage = .error(error.localizedDescription); return }
        }
        stage = .credentials
        connectUsingBuildCredentials()
    }

    private func configure() {
        guard let attempt = authorizationSetup.begin(hasCredentials: apiID > 0 && !apiHash.isEmpty) else { return }
        let client = clientID
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tevee/TDLib", isDirectory: true)
        let files = root.appendingPathComponent("files", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            let key = try SecureStore.databaseKey()
            send(["@type": "setTdlibParameters", "database_directory": root.path, "files_directory": files.path,
                "database_encryption_key": key.base64EncodedString(), "use_file_database": true, "use_chat_info_database": true,
                "use_message_database": true, "use_secret_chats": false, "api_id": apiID, "api_hash": apiHash,
                "system_language_code": Locale.current.language.languageCode?.identifier ?? "en", "device_model": "iPhone",
                "system_version": ProcessInfo.processInfo.operatingSystemVersionString, "application_version": "1.1"] ) { [weak self] result in
                    guard let self, self.clientID == client, !self.loggingOut else { return }
                    switch result {
                    case .success: _ = self.authorizationSetup.finish(attempt, succeeded: true)
                    case .failure(let error):
                        if self.authorizationSetup.finish(attempt, succeeded: false) {
                            self.stage = .error("Account setup failed: \(error.localizedDescription)")
                        }
                    }
                }
        } catch {
            if authorizationSetup.finish(attempt, succeeded: false) {
                stage = .error("Could not prepare secure storage: \(error.localizedDescription)")
            }
        }
    }
    private func send(_ request: [String: Any], completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        var request = request
        let id = requestID
        requestID += 1
        request["@extra"] = id
        do {
            let data = try JSONSerialization.data(withJSONObject: request)
            guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.propertyListWriteInvalid) }
            if let completion {
                completions[id] = completion
                requestTimeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                    catch { return }
                    guard let self else { return }
                    self.requestTimeouts.removeValue(forKey: id)
                    self.completions.removeValue(forKey: id)?(.failure(URLError(.timedOut)))
                }
            }
            text.withCString { td_send(clientID, $0) }
        } catch {
            if let completion { completion(.failure(error)) }
            else { status = "Account request failed: \(error.localizedDescription)" }
        }
    }

    nonisolated private static func parse(_ text: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return value
    }
}
