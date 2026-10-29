import Foundation
import SwiftUI
import UIKit
import ImageIO
import AVKit
import Combine

struct AccessAnnouncement: Identifiable {
    let id: Int64
    let text: String
    let entities: [[String: Any]]
    let fileID: Int32?
    let animation: Bool
    let mediaRatio: CGFloat
    let date: Date
    let hasMedia: Bool
    let video: Bool
    init?(message: [String: Any]) {
        guard let markup = message["reply_markup"] as? [String: Any], markup["@type"] as? String == "replyMarkupInlineKeyboard",
              let rows = markup["rows"] as? [[[String: Any]]], rows.flatMap({ $0 }).contains(where: { button in
                  guard let type = button["type"] as? [String: Any], type["@type"] as? String == "inlineKeyboardButtonTypeCallback",
                        let encoded = type["data"] as? String, let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8) else { return false }
                  return text.range(of: #"^notice:1:[0-9a-f]{32}$"#, options: .regularExpression) != nil
              }), let id = message["id"] as? Int64, let content = message["content"] as? [String: Any] else { return nil }
        self.id = id
        date = Date(timeIntervalSince1970: TimeInterval(message["date"] as? Int ?? 0))
        let formatted = content["text"] as? [String: Any] ?? content["caption"] as? [String: Any] ?? [:]
        text = formatted["text"] as? String ?? ""
        entities = formatted["entities"] as? [[String: Any]] ?? []
        animation = content["@type"] as? String == "messageAnimation"
        let media = content["animation"] as? [String: Any] ?? [:]
        video = animation && (media["mime_type"] as? String ?? "").hasPrefix("video/")
        var file = media["animation"] as? [String: Any]
        var width = media["width"] as? Double ?? 1
        var height = media["height"] as? Double ?? 1
        hasMedia = animation || content["@type"] as? String == "messagePhoto"
        if !animation, let sizes = (content["photo"] as? [String: Any])?["sizes"] as? [[String: Any]],
           let best = sizes.max(by: { ($0["width"] as? Int ?? 0) * ($0["height"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) * ($1["height"] as? Int ?? 0) }) {
            file = best["photo"] as? [String: Any]
            width = best["width"] as? Double ?? 1; height = best["height"] as? Double ?? 1
        }
        mediaRatio = CGFloat(max(0.01, width) / max(1, height))
        let size = max(file?["size"] as? Int64 ?? 0, file?["expected_size"] as? Int64 ?? 0)
        fileID = size <= 20_000_000 ? file?["id"] as? Int32 : nil

    }
    func dismissalKey(_ account: Int64) -> String { "access.notice.\(account).\(id)" }
    var formatted: AttributedString {
        let value = NSMutableAttributedString(string: text, attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label])
        for entity in entities {
            guard let offset = entity["offset"] as? Int, let length = entity["length"] as? Int, offset >= 0, length > 0,
                  offset <= value.length, length <= value.length - offset, let type = entity["type"] as? [String: Any] else { continue }
            let range = NSRange(location: offset, length: length)
            switch type["@type"] as? String {
            case "textEntityTypeBold": value.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize), range: range)
            case "textEntityTypeItalic": value.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize), range: range)
            case "textEntityTypeUnderline": value.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case "textEntityTypeStrikethrough": value.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case "textEntityTypeCode", "textEntityTypePre", "textEntityTypePreCode": value.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular), range: range)
            case "textEntityTypeTextUrl", "textEntityTypeUrl":
                let link = type["url"] as? String ?? (text as NSString).substring(with: range)
                if let url = URL(string: link), ["https", "http"].contains(url.scheme ?? "") { value.addAttribute(.link, value: url, range: range) }
            default: break
            }
        }
        return AttributedString(value)
    }
}

struct AccessAnnouncementBanner: View {
    let notice: AccessAnnouncement
    let open: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Image(systemName: "megaphone.fill").font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Announcement").font(.subheadline.bold())
                        Text(notice.text.isEmpty ? "New media from Cinespice" : notice.text).font(.subheadline).lineLimit(2)
                        Text("Tap to read").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Opens the full announcement")
            Button(action: dismiss) { Image(systemName: "xmark").padding(10) }
                .accessibilityLabel("Dismiss announcement")
        }.padding(16)
    }
}

struct AccessNotificationHistoryView: View {
    @EnvironmentObject private var telegram: TelegramClient
    @Environment(\.dismiss) private var dismiss
    @State private var selected: AccessAnnouncement?
    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            List {
                Color.clear.frame(height: 1).listRowSeparator(.hidden).id("notices-top")
                if telegram.notifications.isEmpty && !telegram.notificationsLoading && telegram.notificationsError.isEmpty { Text("No notifications yet").foregroundStyle(.secondary) }
                ForEach(telegram.notifications) { notice in
                    Button { selected = notice } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: notice.hasMedia ? "photo" : "text.bubble")
                            VStack(alignment: .leading, spacing: 6) {
                                Text(notice.text.isEmpty ? "Media announcement" : notice.text).lineLimit(3)
                                Text(notice.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption)
                        }.padding(.vertical, 8)
                    }.buttonStyle(.plain)
                }
                if !telegram.notificationsError.isEmpty {
                    Text(telegram.notificationsError).foregroundStyle(.secondary)
                    Button("Retry notifications") { telegram.loadAnnouncements() }
                }
                if telegram.notificationsLoading { ProgressView("Loading notifications…") }
                else if telegram.notificationsMore { Button("Load older notifications") { telegram.loadAnnouncements(refresh: false) } }
            }.navigationTitle("Notifications")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Button("Top") { scroll.scrollTo("notices-top", anchor: .top) }.disabled(telegram.notifications.isEmpty) }
                    ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } }
                }
                .refreshable { telegram.loadAnnouncements() }
                .fullScreenCover(item: $selected) { notice in AccessAnnouncementView(notice: notice) { selected = nil } }
                .onChange(of: telegram.notifications.map(\.id)) { ids in if let current = selected, !ids.contains(current.id) { selected = nil } }
            }
        }.task { telegram.loadAnnouncements() }
    }
}

struct AccessAnnouncementView: View {
    let notice: AccessAnnouncement
    let close: () -> Void
    @EnvironmentObject private var telegram: TelegramClient
    @State private var media: URL?
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var retry = 0
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if notice.hasMedia {
                            Group {
                                if let player, let item = player.currentItem {
                                    VideoPlayer(player: player).onReceive(item.publisher(for: \.status).receive(on: RunLoop.main)) { status in
                                        if status == .failed, self.player === player { player.pause(); self.player = nil; media = nil }
                                    }
                                }
                                else if let media { AnnouncementImage(url: media) }
                                else if loading { ProgressView("Loading media…") }
                                else { VStack(spacing: 12) { Text("Media could not be loaded."); Button("Retry") { retry += 1 } } }
                            }.frame(width: max(1, geometry.size.width - 40), height: min(420, max(120, (geometry.size.width - 40) / notice.mediaRatio)))
                                .clipped().background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if !notice.text.isEmpty { Text(notice.formatted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(20).frame(width: geometry.size.width)
                }
            }.navigationTitle("From Cinespice").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close", action: close) } }
        }.task(id: retry) {
            guard notice.hasMedia else { return }
            loading = true
            let loaded = await telegram.announcementMedia(notice)
            guard !Task.isCancelled else { return }
            if let loaded, !notice.video {
                let decodable = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(loaded as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return false }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary) != nil
                }.value
                media = decodable ? loaded : nil
            } else { media = loaded }
            guard !Task.isCancelled else { media = nil; return }
            loading = false
            if let media, notice.video {
                player = AVPlayer(url: media); player?.isMuted = true; player?.play()
            }
        }.onDisappear { player?.pause(); player = nil }
    }
}

/// No intrinsic pixel size is offered to SwiftUI: the parent supplies the exact viewport.
private final class FittedAnnouncementImage: UIImageView {
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
}
private struct AnnouncementImage: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> UIImageView {
        let view = FittedAnnouncementImage(); view.contentMode = .scaleAspectFit; view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let first = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= 150, Int64(first.width)*Int64(first.height)*Int64(count) <= 25_000_000 else { view.image = UIImage(cgImage: first); return }
        var frames: [UIImage] = []; var duration = 0.0
        for index in 0..<count {
            if let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) { frames.append(UIImage(cgImage: image)) }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            duration += max(0.02, gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1)
        }
        view.image = UIImage.animatedImage(with: frames, duration: duration)
    }
}
