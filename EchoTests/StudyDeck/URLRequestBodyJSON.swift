// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension URLRequest {
    /// The URLProtocol-visible request body decoded as JSON. URLSession moves
    /// `httpBody` into `httpBodyStream` before `URLProtocol` receives the request.
    nonisolated var stubBodyJSON: [String: Any]? {
        var data = httpBody
        if data == nil, let stream = httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        return data.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
    }
}
