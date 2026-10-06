import CApfs
import Darwin
import Foundation

public struct PlannerOptions {
    /// Files smaller than this are ignored entirely.
    public var minSize: Int64 = 16 << 10
    /// Near-duplicate matching only applies to files larger than this.
    public var nearMinSize: Int64 = 100 << 20
    /// A near-duplicate must differ in less than this fraction of its size.
    public var maxDiff: Double = 0.10
    public var nearEnabled = true
    public var threads = 4
    /// Clone granularity override in bytes; nil = probe the volume.
    public var granularity: Int?
    /// Probe granularity by cloning a small temp file (writes in a target directory).
    public var probeGranularity = true
    public var excludes: [String] = []
    /// Rehearse every target's metadata on an empty temp file in its directory.
    public var rehearse = false
    public var progress: ((String) -> Void)?

    public init() {}
}

public enum Severity: String, Codable { case blocker, warning }

public struct Issue: Codable, Hashable {
    public var severity: Severity
    public var message: String
}

public struct VolumeReport: Codable {
    public var dev: Int32
    public var mount: String
    public var device: String
    public var fsType: String
    public var supportsClone: Bool
    public var blockSize: Int
    public var granularity: Int
    public var granularitySource: String
    public var availableBytes: Int64
    public var snapshots: [String]
}

public struct PlanTarget: Codable {
    public var file: FileEntry
    public var kind: String  // "exact" or "near"
    public var differingChunks: Int
    /// Bytes that must be rewritten into the clone (and stay private to it).
    public var rewriteBytes: Int64
    public var diffFraction: Double
    /// Space freed as soon as the replacement is committed.
    public var immediateSavings: Int64
    /// Space freed once no snapshot references the old blocks.
    public var eventualSavings: Int64
    public var issues: [Issue]
    public var isBlocked: Bool { issues.contains { $0.severity == .blocker } }
}

public struct PlanGroup: Codable {
    public var base: FileEntry
    public var targets: [PlanTarget]
}

public struct Plan: Codable {
    public var roots: [String]
    public var settings: [String: String]
    public var volumes: [VolumeReport]
    public var groups: [PlanGroup]
    public var skipped: [SkippedFile]
    public var errors: [SkippedFile]
    public var filesScanned: Int
    public var bytesScanned: Int64
    public var inherentChanges: [String]

    public var actionableTargets: [PlanTarget] { groups.flatMap(\.targets).filter { !$0.isBlocked } }
    public var blockedTargets: [PlanTarget] { groups.flatMap(\.targets).filter(\.isBlocked) }
    public var immediateSavings: Int64 { actionableTargets.reduce(0) { $0 + $1.immediateSavings } }
    public var eventualSavings: Int64 { actionableTargets.reduce(0) { $0 + $1.eventualSavings } }
}

public let inherentChangeNotes = [
    "Each replaced file becomes a new inode: its file ID / inode number changes. Hard links can't be kept, so hard-linked files are skipped. Apps that track files by ID rather than path (some alias/bookmark data, certain catalog apps) may need to re-resolve them.",
    "ctime (inode change time) is set by the kernel and can't be preserved; replaced files get the time of replacement. (The tool's own reads don't touch atime or ctime of any file.)",
    "Backup tools that compare inode or ctime (Time Machine included) will see replaced files as changed and back them up again once.",
    "The parent directory's mtime/atime are restored after each replacement, but its ctime changes.",
    "Old blocks are only freed when nothing else references them. Local snapshots (Time Machine, etc.) keep them allocated until the snapshot is deleted.",
]

public final class Planner {
    let opts: PlannerOptions
    private let lock = NSLock()

    public init(options: PlannerOptions) { opts = options }

    private func log(_ s: String) { opts.progress?(s) }

    public func makePlan(roots: [String]) throws -> Plan {
        log("Scanning \(roots.count) director\(roots.count == 1 ? "y" : "ies")…")
        let scan = scanDirectories(roots, minSize: opts.minSize, excludes: opts.excludes)
        let files = scan.files.filter(\.isRegular)
        var skipped: [SkippedFile] = []

        // Volumes.
        var vols: [Int32: VolumeReport] = [:]
        for dev in Set(files.map(\.dev)).sorted() {
            let members = files.filter { $0.dev == dev }
            vols[dev] = volumeReport(for: members)
        }

        // Eligibility.
        var eligible: [FileEntry] = []
        for f in files {
            let v = vols[f.dev]!
            if v.fsType != "apfs" || !v.supportsClone {
                skipped.append(SkippedFile(path: f.path, reason: "volume \(v.mount) (\(v.fsType)) does not support clones"))
            } else if f.isDataless {
                skipped.append(SkippedFile(path: f.path, reason: "dataless cloud placeholder (reading it would trigger a download)"))
            } else if f.isCompressed {
                skipped.append(SkippedFile(path: f.path, reason: "transparently compressed (decmpfs); a clone-based replacement would lose compression"))
            } else if access(f.path, R_OK) != 0 {
                skipped.append(SkippedFile(path: f.path, reason: "not readable: \(errnoString())"))
            } else {
                eligible.append(f)
            }
        }
        log("Found \(files.count) files (\(formatBytes(files.reduce(0) { $0 + $1.size }))), \(eligible.count) eligible.")

        func G(_ i: Int) -> Int { vols[eligible[i].dev]!.granularity }
        func isLarge(_ i: Int) -> Bool { eligible[i].size > opts.nearMinSize }

        var chunkCache: [Int: [UInt64]] = [:]
        var errors = scan.errors
        func recordError(_ i: Int, _ e: Error) {
            lock.lock(); errors.append(SkippedFile(path: eligible[i].path, reason: "\(e)")); lock.unlock()
        }
        func ensureChunks(_ idx: [Int]) {
            let need = idx.filter { chunkCache[$0] == nil }
            parallelForEach(need.count, threads: opts.threads) { k in
                let i = need[k]
                do {
                    let h = try ChunkHasher.chunkHashes(path: eligible[i].path, size: eligible[i].size, chunk: G(i))
                    self.lock.lock(); chunkCache[i] = h; self.lock.unlock()
                } catch { recordError(i, error) }
            }
        }

        // ---- Exact duplicates: same volume + size, then head/tail, then full hash.
        struct SizeKey: Hashable { var dev: Int32; var size: Int64 }
        let sizeGroups = Dictionary(grouping: eligible.indices) { SizeKey(dev: eligible[$0].dev, size: eligible[$0].size) }
            .values.filter { $0.count > 1 }
        let sameSize = sizeGroups.flatMap { $0 }
        log("Exact-duplicate check: \(sameSize.count) files share a size with another file.")

        var headTail: [Int: UInt64] = [:]
        let smallSameSize = sameSize.filter { !isLarge($0) }
        parallelForEach(smallSameSize.count, threads: opts.threads) { k in
            let i = smallSameSize[k]
            do {
                let h = try ChunkHasher.headTailHash(path: eligible[i].path, size: eligible[i].size, chunk: G(i))
                self.lock.lock(); headTail[i] = h; self.lock.unlock()
            } catch { recordError(i, error) }
        }
        var fullCandidates: [Int] = sameSize.filter(isLarge)
        struct HTKey: Hashable { var dev: Int32; var size: Int64; var h: UInt64 }
        let htGroups = Dictionary(grouping: smallSameSize.filter { headTail[$0] != nil }) {
            HTKey(dev: eligible[$0].dev, size: eligible[$0].size, h: headTail[$0]!)
        }
        fullCandidates += htGroups.values.filter { $0.count > 1 }.flatMap { $0 }

        var digests: [Int: UInt64] = [:]
        ensureChunks(fullCandidates.filter(isLarge))
        let smallFull = fullCandidates.filter { !isLarge($0) }
        parallelForEach(smallFull.count, threads: opts.threads) { k in
            let i = smallFull[k]
            do {
                let h = try ChunkHasher.chunkHashes(path: eligible[i].path, size: eligible[i].size, chunk: G(i))
                let d = ChunkHasher.combine(h, size: eligible[i].size)
                self.lock.lock(); digests[i] = d; self.lock.unlock()
            } catch { recordError(i, error) }
        }
        for i in fullCandidates where isLarge(i) {
            if let c = chunkCache[i] { digests[i] = ChunkHasher.combine(c, size: eligible[i].size) }
        }
        let exactGroups = Dictionary(grouping: digests.keys) { HTKey(dev: eligible[$0].dev, size: eligible[$0].size, h: digests[$0]!) }
            .values.filter { $0.count > 1 }.map { $0.sorted() }

        // Directed edges: base -> target -> differing chunk count.
        var edges: [Int: [Int: Int]] = [:]
        var kinds: [Pair: String] = [:]
        for g in exactGroups {
            for a in g {
                for b in g where a != b {
                    edges[a, default: [:]][b] = 0
                    kinds[Pair(a, b)] = "exact"
                }
            }
        }
        log("Exact duplicates: \(exactGroups.count) groups, \(exactGroups.reduce(0) { $0 + $1.count }) files.")

        // ---- Near duplicates among large files.
        if opts.nearEnabled {
            let large = eligible.indices.filter(isLarge)
            log("Near-duplicate check: \(large.count) files larger than \(formatBytes(opts.nearMinSize)).")
            var samples: [Int: [UInt64]] = [:]
            func strideFor(_ i: Int) -> Int { max(1, Int(opts.nearMinSize / 256 / Int64(G(i)))) }
            let needSamples = large.filter { chunkCache[$0] == nil }
            parallelForEach(needSamples.count, threads: opts.threads) { k in
                let i = needSamples[k]
                do {
                    let s = try ChunkHasher.sampleHashes(path: eligible[i].path, size: eligible[i].size, chunk: G(i), stride: strideFor(i))
                    self.lock.lock(); samples[i] = s; self.lock.unlock()
                } catch { recordError(i, error) }
            }
            for i in large {
                if let c = chunkCache[i] {
                    let st = strideFor(i)
                    samples[i] = Swift.stride(from: 0, to: c.count, by: st).map { c[$0] }
                }
            }

            // Inverted index over (volume, sample position, hash).
            struct SampleKey: Hashable { var dev: Int32; var pos: Int; var h: UInt64 }
            var index: [SampleKey: [Int]] = [:]
            for i in large {
                guard let s = samples[i] else { continue }
                for (pos, h) in s.enumerated() { index[SampleKey(dev: eligible[i].dev, pos: pos, h: h), default: []].append(i) }
            }
            var pairCounts: [Pair: Int] = [:]
            for bucket in index.values where bucket.count > 1 && bucket.count <= 4000 {
                for x in 0..<bucket.count {
                    for y in (x + 1)..<bucket.count { pairCounts[Pair(bucket[x], bucket[y]), default: 0] += 1 }
                }
            }
            let threshold = max(0.3, 1 - 3 * opts.maxDiff)
            var candidates: [Pair] = []
            for (p, count) in pairCounts {
                let fa = eligible[p.a], fb = eligible[p.b]
                if edges[p.a]?[p.b] != nil { continue }  // already exact duplicates
                let bigger = Double(max(fa.size, fb.size))
                if Double(abs(fa.size - fb.size)) >= opts.maxDiff * bigger { continue }
                let n = min(samples[p.a]!.count, samples[p.b]!.count)
                if Double(count) / Double(max(n, 1)) >= threshold { candidates.append(p) }
            }
            log("Near-duplicate candidates: \(candidates.count) pairs; hashing \(Set(candidates.flatMap { [$0.a, $0.b] }).count) files fully.")
            ensureChunks(Array(Set(candidates.flatMap { [$0.a, $0.b] })).sorted())

            for p in candidates {
                guard let ca = chunkCache[p.a], let cb = chunkCache[p.b] else { continue }
                for (x, cx, y, cy) in [(p.a, ca, p.b, cb), (p.b, cb, p.a, ca)] {
                    let d = differingChunks(base: cx, target: cy)
                    if fraction(d, target: y) < opts.maxDiff {
                        edges[x, default: [:]][y] = d
                        kinds[Pair(x, y)] = d == 0 ? "exact" : "near"
                    }
                }
            }
        }

        func fraction(_ d: Int, target y: Int) -> Double {
            let bytes = min(Int64(d) * Int64(G(y)), eligible[y].size)
            return Double(bytes) / Double(max(eligible[y].size, 1))
        }

        // ---- Savings model.
        // Pure clones share one data stream (same clone ID). If every clone of a
        // stream is a target, replacing them all frees the stream: spread its
        // size over the members. Otherwise replacing some of them frees nothing.
        struct CloneKey: Hashable { var dev: Int32; var id: UInt64 }
        var cloneMembers: [CloneKey: Int] = [:]
        for f in eligible where f.sharesAllBlocks && f.cloneRefcnt > 1 {
            cloneMembers[CloneKey(dev: f.dev, id: f.cloneID), default: 0] += 1
        }
        // For pure clones, APFS reports private size 0, so look at the block
        // maps: only the stream's blocks that the base doesn't already use can
        // be freed, and only once every clone of the stream is replaced.
        var extentCache: [Int: [(Int64, Int64)]] = [:]
        func ext(_ i: Int) -> [(Int64, Int64)] {
            if let e = extentCache[i] { return e }
            let e = Footprint.extents(eligible[i].path)
            extentCache[i] = e
            return e
        }
        func effectivePrivate(_ x: Int, _ y: Int) -> (immediate: Int64, eventual: Int64) {
            let f = eligible[y]
            if f.sharesAllBlocks && f.cloneRefcnt > 1 {
                let m = cloneMembers[CloneKey(dev: f.dev, id: f.cloneID)] ?? 1
                guard m >= Int(f.cloneRefcnt) else { return (0, 0) }
                let share = Footprint.bytesNotIn(ext(y), ext(x)) / Int64(m)
                return (share, share)
            }
            return (f.currentPrivate, f.mayShareBlocks ? f.currentPrivate : f.alloc)
        }
        func savings(_ x: Int, _ y: Int, _ d: Int) -> (immediate: Int64, eventual: Int64) {
            let fx = eligible[x], fy = eligible[y]
            if fx.sharesAllBlocks && fy.sharesAllBlocks && fx.cloneID == fy.cloneID { return (0, 0) }
            let rewrite = Int64(d) * Int64(G(y))
            let e = effectivePrivate(x, y)
            // Without snapshots nothing can trap the old blocks: both figures are the same.
            let eventual = vols[fy.dev]!.snapshots.isEmpty ? e.immediate : e.eventual
            return (e.immediate - rewrite, eventual - rewrite)
        }

        // ---- Static checks decide who can be a target at all.
        var targetIssues: [Int: [Issue]] = [:]
        let involved = Set(edges.keys).union(edges.values.flatMap(\.keys))
        for i in involved { targetIssues[i] = staticIssues(eligible[i]) }
        if opts.rehearse {
            log("Rehearsing metadata on \(involved.count) files…")
            let rehearser = Replacer()
            for i in involved.sorted() where !(targetIssues[i] ?? []).contains(where: { $0.severity == .blocker }) {
                targetIssues[i, default: []] += rehearser.rehearse(eligible[i])
            }
        }
        func blocked(_ i: Int) -> Bool { (targetIssues[i] ?? []).contains { $0.severity == .blocker } }

        // ---- Greedy grouping: pick the base that saves the most, repeat.
        var remaining = involved
        var chosen: [(base: Int, targets: [Int])] = []
        let order = involved.sorted { eligible[$0].path < eligible[$1].path }
        while true {
            var best: (score: Int64, x: Int, ys: [Int])?
            for x in order where remaining.contains(x) {
                guard let outs = edges[x] else { continue }
                var score: Int64 = 0
                var ys: [Int] = []
                for (y, d) in outs where remaining.contains(y) && !blocked(y) {
                    let s = savings(x, y, d)
                    if s.eventual > 0 {
                        score += s.eventual
                        ys.append(y)
                    }
                }
                guard score > 0 else { continue }
                if let b = best {
                    let fx = eligible[x], fb = eligible[b.x]
                    if score < b.score { continue }
                    if score == b.score && !(fx.crtime < fb.crtime) { continue }
                }
                best = (score, x, ys)
            }
            guard let b = best else { break }
            chosen.append((b.x, b.ys.sorted { eligible[$0].path < eligible[$1].path }))
            remaining.remove(b.x)
            b.ys.forEach { remaining.remove($0) }
        }

        // Attach blocked files to the group they would have joined, for reporting.
        var bases = Set(chosen.map(\.base))
        var blockedFor: [Int: [Int]] = [:]
        for y in order where blocked(y) && !bases.contains(y) {
            // Prefer a base that is already in the plan, else any match.
            var bestX: Int?
            var bestS: Int64 = 0
            for x in chosen.map(\.base) + order {
                if let d = edges[x]?[y], x != y {
                    let s = savings(x, y, d).eventual
                    if s > bestS { bestS = s; bestX = x }
                }
                if bestX != nil && !bases.contains(x) { break }
            }
            if let x = bestX {
                blockedFor[x, default: []].append(y)
                if !bases.contains(x) {
                    bases.insert(x)
                    chosen.append((x, []))
                }
            }
        }

        // Clone-set correction: partial replacement of a clone set frees nothing.
        var targetedClones: [CloneKey: Int] = [:]
        for g in chosen {
            for y in g.targets where eligible[y].sharesAllBlocks && eligible[y].cloneRefcnt > 1 {
                targetedClones[CloneKey(dev: eligible[y].dev, id: eligible[y].cloneID), default: 0] += 1
            }
        }

        var groups: [PlanGroup] = []
        for g in chosen {
            var targets: [PlanTarget] = []
            for y in g.targets + (blockedFor[g.base] ?? []) {
                let f = eligible[y]
                let d = edges[g.base]![y]!
                var s = savings(g.base, y, d)
                if f.sharesAllBlocks && f.cloneRefcnt > 1 {
                    let have = targetedClones[CloneKey(dev: f.dev, id: f.cloneID)] ?? 0
                    if have < Int(f.cloneRefcnt) && !blocked(y) {
                        skipped.append(SkippedFile(path: f.path, reason: "already shares all blocks with clones outside this plan; replacing it would free nothing"))
                        continue
                    }
                    if have < Int(f.cloneRefcnt) { s = (0, 0) }
                }
                targets.append(PlanTarget(
                    file: f, kind: kinds[Pair(g.base, y)] ?? "near", differingChunks: d,
                    rewriteBytes: Int64(d) * Int64(G(y)), diffFraction: fraction(d, target: y),
                    immediateSavings: s.immediate, eventualSavings: s.eventual,
                    issues: targetIssues[y] ?? []))
            }
            if !targets.isEmpty { groups.append(PlanGroup(base: eligible[g.base], targets: targets)) }
        }
        groups.sort { $0.targets.reduce(0) { $0 + $1.eventualSavings } > $1.targets.reduce(0) { $0 + $1.eventualSavings } }

        var settings: [String: String] = [
            "min-size": formatBytes(opts.minSize),
            "near-min-size": formatBytes(opts.nearMinSize),
            "max-diff": String(format: "%.1f%%", opts.maxDiff * 100),
            "near-duplicates": opts.nearEnabled ? "on" : "off",
        ]
        if opts.rehearse { settings["rehearse"] = "on" }

        return Plan(
            roots: roots, settings: settings,
            volumes: vols.values.sorted { $0.mount < $1.mount }, groups: groups,
            skipped: skipped, errors: errors,
            filesScanned: files.count, bytesScanned: files.reduce(0) { $0 + $1.size },
            inherentChanges: inherentChangeNotes)
    }

    // MARK: - Helpers

    private func volumeReport(for members: [FileEntry]) -> VolumeReport {
        var v = capfs_vol()
        _ = capfs_vol_info(members[0].path, &v)
        let mount = withUnsafeBytes(of: v.mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let device = withUnsafeBytes(of: v.mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let fsType = withUnsafeBytes(of: v.fstype) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let fallback = max(Int(v.bsize), Int(getpagesize()))
        var gran = fallback
        var source = "max(block size \(v.bsize), VM page size \(getpagesize()))"
        if let g = opts.granularity {
            gran = g
            source = "--granularity"
        } else if opts.probeGranularity && v.supports_clone != 0 {
            let dirs = Array(Set(members.map { parentDirectory($0.path) })).sorted()
            for d in dirs.prefix(20) {
                if let g = probeCloneGranularity(directory: d) {
                    gran = max(g, Int(v.bsize))
                    source = "measured (clone + 1-byte write in \(d))"
                    break
                }
            }
        }
        return VolumeReport(
            dev: members[0].dev, mount: mount, device: device, fsType: fsType,
            supportsClone: v.supports_clone != 0, blockSize: Int(v.bsize),
            granularity: gran, granularitySource: source,
            availableBytes: Int64(v.avail_bytes), snapshots: listSnapshots(mount: mount))
    }

    private func staticIssues(_ f: FileEntry) -> [Issue] {
        var out: [Issue] = []
        func block(_ m: String) { out.append(Issue(severity: .blocker, message: m)) }
        func warn(_ m: String) { out.append(Issue(severity: .warning, message: m)) }

        if f.nlink > 1 { block("has \(f.nlink) hard links; replacing one path would split them") }
        if !isRoot && f.uid != geteuid() { block("owned by uid \(f.uid); only root can create the replacement with that owner") }
        let dir = parentDirectory(f.path)
        var ds = stat()
        let dirOK = lstat(dir, &ds) == 0
        // New files inherit the directory's group, so that one never needs chown.
        if !isRoot && f.uid == geteuid() && !(dirOK && ds.st_gid == f.gid) && !canAssignGroup(f.gid) {
            block("group gid \(f.gid) differs from its directory's and this user isn't a member, so the replacement can't carry it")
        }
        if f.flags & kSF_RESTRICTED != 0 { block("SIP-restricted file (SF_RESTRICTED)") }
        else if f.flags & kSystemFlags != 0 && !isRoot {
            block("has system flags 0x\(String(f.flags & kSystemFlags, radix: 16)) (schg/sappnd/arch/…) that only root can set")
        }
        if f.flags & kUF_DATAVAULT != 0 { block("data-vault protected (UF_DATAVAULT)") }
        if access(dir, W_OK | X_OK) != 0 { block("parent directory not writable: \(errnoString())") }
        if dirOK && ds.st_flags & kImmutableLikeFlags != 0 { block("parent directory is immutable/append-only") }
        if f.documentID != 0 || f.flags & kUF_TRACKED != 0 {
            warn("has a document ID (\(f.documentID)) used by Versions/iCloud; the replacement may get a new one")
        }
        if let acl = try? MetadataSnapshot.readACL(f.path), acl.contains(":deny:") {
            warn("has a deny ACL; it is lifted from the old copy and applied to the replacement right after the swap (briefly, the file has no ACL)")
        }
        if let names = try? MetadataSnapshot.readXattrs(f.path).map(\.name) {
            for n in names where n == "com.apple.macl" || n == "com.apple.rootless" {
                block("protected extended attribute \(n) can't be set by user processes")
            }
        }
        if f.mayShareBlocks && !f.sharesAllBlocks {
            warn("already shares some blocks with another file (an earlier clone)")
        }
        return out
    }
}

struct Pair: Hashable {
    var a: Int
    var b: Int
    init(_ a: Int, _ b: Int) { self.a = a; self.b = b }
}

/// Number of target chunks that differ from the base at the same offset.
func differingChunks(base: [UInt64], target: [UInt64]) -> Int {
    var d = 0
    for i in 0..<target.count where i >= base.count || base[i] != target[i] { d += 1 }
    return d
}

/// Snapshot names on the volume mounted at `mount`, via diskutil.
func listSnapshots(mount: String) -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    p.arguments = ["apfs", "listSnapshots", "-plist", mount]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return [] }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let snaps = plist["Snapshots"] as? [[String: Any]] else { return [] }
    return snaps.compactMap { $0["SnapshotName"] as? String }
}
