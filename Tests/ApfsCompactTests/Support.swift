import ApfsCompactCore
import CApfs
import CryptoKit
import Darwin
import Foundation
import XCTest

// MARK: - Scratch APFS volume

/// A sparse APFS disk image mounted privately for the duration of a test.
/// Its free space is not shared with anything else, so space measurements on
/// it are exact.
final class TestVolume {
    let image: String
    let mount: String

    init(sizeGB: Int, name: String) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("apfs-compact-tests-\(getpid())-\(name)")
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        image = base.appendingPathComponent("vol.sparseimage").path
        mount = base.appendingPathComponent("mnt").path
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        try shell("/usr/bin/hdiutil", ["create", "-quiet", "-size", "\(sizeGB)g", "-type", "SPARSE", "-fs", "APFS",
                                      "-volname", "acmp-\(name)", image])
        try shell("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noverify", "-noautoopen", "-owners", "on",
                                      "-mountpoint", mount, image])
    }

    func destroy() {
        _ = try? shell("/usr/bin/chflags", ["-R", "nouchg,noschg", mount])
        _ = try? shell("/usr/bin/hdiutil", ["detach", "-force", "-quiet", mount])
        try? FileManager.default.removeItem(atPath: (image as NSString).deletingLastPathComponent)
    }
}

@discardableResult
func shell(_ exe: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    if p.terminationStatus != 0 {
        throw CompactError("\(exe) \(args.joined(separator: " ")) failed (\(p.terminationStatus)): \(text)")
    }
    return text
}

// MARK: - Randomness

/// Seeded generator for the *structure* of a test (sizes, offsets, metadata).
/// File contents come from arc4random_buf for speed.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - File creation (never via cp, which clones on APFS)

let ioSize = 8 << 20

func writeRandomFile(_ path: String, size: Int64) throws {
    let fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0o644)
    guard fd >= 0 else { throw CompactError("create \(path): \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: ioSize, alignment: 16384)
    defer { buf.deallocate() }
    var off: Int64 = 0
    while off < size {
        let n = Int(min(Int64(ioSize), size - off))
        arc4random_buf(buf, n)
        guard pwrite(fd, buf, n, off_t(off)) == n else { throw CompactError("write \(path)") }
        off += Int64(n)
    }
}

/// Byte copy into a brand-new file with its own blocks.
func copyNoClone(_ src: String, _ dst: String) throws {
    let s = open(src, O_RDONLY)
    let d = open(dst, O_CREAT | O_TRUNC | O_WRONLY, 0o644)
    guard s >= 0, d >= 0 else { throw CompactError("copy \(src) -> \(dst)") }
    defer { close(s); close(d) }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: ioSize, alignment: 16384)
    defer { buf.deallocate() }
    var off: off_t = 0
    while true {
        let n = pread(s, buf, ioSize, off)
        if n <= 0 { break }
        guard pwrite(d, buf, n, off) == n else { throw CompactError("write \(dst)") }
        off += off_t(n)
    }
}

struct Edit: CustomStringConvertible {
    var offset: Int64
    var length: Int
    var description: String { "\(length)B@\(offset)" }
}

/// Overwrites random, deliberately unaligned byte ranges with random data
/// until roughly `fraction` of the file has changed.
func scatterEdits(_ path: String, size: Int64, fraction: Double, maxEdits: Int, rng: inout SeededRNG) throws -> [Edit] {
    let fd = open(path, O_WRONLY)
    guard fd >= 0 else { throw CompactError("open \(path)") }
    defer { close(fd) }
    let budget = max(1, Int64(Double(size) * fraction))
    let count = Int.random(in: 1...maxEdits, using: &rng)
    var edits: [Edit] = []
    for _ in 0..<count {
        var len = Int(max(1, budget / Int64(count)))
        len = Int.random(in: max(1, len / 2)...max(1, len), using: &rng)
        var off = Int64.random(in: 0..<max(1, size - Int64(len)), using: &rng)
        if off % 4096 == 0 { off += 1 }  // make sure it isn't block aligned
        len = Int(min(Int64(len), size - off))
        let buf = UnsafeMutableRawPointer.allocate(byteCount: len, alignment: 16)
        arc4random_buf(buf, len)
        let n = pwrite(fd, buf, len, off_t(off))
        buf.deallocate()
        guard n == len else { throw CompactError("edit \(path)") }
        edits.append(Edit(offset: off, length: len))
    }
    return edits
}

func truncateFile(_ path: String, to size: Int64) throws {
    guard truncate(path, off_t(size)) == 0 else { throw CompactError("truncate \(path)") }
}

func appendRandom(_ path: String, bytes: Int) throws {
    let fd = open(path, O_WRONLY | O_APPEND)
    guard fd >= 0 else { throw CompactError("open \(path)") }
    defer { close(fd) }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
    defer { buf.deallocate() }
    arc4random_buf(buf, bytes)
    guard write(fd, buf, bytes) == bytes else { throw CompactError("append \(path)") }
}

// MARK: - Metadata decoration

/// Gives a file a random but realistic set of macOS metadata: mode, extended
/// attributes (resource fork, Finder info, tags, quarantine, custom), ACLs,
/// BSD flags and all five settable timestamps.
func decorate(_ path: String, rng: inout SeededRNG, allowImmutable: Bool = true) throws {
    func setX(_ name: String, _ data: Data) throws {
        let r = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        guard r == 0 else { throw CompactError("setxattr \(name) \(path): \(String(cString: strerror(errno)))") }
    }
    func randomData(_ n: Int, _ rng: inout SeededRNG) -> Data {
        Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    try setX("com.example.apfs-compact.note", Data("note-\(rng.next())".utf8))
    if Bool.random(using: &rng) {
        try setX("com.apple.ResourceFork", randomData(Int.random(in: 1...65536, using: &rng), &rng))
    }
    if Bool.random(using: &rng) {
        var fi = [UInt8](repeating: 0, count: 32)
        fi[0...3] = [0x54, 0x45, 0x58, 0x54]  // type 'TEXT'
        fi[4...7] = [0x74, 0x74, 0x78, 0x74]  // creator 'ttxt'
        fi[9] = UInt8.random(in: 1...7, using: &rng) << 1  // color label
        try setX("com.apple.FinderInfo", Data(fi))
    }
    if Bool.random(using: &rng) {
        let tags = ["Red\n6", "Project-\(rng.next() % 100)"]
        let plist = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        try setX("com.apple.metadata:_kMDItemUserTags", plist)
    }
    if Int.random(in: 0..<4, using: &rng) == 0 {
        try setX("com.apple.quarantine", Data("0083;5f5e1000;Safari;\(UUID().uuidString)".utf8))
    }

    let modes: [mode_t] = [0o644, 0o600, 0o640, 0o444, 0o755]
    guard chmod(path, modes.randomElement(using: &rng)!) == 0 else { throw CompactError("chmod \(path)") }

    // Times. atime is sometimes older than mtime, which makes plain reads update it.
    let crtime = Int.random(in: 1_104_537_600...1_420_070_400, using: &rng)  // 2005-2015
    let mtime = Int.random(in: crtime...1_600_000_000, using: &rng)
    let atime = Bool.random(using: &rng) ? Int.random(in: crtime..<mtime + 1, using: &rng)
                                         : Int.random(in: mtime...1_700_000_000, using: &rng)
    var ts = [crtime, mtime, atime, Int.random(in: 0...1_700_000_000, using: &rng),
              Int.random(in: crtime...1_700_000_000, using: &rng)].map {
        timespec(tv_sec: $0, tv_nsec: Int.random(in: 0..<1_000_000_000, using: &rng))
    }
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { throw CompactError("open \(path)") }
    defer { close(fd) }
    guard capfs_fset_times(fd, &ts[0], &ts[1], &ts[2], &ts[3], &ts[4]) == 0 else {
        throw CompactError("set times \(path): \(String(cString: strerror(errno)))")
    }

    switch Int.random(in: 0..<4, using: &rng) {
    case 0: try shell("/bin/chmod", ["+a", "everyone deny delete", path])
    case 1: try shell("/bin/chmod", ["+a", "user:\(NSUserName()) allow read,write,append,readattr,readextattr", path])
    default: break
    }

    var flags: UInt32 = 0
    if Int.random(in: 0..<4, using: &rng) == 0 { flags |= UInt32(UF_HIDDEN) }
    if allowImmutable && Int.random(in: 0..<6, using: &rng) == 0 { flags |= UInt32(UF_IMMUTABLE) }
    if flags != 0 { guard fchflags(fd, flags) == 0 else { throw CompactError("chflags \(path)") } }
}

// MARK: - Verification helpers

func md5(_ path: String) throws -> String {
    try AtimeGuard.reading(path) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw CompactError("open \(path)") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var h = Insecure.MD5()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: ioSize, alignment: 16384)
        defer { buf.deallocate() }
        while true {
            let n = read(fd, buf, ioSize)
            if n <= 0 { break }
            h.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Independent re-implementation of "how many chunks of target differ from
/// base at the same offset" used to cross-check the planner.
func countDifferingChunks(base: String, target: String, chunk: Int) throws -> Int {
    try AtimeGuard.reading(base) {
        try AtimeGuard.reading(target) {
            let a = FileHandle(forReadingAtPath: base)!, b = FileHandle(forReadingAtPath: target)!
            defer { try? a.close(); try? b.close() }
            var count = 0
            while true {
                let db = b.readData(ofLength: chunk)
                if db.isEmpty { break }
                let da = a.readData(ofLength: chunk)
                // A chunk counts as different if its bytes differ, or if it is a
                // partial tail chunk whose length differs (truncating a shared
                // block rewrites it too).
                if da != db { count += 1 }
            }
            return count
        }
    }
}

struct FileState {
    var meta: MetadataSnapshot
    var md5: String
    var ino: UInt64
}

/// Metadata first (before reading moves atime), then content hash.
func captureState(_ path: String) throws -> FileState {
    let meta = try MetadataSnapshot.capture(path)
    return FileState(meta: meta, md5: try md5(path), ino: meta.ino)
}

func allFiles(under root: String) -> [String] {
    var out: [String] = []
    let e = FileManager.default.enumerator(atPath: root)!
    while let rel = e.nextObject() as? String {
        let p = (root as NSString).appendingPathComponent(rel)
        var st = stat()
        if lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG { out.append(p) }
    }
    return out.sorted()
}

func settledAvailable(_ mount: String) -> Int64 {
    sync()
    var last = availableBytes(mount)
    for _ in 0..<40 {
        usleep(250_000)
        sync()
        let now = availableBytes(mount)
        if now == last { return now }
        last = now
    }
    return last
}

func log(_ s: String) {
    FileHandle.standardError.write(("[apfs-compact-test] " + s + "\n").data(using: .utf8)!)
}
