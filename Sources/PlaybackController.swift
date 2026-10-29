import Foundation
import Combine
import AVFoundation
import MobileVLCKit

struct PlaybackSelection: Identifiable {
    let id = UUID()
    let video: TelegramVideo
    let url: URL
    var resume = true
}

struct PlayerTrack: Identifiable {
    let id: Int32
    let name: String
}

@MainActor
final class PlaybackController: ObservableObject {
    let player = VLCMediaPlayer()
    let selection: PlaybackSelection
    private let library: LibraryStore
    private let sessionID: UUID
    @Published var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var state: VLCMediaPlayerState = .stopped
    @Published private(set) var seekable = false
    @Published private(set) var audioTracks: [PlayerTrack] = []
    @Published private(set) var subtitleTracks: [PlayerTrack] = []
    @Published private(set) var error = ""
    @Published private(set) var resumeWarning = ""
    @Published private(set) var selectedAudio: Int32 = -1
    @Published private(set) var selectedSubtitle: Int32 = -1
    @Published private(set) var subtitleDelay: Double = 0
    @Published private(set) var audioDelay: Double = 0
    private let attachmentsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TeveeAttachments/\(UUID().uuidString)", isDirectory: true)
    @Published private(set) var rate: Float = 1
    var scrubbing = false
    private var poll: Task<Void, Never>?
    private var recovery = PlaybackRecovery()
    private var initialPosition: Double = 0
    private var hasPlayed = false
    private var started = false
    private var ticks = 0
    private var savedEnd = false
    private var stopped = false
    @Published private(set) var isBuffering = false
    @Published private(set) var isOpening = true
    @Published private(set) var subtitleSize = SubtitleSize.restored(UserDefaults.standard.integer(forKey: "Cinespice.subtitlePoints"), legacy: UserDefaults.standard.integer(forKey: "Cinespice.subtitleSize"))
    @Published private(set) var subtitleStyleWarning = ""
    private var styledSubtitle: Int32?
    private var styledPlayback = false
    private var subtitleSelection = SubtitleSelection()
    private var viewport = (width: 0.0, height: 0.0, scale: 1.0)
    private var appliedPicture: PlayerPictureLayout?
    private var activity = PlaybackActivity()
    @Published private(set) var userPaused = false
    var showsPause: Bool { !userPaused && state != .ended && state != .error }
    private var resumeAfterBackground = false
    @Published var aspect: PlayerAspect = .fit { didSet { applyPicture() } }
    @Published var edgeToEdge = false

    init(selection: PlaybackSelection, library: LibraryStore) {
        self.selection = selection; self.library = library; sessionID = library.sessionID
        let saved = library.snapshot.history[selection.video.id]
        initialPosition = selection.resume && saved?.canResume == true ? saved?.position ?? 0 : 0
    }
    deinit { poll?.cancel() }

    func start() {
        guard !started, !stopped else { return }; started = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { started = false; isOpening = false; self.error = "Audio setup failed: \(error.localizedDescription)"; return }
        if initialPosition > 0 { recovery.begin(initialPosition, resuming: true) }
        player.media = VLCMedia(url: selection.url)
        player.play()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        state = player.state
        seekable = player.isSeekable
        let current = max(0, (player.time.value?.doubleValue ?? 0) / 1000)
        isBuffering = activity.stalled(time: current, waiting: state == .opening || state == .buffering || state == .playing, paused: userPaused || state == .paused || state == .ended || state == .error)
        duration = max(0, (player.media?.length.value?.doubleValue ?? 0) / 1000)
        switch recovery.poll(position: current) {
        case .reached: resumeWarning = ""
        case .timedOut:
            pause()
            resumeWarning = "The requested position could not be reached. Retry, start from the beginning, or download the file."
        case .waiting: break
        }
        if seekable, duration > 0, let target = recovery.issue(duration: duration) {
            player.time = VLCTime(number: NSNumber(value: target * 1000))
        }
        if !scrubbing { position = recovery.target ?? current }
        audioTracks = tracks(player.audioTrackNames, player.audioTrackIndexes)
        subtitleTracks = tracks(player.videoSubTitlesNames, player.videoSubTitlesIndexes)
        selectedAudio = player.currentAudioTrackIndex; selectedSubtitle = player.currentVideoSubTitleIndex
        if state == .playing || state == .paused || state == .buffering {
            if let desired = subtitleSelection.desired(available: subtitleTracks.map(\.id), current: selectedSubtitle) {
                player.currentVideoSubTitleIndex = desired
                selectedSubtitle = player.currentVideoSubTitleIndex
            }
        }
        // A drawable/layout callback can happen before VLC has opened a video output.
        // Reapply when real dimensions arrive, including an adaptive size change.
        applyPicture()
        if state == .error { error = "The player could not play this video. Try Download, then reopen it."; isOpening = false }
        if state == .ended { isOpening = false }
        if state == .playing || (current > 0 && player.isPlaying) { hasPlayed = true; isOpening = false }
        // The renderer is created asynchronously. Apply once it is playing, and
        // again after a subtitle track change (including an imported file).
        if hasPlayed, !styledPlayback || styledSubtitle != selectedSubtitle {
            applySubtitleSize(); styledPlayback = true; styledSubtitle = selectedSubtitle
        }
        ticks += 1
        if state == .ended, !savedEnd { save(completed: true); savedEnd = true }
        else if state == .playing || state == .paused || (state == .buffering && current > 0) {
            savedEnd = false
            if ticks % 10 == 0 { save() }
        }
    }

    func toggle() {
        // Follow the user's intent immediately, even while VLC is opening or
        // buffering and isPlaying has not caught up with the last command.
        if showsPause { pause() }
        else if recovery.failedTarget != nil { retryPosition() }
        else { userPaused = false; player.play() }
        save()
    }
    func pause() { resumeAfterBackground = false; userPaused = true; isBuffering = false; player.pause(); save() }
    func suspend() {
        let shouldResume = !userPaused && (player.isPlaying || state == .opening || state == .buffering)
        pause()
        resumeAfterBackground = shouldResume
    }
    func restoreForeground() {
        if resumeAfterBackground { userPaused = false; player.play() }
        resumeAfterBackground = false
    }
    func configureViewport(width: Double, height: Double, displayScale: Double) {
        viewport = (width, height, displayScale)
        applyPicture()
    }
    private func applyPicture() {
        guard !stopped else { return }
        let video = player.videoSize
        guard let layout = aspect.layout(width: viewport.width, height: viewport.height,
                                         videoWidth: Double(video.width), videoHeight: Double(video.height), displayScale: viewport.scale),
              layout != appliedPicture else { return }
        player.videoCropGeometry = nil
        if let ratio = layout.aspect {
            ratio.withCString { player.videoAspectRatio = UnsafeMutablePointer(mutating: $0) }
        } else { player.videoAspectRatio = nil }
        player.scaleFactor = layout.scale
        appliedPicture = layout
        applySubtitleSize()
    }
    func seek(_ delta: Double) { position = min(max(duration, 0), max(0, position + delta)); commitSeek() }
    func commitSeek() {
        guard seekable else { return }
        resumeWarning = ""
        recovery.begin(position)
        if let target = recovery.issue(duration: duration) {
            player.time = VLCTime(number: NSNumber(value: target * 1000))
        }
    }
    func retryPosition() {
        guard let target = recovery.failedTarget else { return }
        recovery.begin(target); resumeWarning = ""; userPaused = false; player.play()
    }
    func startOver() {
        recovery.begin(0); resumeWarning = ""; position = 0; userPaused = false; player.play()
    }
    func setRate(_ value: Float) { rate = value; player.rate = value }
    func selectAudio(_ id: Int32) { selectedAudio = id; player.currentAudioTrackIndex = id }
    func selectSubtitle(_ id: Int32) { subtitleSelection.select(id); selectedSubtitle = id; player.currentVideoSubTitleIndex = id; styledSubtitle = nil }

    func setSubtitleSize(_ size: SubtitleSize) {
        subtitleSize = size
        UserDefaults.standard.set(size.points, forKey: "Cinespice.subtitlePoints")
        applySubtitleSize()
    }
    private func applySubtitleSize() {
        // VLCKit 3.7.4 implements this selector; VLC iOS uses it as well, though
        // it is not in the public header. Guard it when changing VLCKit versions.
        guard let height = appliedPicture?.pictureHeight,
              let divisor = subtitleSize.rendererDivisor(pictureHeight: height) else { return }
        let selector = NSSelectorFromString("setTextRendererFontSize:")
        guard player.responds(to: selector) else {
            subtitleStyleWarning = "The player cannot change subtitle size during playback."
            return
        }
        _ = player.perform(selector, with: NSNumber(value: divisor))
        subtitleStyleWarning = ""
    }

    func adjustSubtitleDelay(_ seconds: Double) {
        subtitleDelay = min(30, max(-30, subtitleDelay + seconds))
        player.currentVideoSubTitleDelay = Int(subtitleDelay * 1_000_000)
    }
    func adjustAudioDelay(_ seconds: Double) {
        audioDelay = min(30, max(-30, audioDelay + seconds))
        player.currentAudioPlaybackDelay = Int(audioDelay * 1_000_000)
    }

    /// Imported files are sandbox copies for this playback session only.
    func importAttachments(_ urls: [URL], audio: Bool) async {
        let directory = attachmentsDirectory
        do {
            let copies = try await Task.detached(priority: .userInitiated) {
                guard !urls.isEmpty, urls.count <= 8 else { throw CocoaError(.fileReadTooLarge) }
                let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "smi", "sami", "ttml", "sbv"]
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var copies: [URL] = []
                do {
                    for url in urls {
                        guard (audio ? TelegramVideo.audioExtensions : subtitleExtensions).contains(url.pathExtension.lowercased()) else { throw CocoaError(.fileReadCorruptFile) }
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let destination = directory.appendingPathComponent(url.lastPathComponent)
                        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
                        if !audio {
                            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw CocoaError(.fileReadUnknown) }
                            guard size >= 0, size <= 20 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                        }
                        try FileManager.default.copyItem(at: url, to: destination)
                        copies.append(destination)
                    }
                    return copies
                } catch {
                    for copy in copies { try? FileManager.default.removeItem(at: copy) }
                    throw error
                }
            }.value
            guard !stopped, library.sessionID == sessionID else {
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
                return
            }
            let tracks = audio ? copies : SubtitleAttachments.tracks(in: copies)
            for copy in tracks {
                let result = player.addPlaybackSlave(copy, type: audio ? .audio : .subtitle, enforce: true)
                if result == 0, !audio { subtitleSelection.imported(); styledSubtitle = nil }
                guard result == 0 else { throw NSError(domain: "Tevee.Player", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "The player could not attach \(copy.lastPathComponent). Check the file format and try again."]) }
            }
        } catch { self.error = "Could not load external track: \(error.localizedDescription)" }
    }

    private func save(completed: Bool = false) {
        guard hasPlayed, error.isEmpty, !recovery.protectsProgress, !scrubbing, library.sessionID == sessionID else { return }
        let current = max(0, (player.time.value?.doubleValue ?? 0) / 1000)
        let length = duration > 0 ? duration : Double(selection.video.duration)
        let video = selection.video
        let session = sessionID
        let recordedAt = Date()
        let didComplete = completed || state == .ended
        Task { [library] in
            guard library.sessionID == session else { return }
            await library.record(video, position: current, duration: length, completed: didComplete, updatedAt: recordedAt)
        }
    }

    func stop() {
        guard !stopped else { return }; stopped = true
        poll?.cancel(); poll = nil; isOpening = false; isBuffering = false
        save(completed: player.state == .ended)
        player.stop()
        let directory = attachmentsDirectory
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { library.report("Could not release audio: \(error.localizedDescription)") }
    }
    private func tracks(_ names: [Any], _ indexes: [Any]) -> [PlayerTrack] {
        zip(names, indexes).compactMap { name, index in
            guard let value = index as? NSNumber else { return nil }
            return PlayerTrack(id: value.int32Value, name: String(describing: name))
        }
    }
}
