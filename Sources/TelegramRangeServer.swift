import Foundation
import Combine
import Network

@MainActor
final class TelegramRangeServer: ObservableObject {
    @Published private(set) var status = ""
    private var listener: NWListener?
    private var sessionID = UUID()
    private var connections: [UUID: NWConnection] = [:]
    private var requests: [UUID: Task<Void, Never>] = [:]
    private let queue = DispatchQueue(label: "app.tevee.range-server", qos: .userInitiated)

    func open(video: TelegramVideo, using telegram: TelegramClient) async throws -> URL {
        stop()
        guard video.size > 0 else {
            throw NSError(domain: "Tevee.Stream", code: 7, userInfo: [NSLocalizedDescriptionKey: "The video size is unknown. Download it before playback."])
        }
        status = "Streaming video."
        let session = sessionID
        let path = "/\(session.uuidString)/video"
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        let newListener = try NWListener(using: parameters)
        listener = newListener
        newListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == session else { connection.cancel(); return }
                let id = UUID()
                connection.start(queue: self.queue)
                self.connections[id] = connection
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed, .cancelled:
                        Task { @MainActor [weak self] in self?.requests[id]?.cancel() }
                    default: break
                    }
                }
                self.requests[id] = Task { [weak self] in
                    guard let self else { connection.cancel(); return }
                    await self.serve(connection, video: video, telegram: telegram, path: path)
                    self.connections.removeValue(forKey: id)
                    self.requests.removeValue(forKey: id)
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let gate = StreamResumeGate()
                newListener.stateUpdateHandler = { [weak newListener] state in
                    switch state {
                    case .ready:
                        guard let port = newListener?.port,
                              let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(path)") else {
                            gate.resumeOnce { continuation.resume(throwing: URLError(.badURL)) }
                            return
                        }
                        gate.resumeOnce { continuation.resume(returning: url) }
                    case let .failed(error):
                        gate.resumeOnce { continuation.resume(throwing: error) }
                    case .cancelled:
                        gate.resumeOnce { continuation.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                newListener.start(queue: queue)
                if Task.isCancelled { newListener.cancel() }
            }
        } onCancel: {
            newListener.cancel()
        }
    }

    func stop() {
        sessionID = UUID()
        listener?.cancel()
        listener = nil
        for task in requests.values { task.cancel() }
        for connection in connections.values { connection.cancel() }
        requests.removeAll()
        connections.removeAll()
    }

    func report(_ message: String) { status = message }

    private func serve(_ connection: NWConnection, video: TelegramVideo, telegram: TelegramClient, path: String) async {
        // Bound incomplete request headers. Media responses may last hours;
        // their individual writes and TDLib reads have separate deadlines.
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { connection.cancel() }
        }
        defer { timeout.cancel(); connection.cancel() }
        var responseStarted = false
        do {
            let request = try await readRequest(connection)
            timeout.cancel()
            let response = HTTPVideoResponse.make(request: request, path: path, size: video.size, mimeType: video.mimeType)
            try Task.checkCancellation()
            responseStarted = true
            try await send(response.headers, on: connection)
            guard response.sendsBody else { return }
            var position = response.start
            let end = response.start + response.length
            while position < end {
                try Task.checkCancellation()
                let count = Int(min(1024 * 1024, end - position))
                let bytes = try await telegram.readRange(video: video, offset: position, length: count)
                guard !bytes.isEmpty, bytes.count <= count else { throw URLError(.cannotDecodeContentData) }
                try await send(bytes, on: connection)
                position += Int64(bytes.count)
            }
        } catch {
            guard !Task.isCancelled else { return }
            status = "Streaming interrupted: \(error.localizedDescription). Download is available."
            // A response already in progress must end with a short body/closed
            // connection; a second status line would corrupt the video bytes.
            if !responseStarted {
                let response = Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
                try? await send(response, on: connection)
            }
        }
    }

    private func readRequest(_ connection: NWConnection) async throws -> String {
        var collected = Data()
        while collected.range(of: Data("\r\n\r\n".utf8)) == nil {
            try Task.checkCancellation()
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, done, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if done { continuation.resume(throwing: URLError(.networkConnectionLost)) }
                    else { continuation.resume(throwing: URLError(.badServerResponse)) }
                }
            }
            collected.append(chunk)
            if collected.count > 64 * 1024 { throw URLError(.dataLengthExceedsMaximum) }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try Task.checkCancellation()
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if !Task.isCancelled { connection.cancel() }
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}

private final class StreamResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resumeOnce(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        action()
    }
}
