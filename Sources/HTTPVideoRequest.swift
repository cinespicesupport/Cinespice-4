import Foundation

/// Pure HTTP framing for the loopback bridge. No Telegram or player state.
struct HTTPVideoResponse {
    let status: String
    let start: Int64
    let length: Int64
    let sendsBody: Bool
    let headers: Data

    static func make(request: String, path: String, size: Int64, mimeType: String) -> HTTPVideoResponse {
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        let isHead = first.first == "HEAD"
        func response(_ status: String, start: Int64 = 0, length: Int64 = 0, extra: String = "") -> HTTPVideoResponse {
            let safeType = mimeType.contains("\r") || mimeType.contains("\n") ? "application/octet-stream" : mimeType
            let text = "HTTP/1.1 \(status)\r\nContent-Type: \(safeType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(length)\r\nConnection: close\r\n\(extra)\r\n"
            return HTTPVideoResponse(status: status, start: start, length: length,
                                     sendsBody: !isHead && status.hasPrefix("20") && length > 0,
                                     headers: Data(text.utf8))
        }
        guard first.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(first[2])), size >= 0 else {
            return response("400 Bad Request")
        }
        guard first[1] == path else { return response("404 Not Found") }
        guard first[0] == "GET" || isHead else { return response("405 Method Not Allowed", extra: "Allow: GET, HEAD\r\n") }
        var ranges: [String] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return response("400 Bad Request") }
            if pair[0].lowercased() == "range" { ranges.append(pair[1].trimmingCharacters(in: .whitespaces)) }
        }
        // HEAD describes the full representation; Range only applies to GET.
        if isHead || ranges.isEmpty { return response("200 OK", length: size) }
        guard ranges.count == 1, ranges[0].hasPrefix("bytes="), !ranges[0].contains(",") else {
            return response("400 Bad Request")
        }
        let parts = ranges[0].dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        func decimal(_ value: Substring) -> Int64? {
            guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            return Int64(value)
        }
        func unsatisfiable() -> HTTPVideoResponse {
            response("416 Range Not Satisfiable", extra: "Content-Range: bytes */\(size)\r\n")
        }
        guard parts.count == 2 else { return response("400 Bad Request") }
        let lower: Int64
        let upper: Int64
        if parts[0].isEmpty {
            guard let suffix = decimal(parts[1]) else { return response("400 Bad Request") }
            guard suffix > 0, size > 0 else { return unsatisfiable() }
            lower = max(0, size - suffix)
            upper = size - 1
        } else {
            guard let start = decimal(parts[0]) else { return response("400 Bad Request") }
            let end: Int64
            if parts[1].isEmpty { end = size - 1 }
            else {
                guard let value = decimal(parts[1]) else { return response("400 Bad Request") }
                end = value
            }
            guard start < size, end >= start else { return unsatisfiable() }
            lower = start
            upper = min(end, size - 1)
        }
        return response("206 Partial Content", start: lower, length: upper - lower + 1,
                        extra: "Content-Range: bytes \(lower)-\(upper)/\(size)\r\n")
    }
}
