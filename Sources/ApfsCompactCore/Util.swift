import CApfs
import Darwin
import Foundation

public struct CompactError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

func errnoString(_ e: Int32 = errno) -> String { String(cString: strerror(e)) }

func posixFailure(_ what: String, _ path: String, _ e: Int32 = errno) -> CompactError {
    CompactError("\(what) \(path): \(errnoString(e))")
}

// MARK: - Timestamps

public struct TS: Codable, Hashable, Comparable, CustomStringConvertible {
    public var sec: Int
    public var nsec: Int

    public init(sec: Int, nsec: Int) {
        self.sec = sec
        self.nsec = nsec
    }

    public init(_ t: timespec) {
        sec = t.tv_sec
        nsec = t.tv_nsec
    }

    public var timespec: Darwin.timespec { Darwin.timespec(tv_sec: sec, tv_nsec: nsec) }

    public static func < (a: TS, b: TS) -> Bool { (a.sec, a.nsec) < (b.sec, b.nsec) }

    public var description: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let base = f.string(from: Date(timeIntervalSince1970: TimeInterval(sec)))
        return nsec == 0 ? base : "\(base) +\(nsec)ns"
    }
}

// MARK: - Sizes

public func formatBytes(_ n: Int64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    var v = Double(n.magnitude)
    var i = 0
    while v >= 1024 && i < units.count - 1 {
        v /= 1024
        i += 1
    }
    let sign = n < 0 ? "-" : ""
    return i == 0 ? "\(sign)\(n.magnitude) B" : String(format: "%@%.2f %@", sign, v, units[i])
}

/// Parses sizes like "100MB", "1g", "16k", "4096". Units are binary (1 KB = 1024 bytes).
public func parseSize(_ text: String) -> Int64? {
    let s = text.trimmingCharacters(in: .whitespaces).lowercased()
    var numEnd = s.startIndex
    while numEnd < s.endIndex, s[numEnd].isNumber || s[numEnd] == "." { numEnd = s.index(after: numEnd) }
    guard let value = Double(s[s.startIndex..<numEnd]) else { return nil }
    let k = 1024.0
    let multipliers: [String: Double] = [
        "": 1, "b": 1,
        "k": k, "kb": k, "kib": k,
        "m": k * k, "mb": k * k, "mib": k * k,
        "g": k * k * k, "gb": k * k * k, "gib": k * k * k,
        "t": k * k * k * k, "tb": k * k * k * k, "tib": k * k * k * k,
    ]
    guard let m = multipliers[String(s[numEnd...])] else { return nil }
    return Int64(value * m)
}

// MARK: - I/O helpers

final class AlignedBuffer {
    let ptr: UnsafeMutableRawPointer
    let size: Int

    init(size: Int, alignment: Int = 16384) {
        var p: UnsafeMutableRawPointer?
        precondition(posix_memalign(&p, alignment, max(size, 1)) == 0, "out of memory")
        ptr = p!
        self.size = size
    }

    deinit { free(ptr) }
}

/// pread until `count` bytes or EOF. Returns the number of bytes read.
func readFully(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int, _ offset: Int64, path: String) throws -> Int {
    var done = 0
    while done < count {
        let n = pread(fd, buf + done, count - done, off_t(offset) + off_t(done))
        if n < 0 {
            if errno == EINTR { continue }
            throw posixFailure("read", path)
        }
        if n == 0 { break }
        done += n
    }
    return done
}

func writeFully(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int, _ offset: Int64, path: String) throws {
    var done = 0
    while done < count {
        let n = pwrite(fd, buf + done, count - done, off_t(offset) + off_t(done))
        if n < 0 {
            if errno == EINTR { continue }
            throw posixFailure("write", path)
        }
        done += n
    }
}

/// Reads normally update atime on APFS when atime is older than mtime. The
/// tool turns that off for its own process (IOPOL_TYPE_VFS_ATIME_UPDATES), so
/// scanning, even a dry run, changes neither atime nor ctime. If the policy
/// can't be set, the old atime is put back after each read instead, which
/// bumps ctime (and needs the immutable flag lifted on locked files).
public final class AtimeGuard {
    public static var enabled = true
    private static let lock = NSLock()
    private static var _restored = 0
    public static var restoredCount: Int { lock.lock(); defer { lock.unlock() }; return _restored }

    /// True when the kernel won't update atime for our reads at all.
    public static let policyActive: Bool = {
        setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_PROCESS, IOPOL_ATIME_UPDATES_OFF) == 0
    }()

    public static func reading<T>(_ path: String, _ body: () throws -> T) rethrows -> T {
        guard enabled, !policyActive else { return try body() }
        var before = stat()
        let had = lstat(path, &before) == 0
        defer {
            var after = stat()
            if had, lstat(path, &after) == 0,
               after.st_atimespec.tv_sec != before.st_atimespec.tv_sec
               || after.st_atimespec.tv_nsec != before.st_atimespec.tv_nsec {
                var a = before.st_atimespec
                let locked = before.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND)
                if locked != 0 { _ = lchflags(path, before.st_flags & ~locked) }
                if capfs_set_atime(path, &a) == 0 {
                    lock.lock(); _restored += 1; lock.unlock()
                }
                if locked != 0 { _ = lchflags(path, before.st_flags) }
            }
        }
        return try body()
    }
}

// MARK: - Concurrency

func parallelForEach(_ count: Int, threads: Int, _ body: (Int) -> Void) {
    guard count > 0 else { return }
    let lock = NSLock()
    var next = 0
    DispatchQueue.concurrentPerform(iterations: max(1, min(threads, count))) { _ in
        while true {
            lock.lock()
            let i = next
            next += 1
            lock.unlock()
            if i >= count { return }
            body(i)
        }
    }
}

func parentDirectory(_ path: String) -> String {
    let d = (path as NSString).deletingLastPathComponent
    return d.isEmpty ? "." : d
}

func randomToken() -> String {
    String(format: "%08x%08x", arc4random(), arc4random())
}

var isRoot: Bool { geteuid() == 0 }

/// The groups the current process may assign to files it owns.
let myGroups: Set<UInt32> = {
    var set: Set<UInt32> = [getegid()]
    let n = getgroups(0, nil)
    if n > 0 {
        var gs = [gid_t](repeating: 0, count: Int(n))
        let m = getgroups(n, &gs)
        if m > 0 { gs.prefix(Int(m)).forEach { set.insert($0) } }
    }
    return set
}()
