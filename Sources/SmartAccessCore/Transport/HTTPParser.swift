import Foundation

/// 极简 HTTP/1.1 响应解析。
///
/// 支持：
/// - status line + headers
/// - Content-Length 计长 body
/// - Transfer-Encoding: chunked
///
/// 不支持（V2 不做）：
/// - HTTP/2 / HTTP/3
/// - Trailers
/// - 多 Content-Encoding 压缩（gzip 由调用者按 header 自行解压）
/// - HTTP/1.0 keep-alive 协商（默认每个请求新连接）
///
/// 注：这是为"Relay IP 直连"专门写的最小可用 client，
/// 业务源站请求**不会**走这里——业务流量走 URLSession + 域名访问，
/// 这里只在 Relay endpoint 的 DNS 失败且 directIPMode 启用时启用。
enum HTTPParser {

    struct ParsedResponse {
        let statusCode: Int
        let reasonPhrase: String
        let headers: [(String, String)]
        let body: Data

        var contentTypeIsJSON: Bool {
            headers.contains { $0.0.lowercased() == "content-type" && $0.1.lowercased().contains("json") }
        }
    }

    enum ParseError: Error, Equatable {
        case malformedStatusLine
        case malformedHeader
        case incompleteHeaders
        case incompleteBody
        case chunkedDecodeFailed(String)
        case unexpectedTransferEncoding(String)
        case bodyTooLarge(Int)
    }

    /// 输入是一段已经从连接读出来的字节，解析出完整 response。
    /// `maxBodyBytes` 是安全上限，避免 Relay 返回畸形内容导致 OOM。
    static func parse(_ data: Data, maxBodyBytes: Int = 4 * 1024 * 1024) throws -> ParsedResponse {
        // 1. 找 header / body 分界
        guard let headerEnd = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            throw ParseError.incompleteHeaders
        }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        let bodyBytes = data.subdata(in: headerEnd.upperBound..<data.endIndex)

        // 2. 解析 status line + headers
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw ParseError.malformedStatusLine
        }
        // 注意：HTTP 头行分隔是 CRLF，但有些坏 server 用 LF。统一规整。
        let lines = headerString.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else { throw ParseError.malformedStatusLine }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count >= 2,
              statusParts[0].hasPrefix("HTTP/1."),
              let code = Int(statusParts[1]) else {
            throw ParseError.malformedStatusLine
        }
        let reason = statusParts.count >= 3 ? String(statusParts[2]) : ""

        var headers: [(String, String)] = []
        for raw in lines.dropFirst() {
            if raw.isEmpty { continue }
            guard let colon = raw.firstIndex(of: ":") else { throw ParseError.malformedHeader }
            let name = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        // 3. 解析 body
        let transferEncoding = headers.first { $0.0.lowercased() == "transfer-encoding" }?.1.lowercased()
        let contentLength    = headers.first { $0.0.lowercased() == "content-length" }?.1
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        let body: Data
        if let te = transferEncoding {
            if te.contains("chunked") {
                body = try decodeChunked(bodyBytes, maxBodyBytes: maxBodyBytes)
            } else {
                throw ParseError.unexpectedTransferEncoding(te)
            }
        } else if let len = contentLength {
            if len > maxBodyBytes { throw ParseError.bodyTooLarge(len) }
            if bodyBytes.count < len { throw ParseError.incompleteBody }
            body = bodyBytes.prefix(len)
        } else {
            // 没声明长度也没 chunked，假定整个剩余字节为 body（HTTP/1.0 风格）。
            if bodyBytes.count > maxBodyBytes { throw ParseError.bodyTooLarge(bodyBytes.count) }
            body = bodyBytes
        }

        return ParsedResponse(statusCode: code, reasonPhrase: reason, headers: headers, body: body)
    }

    private static func decodeChunked(_ data: Data, maxBodyBytes: Int) throws -> Data {
        var out = Data()
        var idx = data.startIndex
        while idx < data.endIndex {
            // 读 chunk size line
            guard let lineEnd = data.range(of: Data([0x0D, 0x0A]), in: idx..<data.endIndex) else {
                throw ParseError.chunkedDecodeFailed("no_size_line")
            }
            let sizeLineData = data.subdata(in: idx..<lineEnd.lowerBound)
            guard let sizeStr = String(data: sizeLineData, encoding: .utf8) else {
                throw ParseError.chunkedDecodeFailed("size_line_not_utf8")
            }
            // 忽略扩展（;...）
            let sizeHex = sizeStr.split(separator: ";").first.map(String.init) ?? sizeStr
            guard let size = Int(sizeHex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw ParseError.chunkedDecodeFailed("size_not_hex: \(sizeHex)")
            }
            if size == 0 {
                break // 终止块
            }
            let chunkStart = lineEnd.upperBound
            let chunkEnd = chunkStart + size
            guard chunkEnd <= data.endIndex else {
                throw ParseError.chunkedDecodeFailed("chunk_truncated")
            }
            if out.count + size > maxBodyBytes {
                throw ParseError.bodyTooLarge(out.count + size)
            }
            out.append(data.subdata(in: chunkStart..<chunkEnd))
            // 跳过 chunk 末尾 CRLF
            idx = chunkEnd
            if idx + 2 <= data.endIndex,
               data[idx] == 0x0D, data[idx + 1] == 0x0A {
                idx += 2
            }
        }
        return out
    }
}

extension Data {
    func range(of subdata: Data, in range: Range<Int>) -> Range<Int>? {
        guard !subdata.isEmpty, range.lowerBound >= 0, range.upperBound <= count else { return nil }
        let target = Array(subdata)
        let bytes = Array(self)
        let n = bytes.count
        let m = target.count
        guard m > 0, m <= n else { return nil }
        var i = range.lowerBound
        let limit = min(range.upperBound, n) - m
        while i <= limit {
            if bytes[i..<(i + m)] == ArraySlice(target) {
                return i..<(i + m)
            }
            i += 1
        }
        return nil
    }
}
