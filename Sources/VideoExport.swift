import SwiftUI
import UIKit

struct VideoExport: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    var directory: URL { url.deletingLastPathComponent() }
    static func prepare(_ video: TelegramVideo) async throws -> VideoExport {
        guard video.isDownloaded, !video.localPath.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        return try await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CinespiceExport/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = ((video.fileName ?? video.title) as NSString).lastPathComponent
            let name = original.isEmpty || original == "." || original == ".." ? "Video-\(video.messageID).mp4" : original
            let target = directory.appendingPathComponent(name)
            do {
                let source = URL(fileURLWithPath: video.localPath)
                do { try FileManager.default.linkItem(at: source, to: target) }
                catch { try FileManager.default.copyItem(at: source, to: target) }
                return VideoExport(url: target)
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }.value
    }
}

struct VideoExportPicker: UIViewControllerRepresentable {
    let file: VideoExport
    let done: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done() }
    }
}
