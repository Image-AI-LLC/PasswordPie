import Foundation
import zlib

enum GzipError: Error {
    case failed(Int32)
}

func gzipCompress(_ source: Data) throws -> Data {
    var stream = z_stream()
    let status = deflateInit2_(
        &stream,
        Z_DEFAULT_COMPRESSION,
        Z_DEFLATED,
        MAX_WBITS + 16,
        8,
        Z_DEFAULT_STRATEGY,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard status == Z_OK else { throw GzipError.failed(status) }
    defer { deflateEnd(&stream) }
    return try transform(source, stream: &stream, finish: true, inflate: false)
}

func rawInflate(_ source: Data) throws -> Data {
    var stream = z_stream()
    let status = inflateInit2_(
        &stream,
        -MAX_WBITS,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard status == Z_OK else { throw GzipError.failed(status) }
    defer { inflateEnd(&stream) }
    return try transform(source, stream: &stream, finish: true, inflate: true)
}

func gzipDecompress(_ source: Data) throws -> Data {
    var stream = z_stream()
    let status = inflateInit2_(
        &stream,
        MAX_WBITS + 16,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard status == Z_OK else { throw GzipError.failed(status) }
    defer { inflateEnd(&stream) }
    return try transform(source, stream: &stream, finish: true, inflate: true)
}

private func transform(_ source: Data, stream: inout z_stream, finish: Bool, inflate: Bool) throws -> Data {
    var output = Data()
    let chunk = 65536
    if source.isEmpty {
        return output
    }
    try source.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return }
        stream.next_in = UnsafeMutablePointer(mutating: base)
        stream.avail_in = uInt(source.count)
        while true {
            var buffer = [UInt8](repeating: 0, count: chunk)
            let code: Int32 = buffer.withUnsafeMutableBytes { outRaw in
                stream.next_out = outRaw.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(chunk)
                let flush: Int32 = finish ? Z_FINISH : Z_NO_FLUSH
                if inflate {
                    return zlib.inflate(&stream, flush)
                }
                return deflate(&stream, flush)
            }
            let produced = chunk - Int(stream.avail_out)
            if produced > 0 {
                output.append(buffer, count: produced)
            }
            if code == Z_STREAM_END {
                break
            }
            // A full output buffer is not fatal. Z_FINISH reports it as Z_BUF_ERROR.
            if code == Z_OK || (code == Z_BUF_ERROR && produced > 0) {
                continue
            }
            throw GzipError.failed(code)
        }
    }
    return output
}
