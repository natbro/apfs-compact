import CApfs
import Darwin
import Foundation

/// Measures how many bytes become private when one byte of a clone is
/// rewritten. That is the real allocation cost of each differing region.
func probeCloneGranularity(directory: String) -> Int? {
    let base = "\(directory)/\(tempMarker)probe-\(randomToken())"
    let clone = base + "-clone"
    let dirTimes = DirTimes(directory)
    defer {
        unlink(base)
        unlink(clone)
        dirTimes?.restore()
    }
    let size = 1 << 20
    let buf = AlignedBuffer(size: size)
    arc4random_buf(buf.ptr, size)
    let fd = open(base, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard fd >= 0 else { return nil }
    let ok = (try? writeFully(fd, buf.ptr, size, 0, path: base)) != nil && fsync(fd) == 0
    close(fd)
    guard ok, clonefile(base, clone, UInt32(CLONE_NOFOLLOW)) == 0 else { return nil }
    let cfd = open(clone, O_WRONLY)
    guard cfd >= 0 else { return nil }
    var byte: UInt8 = ~buf.ptr.load(fromByteOffset: 300_001, as: UInt8.self)
    let w = pwrite(cfd, &byte, 1, 300_001)
    fsync(cfd)
    close(cfd)
    guard w == 1, let e = FileEntry.load(clone), let p = e.privateSize, p > 0 else { return nil }
    return Int(p)
}

/// Remembers a directory's mtime/atime so they can be put back after we
/// create/rename entries inside it.
final class DirTimes {
    let path: String
    let mtime: timespec
    let atime: timespec

    init?(_ path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        self.path = path
        mtime = st.st_mtimespec
        atime = st.st_atimespec
    }

    func restore() {
        var m = mtime, a = atime
        _ = capfs_set_mtime_atime(path, &m, &a)
    }
}

public struct ReplaceOutcome: Codable {
    public enum Status: String, Codable { case replaced, skipped, failed }
    public var path: String
    public var base: String
    public var status: Status
    public var messages: [String]
    public var bytesRewritten: Int64
    public var privateBefore: Int64?
    public var privateAfter: Int64?
}

public final class Replacer {
    public var granularityByDev: [Int32: Int] = [:]
    private var dirTimes: [String: DirTimes] = [:]

    public init() {}

    private func rememberDir(_ dir: String) {
        if dirTimes[dir] == nil { dirTimes[dir] = DirTimes(dir) }
    }

    /// Removes a temp file we created, clearing anything that would block it.
    private func discard(_ path: String, fd: Int32?) {
        if let fd {
            _ = fchflags(fd, 0)
            if let empty = acl_init(0) {
                _ = acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED)
                acl_free(UnsafeMutableRawPointer(empty))
            }
            close(fd)
        } else {
            _ = lchflags(path, 0)
        }
        unlink(path)
    }

    /// Tries to give an empty temp file in the target's directory the exact
    /// metadata of the target. Reports anything that couldn't be reproduced.
    public func rehearse(_ target: FileEntry) -> [Issue] {
        let dir = parentDirectory(target.path)
        rememberDir(dir)
        defer { dirTimes[dir]?.restore() }
        let meta: MetadataSnapshot
        do { meta = try MetadataSnapshot.capture(target.path) } catch {
            return [Issue(severity: .blocker, message: "cannot read metadata: \(error)")]
        }
        let tmp = "\(dir)/.\(tempMarker)rehearse-\(randomToken())"
        let fd = open(tmp, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            return [Issue(severity: .blocker, message: "cannot create a file in \(dir): \(errnoString())")]
        }
        var issues = meta.apply(toFD: fd, deferFlags: 0).map { Issue(severity: .blocker, message: "rehearsal: \($0)") }
        if let got = try? MetadataSnapshot.capture(tmp) {
            for d in meta.differences(to: got, ignoreSize: true) {
                let m = "rehearsal: \(d)"
                if !issues.contains(where: { $0.message == m }) { issues.append(Issue(severity: .blocker, message: m)) }
            }
        }
        discard(tmp, fd: fd)
        return issues
    }

    /// Replaces `target` with a clone of `base`, rewriting only the chunks
    /// that differ, then gives it the target's exact metadata. The original is
    /// untouched unless the replacement verifies byte-for-byte and
    /// attribute-for-attribute.
    public func replace(base: FileEntry, target: FileEntry) -> ReplaceOutcome {
        var out = ReplaceOutcome(path: target.path, base: base.path, status: .failed, messages: [],
                                 bytesRewritten: 0, privateBefore: target.privateSize, privateAfter: nil)
        func fail(_ m: String, _ status: ReplaceOutcome.Status = .failed) -> ReplaceOutcome {
            out.status = status
            out.messages.append(m)
            return out
        }

        guard let curB = FileEntry.load(target.path), curB.unchanged(comparedTo: target) else {
            return fail("target changed since it was scanned", .skipped)
        }
        guard let curA = FileEntry.load(base.path), curA.unchanged(comparedTo: base) else {
            return fail("base changed since it was scanned", .skipped)
        }
        out.privateBefore = curB.privateSize
        let G = granularityByDev[target.dev] ?? max(4096, Int(getpagesize()))

        let meta: MetadataSnapshot
        do { meta = try MetadataSnapshot.capture(target.path) } catch { return fail("cannot read metadata: \(error)") }

        let dir = parentDirectory(target.path)
        rememberDir(dir)
        defer { dirTimes[dir]?.restore() }
        let name = (target.path as NSString).lastPathComponent
        let tmp = "\(dir)/.\(name.prefix(100))\(tempMarker)\(randomToken())"

        // 1. Clone the base next to the target. No ACL, no owner copy.
        guard clonefile(base.path, tmp, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
            return fail("clonefile: \(errnoString())")
        }
        _ = lchflags(tmp, 0)
        _ = chmod(tmp, 0o600)
        let tfd = open(tmp, O_RDWR | O_NOFOLLOW)
        guard tfd >= 0 else {
            discard(tmp, fd: nil)
            return fail("open clone: \(errnoString())")
        }
        var committed = false
        defer { if !committed { discard(tmp, fd: tfd) } }

        // 2. Rewrite the chunks that differ and fix the length.
        do {
            out.bytesRewritten = try AtimeGuard.reading(base.path) {
                try patch(tfd: tfd, tmp: tmp, base: base, target: target, chunk: G)
            }
        } catch { return fail("\(error)") }

        // 3. Verify content byte-for-byte against the original.
        do {
            if let m = try verifySame(tfd: tfd, tmp: tmp, target: target) { return fail(m) }
        } catch { return fail("verify: \(error)") }

        // 4. Metadata. Flags that block rename are applied after the rename.
        let deferred = meta.flags & kImmutableLikeFlags
        let deferACL = meta.aclBlocksRename
        let failures = meta.apply(toFD: tfd, deferFlags: deferred, deferACL: deferACL)
        if !failures.isEmpty { return fail("cannot reproduce metadata: " + failures.joined(separator: "; "), .skipped) }
        guard let got = try? MetadataSnapshot.capture(tmp) else { return fail("cannot read back replacement metadata") }
        let diffs = meta.differences(to: got, ignoreFlags: deferred, ignoreACL: deferACL)
        if !diffs.isEmpty { return fail("replacement metadata differs: " + diffs.joined(separator: "; "), .skipped) }

        // 5. Make sure nobody touched the original meanwhile, then swap it in.
        guard let nowB = FileEntry.load(target.path), nowB.unchanged(comparedTo: target) else {
            return fail("target changed during replacement", .skipped)
        }
        if meta.flags & kImmutableLikeFlags != 0 {
            guard lchflags(target.path, meta.flags & ~kImmutableLikeFlags) == 0 else {
                return fail("cannot clear immutable flag on original: \(errnoString())", .skipped)
            }
        }
        // A "deny delete" ACL on the old copy blocks replacing it: lift it
        // (the replacement gets the same ACL right after the rename).
        if deferACL && !setACL(target.path, nil) {
            if meta.flags & kImmutableLikeFlags != 0 { _ = lchflags(target.path, meta.flags) }
            return fail("cannot lift the deny ACL on the original: \(errnoString())", .skipped)
        }
        guard rename(tmp, target.path) == 0 else {
            let e = errnoString()
            if deferACL { _ = setACL(target.path, meta.acl) }
            if meta.flags & kImmutableLikeFlags != 0 { _ = lchflags(target.path, meta.flags) }
            return fail("rename: \(e)")
        }
        committed = true
        defer { close(tfd) }

        // 6. Post-rename: re-assert times if the rename touched any, then final flags.
        if let after = try? MetadataSnapshot.capture(target.path), !meta.differences(to: after, ignoreFlags: deferred).isEmpty {
            var cr = meta.crtime.timespec, m = meta.mtime.timespec, a = meta.atime.timespec, bk = meta.bkuptime.timespec
            var added = meta.addedtime?.timespec ?? timespec()
            _ = meta.addedtime == nil ? capfs_fset_times(tfd, &cr, &m, &a, &bk, nil)
                                      : capfs_fset_times(tfd, &cr, &m, &a, &bk, &added)
        }
        if deferACL, let f = applyACL(toFD: tfd, meta.acl) { out.messages.append(f) }
        if deferred != 0 && fchflags(tfd, meta.flags) != 0 {
            out.messages.append("could not restore flags 0x\(String(meta.flags, radix: 16)): \(errnoString())")
        }
        if let final = try? MetadataSnapshot.capture(target.path) {
            let d = meta.differences(to: final)
            if !d.isEmpty { out.messages.append("after rename: " + d.joined(separator: "; ")) }
        }
        out.privateAfter = FileEntry.load(target.path)?.privateSize
        out.status = .replaced
        return out
    }

    /// Sets (or with nil, clears) the extended ACL on a path.
    private func setACL(_ path: String, _ text: String?) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return applyACL(toFD: fd, text) == nil
    }

    private func patch(tfd: Int32, tmp: String, base: FileEntry, target: FileEntry, chunk G: Int) throws -> Int64 {
        let afd = open(base.path, O_RDONLY | O_NOFOLLOW)
        guard afd >= 0 else { throw posixFailure("open", base.path) }
        defer { close(afd) }
        let bfd = open(target.path, O_RDONLY | O_NOFOLLOW)
        guard bfd >= 0 else { throw posixFailure("open", target.path) }
        defer { close(bfd) }
        var sa = stat(), sb = stat()
        guard fstat(afd, &sa) == 0, sa.st_ino == base.ino, fstat(bfd, &sb) == 0, sb.st_ino == target.ino else {
            throw CompactError("file was replaced while opening")
        }
        _ = fcntl(afd, F_NOCACHE, 1)
        _ = fcntl(bfd, F_NOCACHE, 1)
        // Set the final length first. Growing the file by writing past EOF
        // makes APFS preallocate (~1 MB) beyond EOF, and that stays allocated.
        if base.size != target.size, ftruncate(tfd, off_t(target.size)) != 0 {
            throw posixFailure("truncate", tmp)
        }

        let bufSize = max(G, (8 << 20) / G * G)
        let abuf = AlignedBuffer(size: bufSize), bbuf = AlignedBuffer(size: bufSize)
        var differs = [UInt8](repeating: 0, count: bufSize / G + 1)
        var rewritten: Int64 = 0
        var off: Int64 = 0
        while off < target.size {
            let want = Int(min(Int64(bufSize), target.size - off))
            let nb = try readFully(bfd, bbuf.ptr, want, off, path: target.path)
            guard nb == want else { throw CompactError("\(target.path) shrank while reading") }
            let na = try readFully(afd, abuf.ptr, want, off, path: base.path)
            if na < want { memset(abuf.ptr + na, 0, want - na) }
            _ = differs.withUnsafeMutableBufferPointer { capfs_chunk_diff(abuf.ptr, bbuf.ptr, want, G, $0.baseAddress) }
            // Past the base's end the zero-filled buffer stands in for the zeros
            // that extending the file produces, so all-zero tails stay holes.
            let chunks = (want + G - 1) / G
            // Write runs of differing chunks in one call each.
            var c = 0
            while c < chunks {
                guard differs[c] != 0 else { c += 1; continue }
                var e = c
                while e < chunks && differs[e] != 0 { e += 1 }
                let start = c * G, len = min(e * G, want) - start
                try writeFully(tfd, bbuf.ptr + start, len, off + Int64(start), path: tmp)
                rewritten += Int64(len)
                c = e
            }
            off += Int64(want)
        }
        guard fsync(tfd) == 0 else { throw posixFailure("fsync", tmp) }
        return rewritten
    }

    /// Returns nil if the replacement is byte-identical to the target.
    private func verifySame(tfd: Int32, tmp: String, target: FileEntry) throws -> String? {
        var st = stat()
        guard fstat(tfd, &st) == 0 else { throw posixFailure("stat", tmp) }
        if st.st_size != target.size { return "replacement size \(st.st_size) != \(target.size)" }
        let bfd = open(target.path, O_RDONLY | O_NOFOLLOW)
        guard bfd >= 0 else { throw posixFailure("open", target.path) }
        defer { close(bfd) }
        _ = fcntl(bfd, F_NOCACHE, 1)
        _ = fcntl(tfd, F_NOCACHE, 1)
        let size = 8 << 20
        let x = AlignedBuffer(size: size), y = AlignedBuffer(size: size)
        var off: Int64 = 0
        while off < target.size {
            let want = Int(min(Int64(size), target.size - off))
            let n1 = try readFully(tfd, x.ptr, want, off, path: tmp)
            let n2 = try readFully(bfd, y.ptr, want, off, path: target.path)
            if n1 != want || n2 != want || memcmp(x.ptr, y.ptr, want) != 0 {
                return "content verification failed near offset \(off)"
            }
            off += Int64(want)
        }
        return nil
    }
}

// MARK: - Applying a plan

public struct ApplyReport: Codable {
    public var outcomes: [ReplaceOutcome]
    public var estimatedImmediate: Int64
    public var estimatedEventual: Int64
    public var volumes: [VolumeDelta]
    public var atimesRestored: Int
    /// Exact physical footprint of every file in the plan (bases and targets).
    public var footprintBefore: Footprint
    public var footprintAfter: Footprint

    public struct VolumeDelta: Codable {
        public var mount: String
        public var availableBefore: Int64
        public var availableAfter: Int64
        public var snapshots: [String]
        public var delta: Int64 { availableAfter - availableBefore }
    }

    public var replaced: [ReplaceOutcome] { outcomes.filter { $0.status == .replaced } }
    /// Sum over replaced files of (private bytes before - private bytes after).
    public var privateBytesReleased: Int64 {
        replaced.reduce(0) { $0 + ($1.privateBefore ?? 0) - ($1.privateAfter ?? 0) }
    }
}

public func availableBytes(_ path: String) -> Int64 {
    var v = capfs_vol()
    return capfs_vol_info(path, &v) == 0 ? Int64(v.avail_bytes) : 0
}

/// Waits briefly for APFS to finish releasing freed blocks so that free-space
/// numbers settle (frees are processed asynchronously).
func settledAvailable(_ mount: String) -> Int64 {
    sync()
    var last = availableBytes(mount)
    for _ in 0..<20 {
        usleep(250_000)
        sync()
        let now = availableBytes(mount)
        if now == last { return now }
        last = now
    }
    return last
}

public func applyPlan(_ plan: Plan, progress: ((String) -> Void)? = nil) -> ApplyReport {
    let replacer = Replacer()
    for v in plan.volumes { replacer.granularityByDev[v.dev] = v.granularity }
    var before: [String: Int64] = [:]
    for v in plan.volumes { before[v.mount] = settledAvailable(v.mount) }

    let planPaths = plan.groups.flatMap { [$0.base.path] + $0.targets.map(\.file.path) }
    let fpBefore = Footprint.measure(planPaths)
    var outcomes: [ReplaceOutcome] = []
    let all = plan.groups.flatMap { g in g.targets.map { (g.base, $0) } }
    for (n, (base, t)) in all.enumerated() {
        if t.isBlocked {
            outcomes.append(ReplaceOutcome(path: t.file.path, base: base.path, status: .skipped,
                                           messages: t.issues.filter { $0.severity == .blocker }.map(\.message),
                                           bytesRewritten: 0, privateBefore: t.file.privateSize, privateAfter: nil))
            continue
        }
        progress?("[\(n + 1)/\(all.count)] \(t.file.path)")
        outcomes.append(replacer.replace(base: base, target: t.file))
        if let o = outcomes.last, o.status != .replaced {
            progress?("    \(o.status.rawValue): \(o.messages.joined(separator: "; "))")
        }
    }
    let deltas = plan.volumes.map {
        ApplyReport.VolumeDelta(mount: $0.mount, availableBefore: before[$0.mount] ?? 0,
                                availableAfter: settledAvailable($0.mount), snapshots: $0.snapshots)
    }
    return ApplyReport(outcomes: outcomes, estimatedImmediate: plan.immediateSavings,
                       estimatedEventual: plan.eventualSavings, volumes: deltas,
                       atimesRestored: AtimeGuard.restoredCount,
                       footprintBefore: fpBefore, footprintAfter: Footprint.measure(planPaths))
}
