import Compression
import Foundation

/// Decompresses zlib streams (RFC 1950), the format of loose objects and pack entries.
///
/// Apple's Compression framework names its decoder `COMPRESSION_ZLIB`, but it
/// reads raw DEFLATE (RFC 1951) without the zlib wrapper. So this validates and
/// skips the two-byte zlib header itself and leaves the Adler-32 trailer
/// unread; object ids already protect the content.
enum Inflate {
    /// DEFLATE cannot expand data by more than about 1032:1.
    private static let maximumRatio = 1032

    /// Inflates the zlib stream at the start of `input`, which may continue past
    /// the end of the stream. When `expectedSize` is given, the output must have
    /// exactly that many bytes.
    static func zlib(_ input: UnsafeRawBufferPointer, expectedSize: Int? = nil) throws -> Data {
        guard input.count >= 2, let base = input.baseAddress else {
            throw GitError.corrupt("truncated zlib stream")
        }
        let method = input[0]
        let flags = input[1]
        guard method & 0x0F == 8, method >> 4 <= 7, (UInt16(method) << 8 | UInt16(flags)) % 31 == 0 else {
            throw GitError.corrupt("bad zlib header")
        }
        guard flags & 0x20 == 0 else { throw GitError.unsupported("zlib preset dictionary") }

        let deflate = UnsafeRawBufferPointer(start: base + 2, count: input.count - 2)
        if let expectedSize {
            let limit = deflate.count.multipliedReportingOverflow(by: maximumRatio)
            guard expectedSize >= 0, limit.overflow || expectedSize <= limit.partialValue + 64 else {
                throw GitError.corrupt("object size \(expectedSize) exceeds its compressed data")
            }
        }
        return try rawDeflate(deflate, expectedSize: expectedSize)
    }

    private static func rawDeflate(_ input: UnsafeRawBufferPointer, expectedSize: Int?) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GitError.io("cannot start zlib decoder")
        }
        defer { compression_stream_destroy(stream) }

        guard let source = input.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw GitError.corrupt("empty deflate stream")
        }
        stream.pointee.src_ptr = source
        stream.pointee.src_size = input.count

        // One spare byte lets the decoder reach the end-of-stream marker
        // without stalling on a full output buffer.
        var output = Data(count: (expectedSize ?? max(256, input.count * 3)) + 1)
        var produced = 0
        let finalize = Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue)
        while true {
            if produced == output.count {
                if let expectedSize, produced > expectedSize {
                    throw GitError.corrupt("object is larger than its header says")
                }
                output.count += max(output.count, 4096)
            }
            let sourceBefore = stream.pointee.src_size
            let producedBefore = produced
            let status: compression_status = output.withUnsafeMutableBytes { buffer in
                let destination = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.pointee.dst_ptr = destination + produced
                stream.pointee.dst_size = buffer.count - produced
                let status = compression_stream_process(stream, finalize)
                produced = buffer.count - stream.pointee.dst_size
                return status
            }
            switch status {
            case COMPRESSION_STATUS_END:
                if let expectedSize, produced != expectedSize {
                    throw GitError.corrupt("inflated \(produced) bytes, expected \(expectedSize)")
                }
                output.count = produced
                return output
            case COMPRESSION_STATUS_OK:
                // No progress with room to spare means the input ran out.
                if produced < output.count, produced == producedBefore, stream.pointee.src_size == sourceBefore {
                    throw GitError.corrupt("truncated deflate stream")
                }
            default:
                throw GitError.corrupt("invalid deflate data")
            }
        }
    }
}
