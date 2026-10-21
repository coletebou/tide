import CryptoKit
import Foundation

/// File metadata from `lstat`, with the fields the index records.
struct GitFileStat: Equatable {
    var mode: mode_t
    var size: Int64
    var modificationTime: GitIndexTime
    var statusChangeTime: GitIndexTime
    var inode: UInt64
    var userID: UInt32
    var groupID: UInt32

    var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    var isSymlink: Bool { mode & S_IFMT == S_IFLNK }

    /// `lstat` of `path`, or nil when nothing exists there.
    static func read(_ path: String) -> GitFileStat? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return GitFileStat(
            mode: info.st_mode,
            size: Int64(info.st_size),
            modificationTime: GitIndexTime(
                seconds: UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec),
                nanoseconds: UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec)
            ),
            statusChangeTime: GitIndexTime(
                seconds: UInt32(truncatingIfNeeded: info.st_ctimespec.tv_sec),
                nanoseconds: UInt32(truncatingIfNeeded: info.st_ctimespec.tv_nsec)
            ),
            inode: UInt64(info.st_ino),
            userID: info.st_uid,
            groupID: info.st_gid
        )
    }
}

/// Directory listing and hashing for the work tree.
enum GitWorkTreeIO {
    enum Kind {
        case file, directory, symlink, other
    }

    struct DirectoryEntry {
        var name: [UInt8]
        var kind: Kind
    }

    /// The entries of a directory other than `.` and `..`, or nil when it cannot be read.
    static func readDirectory(_ path: String) -> [DirectoryEntry]? {
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }
        var entries: [DirectoryEntry] = []
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let name: [UInt8] = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(length)) }
            if name == [UInt8(ascii: ".")] || name == [UInt8(ascii: "."), UInt8(ascii: ".")] { continue }
            let kind: Kind
            switch Int32(entry.pointee.d_type) {
            case DT_REG: kind = .file
            case DT_DIR: kind = .directory
            case DT_LNK: kind = .symlink
            case DT_UNKNOWN:
                let childPath = path + "/" + String(decoding: name, as: UTF8.self)
                if let info = GitFileStat.read(childPath) {
                    kind = info.isDirectory ? .directory : info.isSymlink ? .symlink : info.isRegularFile ? .file : .other
                } else {
                    continue
                }
            default: kind = .other
            }
            entries.append(DirectoryEntry(name: name, kind: kind))
        }
        return entries
    }

    /// The blob id of a regular file's content, streamed in chunks. Returns
    /// nil when the file vanished or changed size while it was read.
    static func hashFile(atPath path: String) -> GitObjectID? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        let size = Int(info.st_size)
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        let chunkSize = min(max(size, 1), 1 << 20)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var total = 0
        while true {
            let count = read(descriptor, buffer.baseAddress!, chunkSize)
            if count < 0, errno == EINTR { continue }
            if count < 0 { return nil }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            total += count
            if total > size { return nil }
        }
        guard total == size else { return nil }
        return GitObjectID(digest: hasher.finalize())
    }

    /// The blob id git computes for a regular file whose content it converts
    /// first, such as CRLF to LF for a `text` file. Reads the whole file, as git does.
    static func hashFile(atPath path: String, converting conversion: GitTextConversion, blob: (GitObjectID) -> Data?) -> GitObjectID? {
        guard conversion != .none else { return hashFile(atPath: path) }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        var data = Data(count: Int(info.st_size))
        let complete: Bool = data.withUnsafeMutableBytes { buffer in
            var total = 0
            while total < buffer.count {
                let count = read(descriptor, buffer.baseAddress! + total, buffer.count - total)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return false }
                total += count
            }
            return true
        }
        guard complete else { return nil }
        return GitObjectID.hash(.blob, conversion.normalized(data, blob: blob))
    }

    /// The target of a symbolic link, which git stores as the link's blob.
    static func symlinkTarget(atPath path: String) -> Data? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            pointer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pointer.count) {
                readlink(path, $0, pointer.count - 1)
            }
        }
        guard length >= 0 else { return nil }
        return Data(buffer[0..<length])
    }

    /// The blob id of a symbolic link: the hash of its target text.
    static func hashSymlink(atPath path: String) -> GitObjectID? {
        symlinkTarget(atPath: path).map { GitObjectID.hash(.blob, $0) }
    }
}
