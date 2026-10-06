@testable import ApfsCompactCore
import Darwin
import Foundation
import XCTest

/// Size profiles. Pick with APFS_COMPACT_TEST_PROFILE=quick|standard|full
/// (default: standard, which uses the real 100 MB / 10% thresholds and files
/// up to 1 GB). APFS_COMPACT_TEST_SEED makes a run reproducible.
struct Profile {
    var name: String
    var dirs: Int
    var smallOriginals: Int
    var smallSize: ClosedRange<Int64>
    var largeOriginals: Int
    var largeSize: ClosedRange<Int64>
    var firstLargeSize: ClosedRange<Int64>
    var nearMinSize: Int64
    var volumeGB: Int

    static let MB: Int64 = 1 << 20

    static let quick = Profile(name: "quick", dirs: 3, smallOriginals: 4, smallSize: (64 << 10)...(6 * MB),
                               largeOriginals: 2, largeSize: (9 * MB)...(40 * MB), firstLargeSize: (30 * MB)...(48 * MB),
                               nearMinSize: 8 * MB, volumeGB: 4)
    static let standard = Profile(name: "standard", dirs: 3, smallOriginals: 6, smallSize: (1 * MB)...(60 * MB),
                                  largeOriginals: 2, largeSize: (101 * MB)...(600 * MB), firstLargeSize: (900 * MB)...(1024 * MB),
                                  nearMinSize: 100 * MB, volumeGB: 24)
    static let full = Profile(name: "full", dirs: 5, smallOriginals: 12, smallSize: (1 * MB)...(99 * MB),
                              largeOriginals: 4, largeSize: (101 * MB)...(1024 * MB), firstLargeSize: (1000 * MB)...(1024 * MB),
                              nearMinSize: 100 * MB, volumeGB: 48)

    static var selected: Profile {
        switch ProcessInfo.processInfo.environment["APFS_COMPACT_TEST_PROFILE"] ?? "standard" {
        case "quick": return .quick
        case "full": return .full
        default: return .standard
        }
    }
}

enum Role: Equatable {
    case original, exactCopy, near, far, smallNear
}

struct Planted {
    var path: String
    var family: String
    var role: Role
}

final class CompactTests: XCTestCase {
    var volume: TestVolume?

    override func tearDown() {
        volume?.destroy()
        volume = nil
        super.tearDown()
    }

    func makeVolume(_ gb: Int, _ name: String) throws -> TestVolume {
        var sf = statfs()
        statfs(FileManager.default.temporaryDirectory.path, &sf)
        let free = Int64(sf.f_bavail) * Int64(sf.f_bsize)
        if free < Int64(gb) << 30 {
            throw XCTSkip("needs \(gb) GB free for the test volume; only \(formatBytes(free)) available")
        }
        let v = try TestVolume(sizeGB: gb, name: name)
        volume = v
        return v
    }

    // MARK: - Fixture

    /// Builds random directory trees containing:
    ///  - small files (below the near-duplicate threshold) with exact copies,
    ///    plus slightly edited variants that must NOT be touched;
    ///  - large files with an exact copy, two near-duplicates made of random
    ///    unaligned edits (one also changes length), and a 30%-different
    ///    variant that must NOT be touched.
    /// Every file gets random metadata.
    func buildFixture(root: String, profile p: Profile, rng: inout SeededRNG) throws -> [Planted] {
        var dirs: [String] = []
        for d in 0..<p.dirs {
            var path = "\(root)/dir\(d)"
            for level in 0..<Int.random(in: 0...2, using: &rng) { path += "/sub\(level)-\(rng.next() % 1000)" }
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            dirs.append(path)
        }
        var planted: [Planted] = []
        func place(_ name: String, in d: Int) -> String { "\(dirs[d % dirs.count])/\(name)" }

        for s in 0..<p.smallOriginals {
            let fam = "small\(s)"
            let size = Int64.random(in: p.smallSize, using: &rng) | 1  // odd size: never block aligned
            let d0 = Int.random(in: 0..<dirs.count, using: &rng)
            let orig = place("\(fam).bin", in: d0)
            try writeRandomFile(orig, size: size)
            planted.append(Planted(path: orig, family: fam, role: .original))
            for c in 0..<Int.random(in: 1...2, using: &rng) {
                let copy = place("\(fam)-copy\(c).bin", in: d0 + c + 1)
                try copyNoClone(orig, copy)
                planted.append(Planted(path: copy, family: fam, role: .exactCopy))
            }
            let near = place("\(fam)-edited.bin", in: d0 + 1)
            try copyNoClone(orig, near)
            _ = try scatterEdits(near, size: size, fraction: 0.01, maxEdits: 5, rng: &rng)
            planted.append(Planted(path: near, family: fam, role: .smallNear))
        }

        for l in 0..<p.largeOriginals {
            let fam = "large\(l)"
            let size = Int64.random(in: l == 0 ? p.firstLargeSize : p.largeSize, using: &rng)
            let d0 = Int.random(in: 0..<dirs.count, using: &rng)
            let orig = place("\(fam).dat", in: d0)
            log("writing \(fam) (\(formatBytes(size))) and its variants")
            try writeRandomFile(orig, size: size)
            planted.append(Planted(path: orig, family: fam, role: .original))

            let copy = place("\(fam)-copy.dat", in: d0 + 1)
            try copyNoClone(orig, copy)
            planted.append(Planted(path: copy, family: fam, role: .exactCopy))

            let near1 = place("\(fam)-near1.dat", in: d0 + 2)
            try copyNoClone(orig, near1)
            let e1 = try scatterEdits(near1, size: size, fraction: Double.random(in: 0.005...0.04, using: &rng),
                                      maxEdits: 40, rng: &rng)
            log("  near1: \(e1.count) unaligned edits")
            planted.append(Planted(path: near1, family: fam, role: .near))

            let near2 = place("\(fam)-near2.dat", in: d0)
            try copyNoClone(orig, near2)
            let e2 = try scatterEdits(near2, size: size, fraction: Double.random(in: 0.002...0.02, using: &rng),
                                      maxEdits: 12, rng: &rng)
            if Bool.random(using: &rng) {
                let extra = Int.random(in: 1...200_000, using: &rng)
                try appendRandom(near2, bytes: extra)
                log("  near2: \(e2.count) unaligned edits + appended \(extra) bytes")
            } else {
                let cut = Int64.random(in: 1...200_000, using: &rng)
                try truncateFile(near2, to: size - cut)
                log("  near2: \(e2.count) unaligned edits + truncated \(cut) bytes")
            }
            planted.append(Planted(path: near2, family: fam, role: .near))

            let far = place("\(fam)-far.dat", in: d0 + 1)
            try copyNoClone(orig, far)
            _ = try scatterEdits(far, size: size, fraction: 0.30, maxEdits: 8, rng: &rng)
            planted.append(Planted(path: far, family: fam, role: .far))
        }

        for f in planted { try decorate(f.path, rng: &rng) }
        return planted
    }

    func options(_ p: Profile) -> PlannerOptions {
        var o = PlannerOptions()
        o.nearMinSize = p.nearMinSize
        o.maxDiff = 0.10
        o.rehearse = true
        o.progress = { log($0) }
        return o
    }

    func seed() -> UInt64 {
        if let s = ProcessInfo.processInfo.environment["APFS_COMPACT_TEST_SEED"], let v = UInt64(s) { return v }
        return UInt64(arc4random()) << 32 | UInt64(arc4random())
    }

    // MARK: - The main randomized end-to-end test

    func testRandomizedCompaction() throws {
        let p = Profile.selected
        let s = seed()
        log("profile=\(p.name) seed=\(s) (rerun with APFS_COMPACT_TEST_SEED=\(s))")
        var rng = SeededRNG(seed: s)
        let vol = try makeVolume(p.volumeGB, "rand")
        let root = vol.mount + "/data"
        let planted = try buildFixture(root: root, profile: p, rng: &rng)

        let files = allFiles(under: root)
        var before: [String: FileState] = [:]
        for f in files { before[f] = try captureState(f) }
        let availBefore = settledAvailable(vol.mount)

        // ---- Dry run: plan, and nothing may change.
        let roots = try FileManager.default.contentsOfDirectory(atPath: root).sorted().map { "\(root)/\($0)" }
        let plan = try Planner(options: options(p)).makePlan(roots: roots)
        print(renderPlan(plan, verbose: true, dryRun: true))
        for f in files {
            let now = try captureState(f)
            XCTAssertEqual(now.ino, before[f]!.ino, "dry run replaced \(f)")
            XCTAssertEqual(now.md5, before[f]!.md5, "dry run changed content of \(f)")
            XCTAssertEqual(before[f]!.meta.differences(to: now.meta), [], "dry run changed metadata of \(f)")
        }
        // The probe and rehearsal scratch files cause a little APFS metadata churn.
        XCTAssertEqual(Double(settledAvailable(vol.mount)), Double(availBefore), accuracy: Double(1 << 20),
                       "dry run changed free space")

        // ---- The plan found what we planted, and nothing else.
        let gran = plan.volumes[0].granularity
        var role: [String: Planted] = [:]
        planted.forEach { role[$0.path] = $0 }
        let targets = plan.groups.flatMap { g in g.targets.map { (g.base.path, $0) } }
        let inPlan = Set(plan.groups.flatMap { [$0.base.path] + $0.targets.map(\.file.path) })
        XCTAssertEqual(plan.blockedTargets.map(\.file.path), [], "unexpected blocked files")

        for f in planted {
            switch f.role {
            case .original, .exactCopy, .near:
                XCTAssertTrue(inPlan.contains(f.path), "\(f.path) (\(f.role)) should have been found")
            case .far, .smallNear:
                XCTAssertFalse(inPlan.contains(f.path), "\(f.path) (\(f.role)) should not be compacted")
            }
        }
        for (base, t) in targets {
            XCTAssertEqual(role[base]?.family, role[t.file.path]?.family, "\(t.file.path) paired across families")
            XCTAssertLessThan(t.diffFraction, 0.10)
            let independent = try countDifferingChunks(base: base, target: t.file.path, chunk: gran)
            XCTAssertEqual(t.differingChunks, independent, "chunk diff mismatch for \(t.file.path)")
            if role[t.file.path]?.role == .near || role[base]?.role == .near {
                XCTAssertGreaterThan(t.differingChunks, 0, "\(t.file.path) should differ from \(base)")
            }
        }
        let nearFound = targets.filter { $0.1.kind == "near" }.count
        log("plan: \(targets.count) targets (\(nearFound) near-duplicates), estimated \(formatBytes(plan.immediateSavings))")
        XCTAssertGreaterThan(nearFound, 0, "no near-duplicates were compacted")

        // ---- Apply.
        let report = applyPlan(plan) { log($0) }
        print(renderApply(report))
        XCTAssertEqual(report.outcomes.filter { $0.status != .replaced }.map { "\($0.path): \($0.messages)" }, [])

        // ---- Every file is indistinguishable from before (except inode/ctime).
        let replaced = Set(report.replaced.map(\.path))
        XCTAssertEqual(allFiles(under: root), files, "file set changed (leftover temp files?)")
        for f in files {
            let now = try captureState(f)
            XCTAssertEqual(now.md5, before[f]!.md5, "content changed: \(f)")
            XCTAssertEqual(before[f]!.meta.differences(to: now.meta), [], "metadata changed: \(f)")
            if replaced.contains(f) {
                XCTAssertNotEqual(now.ino, before[f]!.ino, "\(f) should be a new (cloned) file")
            } else {
                XCTAssertEqual(now.ino, before[f]!.ino, "\(f) should not have been replaced")
            }
        }
        for (_, t) in targets {
            let o = report.outcomes.first { $0.path == t.file.path }!
            XCTAssertLessThanOrEqual(o.privateAfter ?? .max, t.rewriteBytes + Int64(gran),
                                     "\(t.file.path) holds more unshared data than its differences")
        }

        // ---- Space really came back. The volume is ours alone, so this is exact
        // up to APFS metadata.
        let availAfter = settledAvailable(vol.mount)
        let gained = availAfter - availBefore
        let fpGained = report.footprintBefore.bytes - report.footprintAfter.bytes
        log("estimated \(formatBytes(plan.immediateSavings)); volume free space +\(formatBytes(gained)); "
            + "physical footprint -\(formatBytes(fpGained)); private bytes -\(formatBytes(report.privateBytesReleased))")
        let tolerance = Double(plan.immediateSavings) * 0.02 + Double(8 << 20)
        XCTAssertEqual(Double(gained), Double(plan.immediateSavings), accuracy: tolerance, "free-space gain vs estimate")
        XCTAssertEqual(Double(fpGained), Double(plan.immediateSavings), accuracy: tolerance, "footprint drop vs estimate")
        XCTAssertGreaterThan(gained, 0)

        // ---- Idempotent: a second scan has nothing left to do.
        let again = try Planner(options: options(p)).makePlan(roots: roots)
        XCTAssertEqual(again.actionableTargets.map(\.file.path), [], "second run still found work")
    }

    // MARK: - Things that must be reported instead of silently done

    func testUnpreservableFilesAreReportedAndLeftAlone() throws {
        let vol = try makeVolume(2, "block")
        let root = vol.mount + "/b"
        let locked = root + "/locked-dir"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        var rng = SeededRNG(seed: 42)

        // Base with three duplicates that can't be replaced faithfully.
        try writeRandomFile(root + "/base.bin", size: 3 << 20)
        try copyNoClone(root + "/base.bin", root + "/hardlinked.bin")
        XCTAssertEqual(link(root + "/hardlinked.bin", root + "/hardlinked-2.bin"), 0)
        try copyNoClone(root + "/base.bin", locked + "/in-locked-dir.bin")
        try copyNoClone(root + "/base.bin", root + "/fine.bin")
        try decorate(root + "/fine.bin", rng: &rng)

        // A transparently compressed file (and its uncompressed twin).
        let text = String(repeating: "compressible text 0123456789\n", count: 40000)
        try text.write(toFile: root + "/plain.txt", atomically: false, encoding: .utf8)
        try shell("/usr/bin/ditto", ["--hfsCompression", root + "/plain.txt", root + "/compressed.txt"])
        let compressedEntry = FileEntry.load(root + "/compressed.txt")!
        XCTAssertTrue(compressedEntry.isCompressed, "ditto didn't compress the fixture")
        XCTAssertEqual(chflags(locked, UInt32(UF_IMMUTABLE)), 0)

        let files = allFiles(under: root)
        var before: [String: FileState] = [:]
        for f in files { before[f] = try captureState(f) }

        var o = PlannerOptions()
        o.rehearse = true
        let plan = try Planner(options: o).makePlan(roots: [root])
        print(renderPlan(plan, verbose: true, dryRun: true))

        let blocked = Dictionary(uniqueKeysWithValues: plan.blockedTargets.map { ($0.file.path, $0.issues.map(\.message).joined()) })
        // The hard-linked file may be used as the base (only read, so harmless);
        // if it is a target, it must be blocked.
        let hardlinkPaths = Set([root + "/hardlinked.bin", root + "/hardlinked-2.bin"])
        let hlIsBase = plan.groups.contains { hardlinkPaths.contains($0.base.path) }
        let hlBlocked = blocked.contains { hardlinkPaths.contains($0.key) && $0.value.contains("hard link") }
        XCTAssertTrue(hlIsBase || hlBlocked, "hard-linked file neither base nor blocked")
        XCTAssertFalse(plan.actionableTargets.contains { hardlinkPaths.contains($0.file.path) })
        XCTAssertTrue(blocked[locked + "/in-locked-dir.bin"]?.contains("immutable") ?? false, "\(blocked)")
        XCTAssertTrue(plan.skipped.contains { $0.path.hasSuffix("compressed.txt") && $0.reason.contains("compressed") })
        XCTAssertTrue(plan.actionableTargets.contains { $0.file.path.hasSuffix("fine.bin") || $0.file.path.hasSuffix("base.bin") })

        let report = applyPlan(plan)
        print(renderApply(report))
        XCTAssertEqual(report.outcomes.filter { $0.status == .failed }.count, 0)
        for f in files {
            let now = try captureState(f)
            XCTAssertEqual(now.md5, before[f]!.md5, f)
            XCTAssertEqual(before[f]!.meta.differences(to: now.meta), [], f)
            if f.contains("hardlinked") || f.contains("locked-dir") || f.contains(".txt") {
                XCTAssertEqual(now.ino, before[f]!.ino, "\(f) must be left alone")
            }
        }
        var st = stat()
        XCTAssertEqual(lstat(root + "/hardlinked.bin", &st), 0)
        XCTAssertEqual(st.st_nlink, 2, "hard link was broken")
        XCTAssertEqual(chflags(locked, 0), 0)
    }

    // MARK: - The command-line tool

    func testCommandLineDryRunAndApply() throws {
        let vol = try makeVolume(2, "cli")
        let root = vol.mount + "/c"
        for d in ["a", "b"] { try FileManager.default.createDirectory(atPath: "\(root)/\(d)", withIntermediateDirectories: true) }
        var rng = SeededRNG(seed: 7)
        try writeRandomFile(root + "/a/one.bin", size: 5_000_001)
        try copyNoClone(root + "/a/one.bin", root + "/b/two.bin")
        try writeRandomFile(root + "/a/big.bin", size: 20_000_003)
        try copyNoClone(root + "/a/big.bin", root + "/b/big-edit.bin")
        _ = try scatterEdits(root + "/b/big-edit.bin", size: 20_000_003, fraction: 0.01, maxEdits: 5, rng: &rng)
        for f in allFiles(under: root) { try decorate(f, rng: &rng) }
        var before: [String: FileState] = [:]
        for f in allFiles(under: root) { before[f] = try captureState(f) }

        let exe = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("apfs-compact").path
        guard FileManager.default.isExecutableFile(atPath: exe) else { throw XCTSkip("CLI binary not found at \(exe)") }

        let dry = try shell(exe, ["scan", "--json", "--near-min-size", "10MB", root + "/a", root + "/b"])
        let plan = try JSONDecoder().decode(Plan.self, from: Data(dry.utf8))
        XCTAssertEqual(plan.actionableTargets.count, 2)
        XCTAssertEqual(plan.actionableTargets.filter { $0.kind == "near" }.count, 1)
        for (f, s) in before { XCTAssertEqual(try captureState(f).ino, s.ino, "scan modified \(f)") }

        let human = try shell(exe, ["apply", "--yes", "--near-min-size", "10MB", root + "/a", root + "/b"])
        print(human)
        XCTAssertTrue(human.contains("Replaced: 2"), human)
        for (f, s) in before {
            let now = try captureState(f)
            XCTAssertEqual(now.md5, s.md5, f)
            XCTAssertEqual(s.meta.differences(to: now.meta), [], f)
        }
        let usage = try shell(exe, ["usage", root])
        XCTAssertTrue(usage.contains("Physical footprint"), usage)
    }

    // MARK: - Small pure functions

    func testParseSize() {
        XCTAssertEqual(parseSize("100MB"), 100 << 20)
        XCTAssertEqual(parseSize("16k"), 16384)
        XCTAssertEqual(parseSize("1.5g"), 3 << 29)
        XCTAssertEqual(parseSize("4096"), 4096)
        XCTAssertNil(parseSize("lots"))
    }

    func testDifferingChunks() {
        XCTAssertEqual(differingChunks(base: [1, 2, 3], target: [1, 2, 3]), 0)
        XCTAssertEqual(differingChunks(base: [1, 2, 3], target: [1, 9, 3, 4]), 2)
        XCTAssertEqual(differingChunks(base: [1, 2, 3, 4], target: [1, 2]), 0)
    }
}
