import SwiftUI
import AVFoundation
import MobileVLCKit
import UniformTypeIdentifiers
import UIKit

struct VLCPlaybackView: View {
    @AppStorage("cinespice.theme") private var theme: CinespiceTheme = .dark
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var telegram: TelegramClient
    @EnvironmentObject private var rangeServer: TelegramRangeServer
    @Environment(\.scenePhase) private var phase
    @StateObject private var playback: PlaybackController
    @ObservedObject private var orientation = PlayerOrientation.shared
    @State private var controlsVisible = true
    @State private var controlLock = PlayerControlLock()
    @State private var unlockInteraction = UUID()
    @State private var importing = false
    @State private var importAudio = false
    @State private var panel: String?
    @State private var trackTab = "Subtitles"
    @State private var closing = false
    @State private var pressingControl = false
    @State private var interaction = UUID()
    @State private var actionFeedback = ""
    @State private var feedbackToken = UUID()
    @State private var message = ""
    @State private var suspended = false
    private let onClose: () -> Void
    private var spice: Color { theme.playerAccent }

    init(selection: PlaybackSelection, library: LibraryStore, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _playback = StateObject(wrappedValue: PlaybackController(selection: selection, library: library))
    }
    private var locked: Bool { controlLock.locked }
    private var streaming: Bool { playback.selection.url.host == "127.0.0.1" }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                VLCVideoSurface(player: playback.player, expanded: playback.edgeToEdge, insets: geometry.safeAreaInsets) { size, scale in
                    playback.configureViewport(width: Double(size.width), height: Double(size.height), displayScale: Double(scale))
                }
                    .allowsHitTesting(false)
                    .ignoresSafeArea(.container)
                if !controlsVisible && !locked && panel == nil { videoGestures }
                if playback.isOpening || playback.isBuffering {
                    VStack(spacing: 12) {
                        ProgressView().tint(spice).scaleEffect(1.2)
                        Text(playback.isOpening ? "Opening media…" : "Buffering…").font(.caption.weight(.medium))
                    }.padding(20).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                        .allowsHitTesting(false)
                }
                if controlsVisible && !locked {
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.7), location: 0),
                        .init(color: .clear, location: 0.3),
                        .init(color: .clear, location: 0.55),
                        .init(color: .black.opacity(0.85), location: 1)
                    ], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                    if dynamicTypeSize.isAccessibilitySize || geometry.size.height < 300 {
                        ScrollView { playerChrome(geometry.size, scrolling: true) }
                            .accessibilityHidden(panel != nil)
                    } else {
                        playerChrome(geometry.size, scrolling: false).accessibilityHidden(panel != nil)
                    }
                }
                if !actionFeedback.isEmpty {
                    Text(actionFeedback).font(.subheadline.weight(.semibold)).padding(12)
                        .background(.black.opacity(0.75), in: Capsule()).allowsHitTesting(false)
                }
                if locked { lockedOverlay }
                if let panel {
                    Color.clear.contentShape(Rectangle()).onTapGesture { self.panel = nil }
                    VStack {
                        Spacer(minLength: 0)
                        options(panel, maxHeight: min(600, max(1, geometry.size.height - 32)) * (geometry.size.width > geometry.size.height ? 1 : 0.85))
                    }.frame(maxWidth: geometry.size.width > geometry.size.height ? 400 : 460)
                        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: geometry.size.width > geometry.size.height ? .bottomTrailing : .bottom)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: panel)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .buttonStyle(CinespicePressStyle { pressed in
            pressingControl = pressed; interaction = UUID()
        })
        .onAppear { playback.start(); UIApplication.shared.isIdleTimerDisabled = true }
        .accessibilityAction(.escape) { if locked { unlockControls() } else { closePlayer() } }
        .onDisappear {
            if streaming { rangeServer.stop() }
            playback.stop()
            orientation.setLandscape(false)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .task(id: "\(controlsVisible)_\(playback.state.rawValue)_\(panel ?? "")_\(interaction)") {
            guard controlsVisible, playback.state == .playing, panel == nil, !pressingControl, !playback.scrubbing, !importing else { return }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            if !UIAccessibility.isVoiceOverRunning && !playback.scrubbing && !importing && playback.error.isEmpty && playback.resumeWarning.isEmpty { controlsVisible = false }
        }
        .task(id: unlockInteraction) {
            guard locked, controlLock.unlockVisible else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            if !UIAccessibility.isVoiceOverRunning { controlLock.hideUnlock() }
        }
        .task(id: feedbackToken) {
            guard !actionFeedback.isEmpty else { return }
            do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return }
            actionFeedback = ""
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await playback.importAttachments(urls, audio: importAudio); controlsVisible = true }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .onChange(of: phase) { state in
            if state != .active && !suspended { suspended = true; playback.suspend(); UIApplication.shared.isIdleTimerDisabled = false }
            if state == .active && suspended { suspended = false; playback.restoreForeground(); UIApplication.shared.isIdleTimerDisabled = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: raw) == .began { playback.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            if let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable { playback.pause() }
        }
        .onChange(of: playback.error) { error in if !error.isEmpty { unlockControls() } }
        .onChange(of: playback.resumeWarning) { warning in if !warning.isEmpty { unlockControls() } }
    }
    private var lockedOverlay: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { controlLock.reveal(); unlockInteraction = UUID() }
                .accessibilityLabel("Player controls locked")
                .accessibilityHint("Activate to show the unlock button")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { controlLock.reveal(); unlockInteraction = UUID() }
            if controlLock.unlockVisible {
                HStack {
                    Button(action: unlockControls) {
                        Image(systemName: "lock.open").font(.system(size: 18, weight: .semibold))
                            .frame(width: 48, height: 48).background(.black.opacity(0.6), in: Circle())
                    }.accessibilityLabel("Unlock controls").accessibilityIdentifier("player.unlock")
                    Spacer()
                }.padding(.horizontal, 16)
            }
        }
    }
    private func playerChrome(_ size: CGSize, scrolling: Bool) -> some View {
        VStack(spacing: 16) {
            topBar
            videoGestures.frame(minHeight: scrolling ? 44 : 16, maxHeight: scrolling ? 44 : .infinity)
            VStack(spacing: 12) {
                if !playback.error.isEmpty { notice(playback.error) }
                if !message.isEmpty { notice(message) }
                if !playback.resumeWarning.isEmpty {
                    notice(playback.resumeWarning)
                    HStack {
                        Button("Retry position") { playback.retryPosition() }
                        Button("Start from beginning") { playback.startOver() }
                    }.font(.subheadline.bold())
                }
                timeline
                controlRow(availableWidth: min(1000, size.width - (size.width >= 700 ? 64 : 32)))

            }.frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }.padding(.horizontal, size.width >= 700 ? 32 : 16).padding(.vertical, 12)
    }
    private func lockControls() {
        panel = nil; controlsVisible = false; actionFeedback = ""
        controlLock.lock(); unlockInteraction = UUID()
        UIAccessibility.post(notification: .announcement, argument: "Controls locked. Tap the video to show Unlock.")
    }
    private func unlockControls() {
        controlLock.unlock(); controlsVisible = true; interaction = UUID()
    }
    private var videoGestures: some View {
        HStack(spacing: 0) { tapArea(-10); tapArea(10) }
            .allowsHitTesting(!locked && panel == nil)
    }
    private func tapArea(_ seconds: Double) -> some View {
        Color.clear.contentShape(Rectangle())
            .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { value in
                switch value {
                case .first:
                    guard playback.seekable else { feedback("Seeking not available yet"); return }
                    playback.seek(seconds); controlsVisible = true
                    feedback(seconds < 0 ? "−10 seconds" : "+10 seconds")
                case .second: controlsVisible.toggle(); interaction = UUID()
                }
            }).accessibilityHidden(true)
    }
    private func feedback(_ text: String) {
        actionFeedback = text; feedbackToken = UUID(); interaction = UUID()
    }
    private func notice(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true) }
    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: closePlayer) { Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).frame(width: 48, height: 48).contentShape(Rectangle()) }
                .accessibilityLabel("Close player").accessibilityIdentifier("player.close").disabled(closing)
            Text(playback.selection.video.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 0)
            rotateTool

        }
    }
    private func controlRow(availableWidth: CGFloat) -> some View {
        let slot = max(dynamicTypeSize.isAccessibilitySize ? 60 : 44, (availableWidth - 72) / 6)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                Button(action: lockControls) {
                    Image(systemName: "lock.open").frame(width: slot, height: 48)
                }.accessibilityLabel("Lock controls")
                trackTool.frame(width: slot)
                Button { playback.seek(-10); feedback("−10 seconds") } label: {
                    Image(systemName: "gobackward.10").frame(width: slot, height: 48)
                }.disabled(!playback.seekable).accessibilityLabel("Back ten seconds")
                Button { playback.toggle(); feedback(playback.showsPause ? "Resuming…" : "Paused") } label: {
                    Image(systemName: playback.showsPause ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .semibold)).frame(width: 72, height: 38)
                        .background(theme.playerAction, in: Capsule()).foregroundStyle(theme.onAction)
                        .frame(height: 48).contentShape(Rectangle())
                }.accessibilityLabel(playback.showsPause ? "Pause" : "Play")
                Button { playback.seek(10); feedback("+10 seconds") } label: {
                    Image(systemName: "goforward.10").frame(width: slot, height: 48)
                }.disabled(!playback.seekable).accessibilityLabel("Forward ten seconds")
                pictureTool.frame(width: slot)
                moreTool.frame(width: slot)
            }.font(.system(size: 21, weight: .medium))
        }
    }
    private var timeline: some View {
        VStack(spacing: 0) {
            Slider(value: $playback.position, in: 0...max(max(playback.duration, playback.position), 1)) { editing in
                playback.scrubbing = editing; interaction = UUID()
                if !editing { playback.commitSeek() }
            }.tint(spice).disabled(!playback.seekable).accessibilityLabel("Playback position")
            HStack { Text(time(playback.position)); Spacer(); Text("−" + time(max(0, playback.duration - playback.position))) }
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
        }
    }
    private func tool(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 21, weight: .medium))
                .frame(minWidth: 44, minHeight: 48).contentShape(Rectangle())
        }.accessibilityLabel(title)
    }
    private var trackTool: some View { tool("Tracks", "captions.bubble") { panel = "Tracks" } }
    private var rotateTool: some View { tool("Rotate", "rotate.right") { orientation.setLandscape(!orientation.landscape) { message = $0 }; feedback(orientation.landscape ? "Landscape locked" : "Portrait locked") } }
    private var pictureTool: some View { tool("Picture", "aspectratio") { panel = "Picture" }.accessibilityValue(playback.aspect.rawValue) }
    private var moreTool: some View { tool("More", "ellipsis") { panel = "More" } }

    private func closePlayer() {
        guard !closing else { return }; closing = true
        // Clear the actual cover binding. Do not rely on an inherited dismiss
        // environment when UIKit/VLC has installed its video drawable.
        if streaming { rangeServer.stop() }
        onClose()
        playback.stop()
    }
    private var panelSurface: Color { theme == .glass ? CinespiceTheme.dark.surface : theme.surface }
    private func options(_ title: String, maxHeight: CGFloat) -> some View {
        VStack(spacing: 4) {
            HStack { Text(title).font(.headline); Spacer(); Button { panel = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Close options") }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if title == "Speed" {
                        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 80))], spacing: 10) {
                            ForEach([Float(0.25), 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4], id: \.self) { rate in
                                option(String(format: "%g×", Double(rate)), selected: rate == playback.rate) { playback.setRate(rate) }
                            }
                        }
                    } else if title == "Picture" {
                        ForEach(PlayerAspect.allCases) { ratio in option(ratio.rawValue, selected: playback.aspect == ratio) { playback.aspect = ratio } }
                        option("Use screen edges", selected: playback.edgeToEdge) { playback.edgeToEdge.toggle() }
                        Text("Fit shows the full picture. Fill zooms and crops without stretching. Ratios change the picture proportions. Screen edges extends video under the camera and home indicator; controls stay inside the safe area.").font(.caption).foregroundStyle(.secondary)
                    } else if title == "Tracks" {
                        trackOptions
                    } else if title == "Subtitle size" {
                        subtitleSizeOptions
                    } else {
                        LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 110))], spacing: 10) {
                            option("Speed") { panel = "Speed" }
                            option("Audio & subtitles") { panel = "Tracks" }
                            option("Subtitle size") { panel = "Subtitle size" }
                            option("Picture") { panel = "Picture" }
                            option("Lock controls", action: lockControls)
                        }
                        option("Download video") { let video = playback.selection.video; closePlayer(); telegram.download(video) }
                        Text("Downloads stay in the library. Use Save to device on the completed video's menu to export its original filename.").font(.caption).foregroundStyle(.secondary)
                        Text("Created by Masalaots · @notmasalaoats").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(16).frame(maxHeight: maxHeight).background(panelSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }
    private var trackOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            let tabs = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            tabs {
                ForEach(["Audio", "Subtitles"], id: \.self) { name in
                    option(name, selected: trackTab == name) { trackTab = name }
                }
            }
            if trackTab == "Audio" {
                if playback.audioTracks.isEmpty { Text("No audio tracks reported yet.").font(.caption).foregroundStyle(.secondary) }
                ForEach(playback.audioTracks) { track in option(track.name, selected: playback.selectedAudio == track.id) { playback.selectAudio(track.id) } }
                option("Open external audio…") { importAudio = true; importing = true; playback.pause() }
                delay("Audio", value: playback.audioDelay, adjust: playback.adjustAudioDelay)
            } else {
                if playback.subtitleTracks.allSatisfy({ $0.id < 0 }) {
                    Text("No embedded subtitles reported yet. They may appear after playback starts. You can also open a subtitle file.").font(.caption).foregroundStyle(.secondary)
                }
                option("Off", selected: playback.selectedSubtitle == -1) { playback.selectSubtitle(-1) }
                ForEach(playback.subtitleTracks.filter { $0.id >= 0 }) { track in option(track.name, selected: playback.selectedSubtitle == track.id) { playback.selectSubtitle(track.id) } }
                option("Open subtitle file…") { importAudio = false; importing = true; playback.pause() }
                Text("For VobSub, select both matching .idx and .sub files.").font(.caption).foregroundStyle(.secondary)
                option("Subtitle size · " + playback.subtitleSize.title) { panel = "Subtitle size" }
                delay("Subtitle", value: playback.subtitleDelay, adjust: playback.adjustSubtitleDelay)
            }
        }
    }
    private var subtitleSizeOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subtitle size · " + playback.subtitleSize.title).font(.subheadline)
            Slider(value: Binding(get: { Double(playback.subtitleSize.points) }, set: { playback.setSubtitleSize(SubtitleSize(Int($0.rounded()))) }), in: 6...18, step: 1)
                .tint(spice).accessibilityLabel("Subtitle size").accessibilityValue(playback.subtitleSize.title)
            HStack { Text("6 pt"); Spacer(); Text("18 pt") }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("Uses iOS points (logical pixels). The player approximates this text size for the current picture. Saved for future videos. Picture subtitles and some styled ASS/SSA tracks keep their own size.").font(.caption).foregroundStyle(.secondary)
            if !playback.subtitleStyleWarning.isEmpty { notice(playback.subtitleStyleWarning) }
            option("Back to subtitles") { panel = "Tracks"; trackTab = "Subtitles" }
        }
    }
    private func option(_ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { Text(title); Spacer(); if selected { Image(systemName: "checkmark").foregroundStyle(spice) } }.font(.subheadline).padding(12).frame(minHeight: 44).background(selected ? spice.opacity(0.18) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10)) }
    }
    private func delay(_ title: String, value: Double, adjust: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: "%@ delay %+.2f s", title, value)).font(.caption)
            HStack(spacing: 16) {
                Button { adjust(-0.25) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }.accessibilityLabel("Decrease " + title.lowercased() + " delay")
                Button { adjust(0.25) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("Increase " + title.lowercased() + " delay")
                Spacer(minLength: 0)
                Button { adjust(-value) } label: { Text("Reset").font(.caption).frame(minWidth: 44, minHeight: 44) }
            }
        }
    }
    private func time(_ value: Double) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The SwiftUI surface always occupies the same full-screen container. Only the
/// UIKit drawable frame changes, keeping VLC's renderer attached during rotation
/// and safe-area toggles. Controls remain in the outer safe-area layout.
private struct VLCVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer
    let expanded: Bool
    let insets: EdgeInsets
    let onLayout: (CGSize, CGFloat) -> Void
    func makeUIView(context: Context) -> VLCVideoContainer {
        let view = VLCVideoContainer(frame: .zero)
        view.onLayout = onLayout
        player.drawable = view.drawable
        return view
    }
    func updateUIView(_ view: VLCVideoContainer, context: Context) {
        view.expanded = expanded
        view.videoInsets = UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
        view.onLayout = onLayout
        view.setNeedsLayout()
    }
}

private final class VLCVideoContainer: UIView {
    let drawable = UIView()
    var expanded = false
    var videoInsets = UIEdgeInsets.zero
    var onLayout: ((CGSize, CGFloat) -> Void)?
    private var previousSize = CGSize.zero
    private var previousScale: CGFloat = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; clipsToBounds = true
        drawable.backgroundColor = .black; drawable.clipsToBounds = true
        addSubview(drawable)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow(); setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let proposed = expanded ? bounds : bounds.inset(by: videoInsets)
        // Never collapse or detach a live renderer during a transient zero layout.
        guard proposed.width > 0, proposed.height > 0 else { return }
        if drawable.frame != proposed { drawable.frame = proposed }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        guard proposed.size != previousSize || scale != previousScale else { return }
        previousSize = proposed.size; previousScale = scale
        let size = proposed.size
        // A UIView layout callback must not synchronously publish SwiftUI state.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.previousSize == size, self.previousScale == scale else { return }
            self.onLayout?(size, scale)
        }
    }
}
