import CApfs
import Darwin
import Foundation

public struct SkippedFile: Codable {
    public var path: String
    public var reason: String
}

let tempMarker = ".apfs-compact-"

struct ScanResult {
    var files: [FileEntry] = []
    var skipped: [SkippedFile] = []
    var errors: [SkippedFile] = []
}

/// Walks the roots without following symlinks and returns regular files of at
/// least `minSize` bytes. Hard-linked paths to the same inode appear once.
func scanDirectories(_ roots: [String], minSize: Int64, excludes: [String]) -> ScanResult {
    var result = ScanResult()
    var seen = Set<[UInt64]>()

    var cPaths: [UnsafeMutablePointer<CChar>?] = roots.map { strdup($0) } + [nil]
    defer { cPaths.forEach { free($0) } }
    guard let fts = fts_open(&cPaths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
        result.errors.append(SkippedFile(path: roots.joined(separator: ", "), reason: "cannot walk: \(errnoString())"))
        return result
    }
    defer { fts_close(fts) }

    func excluded(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return excludes.contains { fnmatch($0, name, 0) == 0 || fnmatch($0, path, 0) == 0 }
    }

    while let ent = fts_read(fts) {
        let path = String(cString: ent.pointee.fts_path)
        switch Int32(ent.pointee.fts_info) {
        case FTS_D:
            if ent.pointee.fts_level > 0, excluded(path) { fts_set(fts, ent, FTS_SKIP) }
        case FTS_F:
            if excluded(path) || path.contains(tempMarker) { continue }
            let st = ent.pointee.fts_statp.pointee
            if st.st_size < minSize { continue }
            guard let e = FileEntry.load(path) else {
                result.errors.append(SkippedFile(path: path, reason: "stat failed: \(errnoString())"))
                continue
            }
            let key = [UInt64(UInt32(bitPattern: e.dev)), e.ino]
            if !seen.insert(key).inserted { continue }
            result.files.append(e)
        case FTS_DNR, FTS_ERR, FTS_NS:
            result.errors.append(SkippedFile(path: path, reason: String(cString: strerror(ent.pointee.fts_errno))))
        default:
            break
        }
    }
    return result
}

// MARK: - Hashing

enum ChunkHasher {
    static let readSize = 8 << 20

    static func chunkHash(_ p: UnsafeRawPointer, _ len: Int) -> UInt64 {
        capfs_hash64(p, len, UInt64(len))
    }

    /// Hash of every `chunk`-sized piece of the file.
    static func chunkHashes(path: String, size: Int64, chunk: Int) throws -> [UInt64] {
        try AtimeGuard.reading(path) {
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw posixFailure("open", path) }
            defer { close(fd) }
            _ = fcntl(fd, F_NOCACHE, 1)
            let bufSize = max(chunk, readSize / chunk * chunk)
            let buf = AlignedBuffer(size: bufSize)
            var hashes: [UInt64] = []
            hashes.reserveCapacity(Int((size + Int64(chunk) - 1) / Int64(chunk)))
            var off: Int64 = 0
            while off < size {
                let want = Int(min(Int64(bufSize), size - off))
                let n = try readFully(fd, buf.ptr, want, off, path: path)
                if n < want { throw CompactError("\(path) shrank while reading") }
                var c = 0
                while c < n {
                    let l = min(chunk, n - c)
                    hashes.append(chunkHash(buf.ptr + c, l))
                    c += l
                }
                off += Int64(n)
            }
            return hashes
        }
    }

    /// Hashes of chunk indices 0, stride, 2*stride, ... (reads only those chunks).
    static func sampleHashes(path: String, size: Int64, chunk: Int, stride: Int) throws -> [UInt64] {
        try AtimeGuard.reading(path) {
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw posixFailure("open", path) }
            defer { close(fd) }
            _ = fcntl(fd, F_NOCACHE, 1)
            let buf = AlignedBuffer(size: chunk)
            var out: [UInt64] = []
            var idx: Int64 = 0
            while idx * Int64(chunk) < size {
                let off = idx * Int64(chunk)
                let want = Int(min(Int64(chunk), size - off))
                let n = try readFully(fd, buf.ptr, want, off, path: path)
                out.append(chunkHash(buf.ptr, n))
                idx += Int64(stride)
            }
            return out
        }
    }

    /// Cheap pre-filter for same-size files: first and last chunk.
    static func headTailHash(path: String, size: Int64, chunk: Int) throws -> UInt64 {
        try AtimeGuard.reading(path) {
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw posixFailure("open", path) }
            defer { close(fd) }
            let buf = AlignedBuffer(size: chunk)
            let n1 = try readFully(fd, buf.ptr, Int(min(Int64(chunk), size)), 0, path: path)
            var h = chunkHash(buf.ptr, n1)
            if size > Int64(chunk) {
                let n2 = try readFully(fd, buf.ptr, chunk, size - Int64(chunk), path: path)
                h ^= chunkHash(buf.ptr, n2) &* 0x9E37_79B9_7F4A_7C15
            }
            return h
        }
    }

    static func combine(_ hashes: [UInt64], size: Int64) -> UInt64 {
        hashes.withUnsafeBytes { capfs_hash64($0.baseAddress, $0.count, UInt64(bitPattern: size)) }
    }
}
