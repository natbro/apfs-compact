import Darwin
import Foundation

public func jsonString<T: Encodable>(_ value: T) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dataEncodingStrategy = .base64
    return String(data: (try? enc.encode(value)) ?? Data(), encoding: .utf8) ?? "{}"
}

private func pct(_ x: Double) -> String { String(format: "%.2f%%", x * 100) }

public func renderPlan(_ plan: Plan, verbose: Bool, dryRun: Bool) -> String {
    var o: [String] = []
    o.append(dryRun ? "apfs-compact: dry run (no files were modified)" : "apfs-compact: plan")
    o.append("Roots: " + plan.roots.joined(separator: ", "))
    o.append("Settings: " + plan.settings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
    o.append("")
    o.append("Volumes:")
    for v in plan.volumes {
        o.append("  \(v.mount) [\(v.device), \(v.fsType)] clones: \(v.supportsClone ? "yes" : "NO"), available: \(formatBytes(v.availableBytes))")
        o.append("    clone granularity \(formatBytes(Int64(v.granularity))): \(v.granularitySource)")
        if !v.snapshots.isEmpty {
            o.append("    ! \(v.snapshots.count) snapshot(s) on this volume. Blocks they reference stay allocated until the snapshots are deleted:")
            v.snapshots.prefix(verbose ? 1000 : 5).forEach { o.append("        \($0)") }
            if !verbose && v.snapshots.count > 5 { o.append("        … (\(v.snapshots.count - 5) more)") }
        }
    }
    o.append("")
    o.append("Scanned \(plan.filesScanned) files, \(formatBytes(plan.bytesScanned)) logical.")
    o.append("")

    if plan.groups.isEmpty {
        o.append("No duplicates or near-duplicates worth cloning were found.")
    }
    for (n, g) in plan.groups.enumerated() {
        let save = g.targets.filter { !$0.isBlocked }.reduce(Int64(0)) { $0 + $1.eventualSavings }
        o.append("Group \(n + 1): saves \(formatBytes(save)). Base: \(g.base.path) (\(formatBytes(g.base.size)))")
        for t in g.targets {
            let what = t.kind == "exact" ? "identical" : "\(pct(t.diffFraction)) different, rewrite \(formatBytes(t.rewriteBytes))"
            let s = t.immediateSavings == t.eventualSavings
                ? "saves \(formatBytes(t.eventualSavings))"
                : "saves \(formatBytes(t.immediateSavings)) now, \(formatBytes(t.eventualSavings)) once snapshots are gone"
            o.append("  \(t.isBlocked ? "BLOCKED" : "   ->  ") \(t.file.path)")
            o.append("           \(what); \(s)")
            // Warnings are summarized once below; inline only with --verbose.
            for i in t.issues where i.severity == .blocker || verbose {
                o.append("           \(i.severity == .blocker ? "x" : "!") \(i.message)")
            }
        }
        o.append("")
    }

    let act = plan.actionableTargets, blocked = plan.blockedTargets
    o.append("Summary")
    o.append("  Files to replace with clones: \(act.count)")
    o.append("  Estimated space reclaimed:   \(formatBytes(plan.immediateSavings)) immediately")
    if plan.eventualSavings != plan.immediateSavings {
        o.append("                               \(formatBytes(plan.eventualSavings)) once snapshots referencing the old data are deleted")
    }
    if !blocked.isEmpty {
        o.append("  Blocked files (left alone):  \(blocked.count), which would have saved \(formatBytes(blocked.reduce(0) { $0 + $1.eventualSavings }))")
    }
    o.append("")

    o.append("Preservation check")
    /// One line per distinct message with a file count, plus a few example paths.
    func summarize(_ targets: [PlanTarget], _ severity: Severity, _ mark: String) {
        var byMessage: [String: [String]] = [:]
        for t in targets {
            for i in t.issues where i.severity == severity { byMessage[i.message, default: []].append(t.file.path) }
        }
        for (message, paths) in byMessage.sorted(by: { $0.value.count > $1.value.count }) {
            o.append("    \(mark) \(message) (\(paths.count) file\(paths.count == 1 ? "" : "s"))")
            let shown = verbose ? paths : Array(paths.prefix(3))
            shown.forEach { o.append("        \($0)") }
            if shown.count < paths.count { o.append("        … \(paths.count - shown.count) more (--verbose lists all)") }
        }
    }
    if blocked.isEmpty {
        o.append("  Every planned file can keep its contents, permissions, owner, group, ACL, flags, extended")
        o.append("  attributes (resource fork, Finder info, tags, quarantine, provenance…) and creation/")
        o.append("  modification/access/backup/date-added times.")
    } else {
        o.append("  These files can't keep all of their properties and will be SKIPPED:")
        summarize(blocked, .blocker, "x")
    }
    if act.contains(where: { $0.issues.contains { $0.severity == .warning } }) {
        o.append("  Notes on files that will be replaced:")
        summarize(act, .warning, "!")
    }
    if !plan.settings.keys.contains("rehearse") && !act.isEmpty {
        o.append("  (Only static checks so far. --rehearse tries each file's exact metadata on a scratch file.)")
    }
    o.append("  These always change for a replaced file, whatever the tool does:")
    plan.inherentChanges.forEach { o.append("    - \($0)") }
    o.append("")

    if !plan.skipped.isEmpty {
        let byReason = Dictionary(grouping: plan.skipped, by: \.reason)
        o.append("Not considered (\(plan.skipped.count) files):")
        for (reason, items) in byReason.sorted(by: { $0.value.count > $1.value.count }) {
            o.append("  \(items.count) × \(reason)")
            if verbose { items.forEach { o.append("      \($0.path)") } }
        }
        if !verbose { o.append("  (--verbose lists them)") }
        o.append("")
    }
    if !plan.errors.isEmpty {
        o.append("Errors (\(plan.errors.count)):")
        plan.errors.prefix(verbose ? Int.max : 20).forEach { o.append("  \($0.path): \($0.reason)") }
        o.append("")
    }
    return o.joined(separator: "\n")
}

public func renderApply(_ r: ApplyReport) -> String {
    var o: [String] = []
    let failed = r.outcomes.filter { $0.status == .failed }
    let skipped = r.outcomes.filter { $0.status == .skipped }
    o.append("Results")
    o.append("  Replaced: \(r.replaced.count)   Skipped: \(skipped.count)   Failed: \(failed.count)")
    for x in skipped + failed {
        o.append("  \(x.status.rawValue.uppercased()) \(x.path)")
        x.messages.forEach { o.append("      \($0)") }
    }
    let notes = r.replaced.filter { !$0.messages.isEmpty }
    for x in notes {
        o.append("  NOTE \(x.path)")
        x.messages.forEach { o.append("      \($0)") }
    }
    o.append("")
    o.append("Space accounting")
    o.append("  Estimated:  \(formatBytes(r.estimatedImmediate)) immediately (\(formatBytes(r.estimatedEventual)) after snapshots)")
    let fpDelta = r.footprintBefore.bytes - r.footprintAfter.bytes
    o.append("  Physical footprint of all files in the plan: \(formatBytes(r.footprintBefore.bytes)) -> \(formatBytes(r.footprintAfter.bytes)) (\(formatBytes(fpDelta)) less)")
    o.append("     (union of the files' physical extents from their block maps: exact, unaffected by other activity)")
    o.append("  Private (unshared) bytes of the replaced files went down by \(formatBytes(r.privateBytesReleased))")
    o.append("     (APFS ATTR_CMNEXT_PRIVATESIZE: bytes freed if the file were deleted; `du` can't see this)")
    for v in r.volumes {
        o.append("  Volume \(v.mount): available space \(formatBytes(v.availableBefore)) -> \(formatBytes(v.availableAfter)) (\(v.delta >= 0 ? "+" : "")\(formatBytes(v.delta)))")
        if !v.snapshots.isEmpty { o.append("     \(v.snapshots.count) snapshot(s) still hold the old blocks; the space comes back when they are deleted.") }
    }
    o.append("     Other activity on a busy volume also moves the free-space number; the private-size figure is per file and exact.")
    if r.atimesRestored > 0 { o.append("  Restored access times on \(r.atimesRestored) file(s) after reading them.") }
    return o.joined(separator: "\n")
}

// MARK: - usage

public struct UsageReport: Codable {
    public var files: Int
    public var logical: Int64
    public var allocated: Int64
    public var privateBytes: Int64
    public var filesSharingBlocks: Int
    public var cloneSets: Int
    public var physical: Footprint
    public var sharedOrTrapped: Int64 { allocated - privateBytes }
}

public func computeUsage(roots: [String]) -> UsageReport {
    let scan = scanDirectories(roots, minSize: 0, excludes: [])
    var r = UsageReport(files: 0, logical: 0, allocated: 0, privateBytes: 0, filesSharingBlocks: 0, cloneSets: 0,
                        physical: Footprint(bytes: 0, extents: 0, unmappedFiles: 0))
    var paths: [String] = []
    var clones = Set<[UInt64]>()
    for f in scan.files where f.isRegular {
        r.files += 1
        paths.append(f.path)
        r.logical += f.size
        r.allocated += f.alloc
        r.privateBytes += f.currentPrivate
        if f.mayShareBlocks { r.filesSharingBlocks += 1 }
        if f.sharesAllBlocks { clones.insert([UInt64(UInt32(bitPattern: f.dev)), f.cloneID]) }
    }
    r.cloneSets = clones.count
    r.physical = Footprint.measure(paths)
    return r
}

public func renderUsage(_ u: UsageReport, roots: [String]) -> String {
    """
    Space usage for \(roots.joined(separator: ", "))
      Files:                      \(u.files)
      Logical size:               \(formatBytes(u.logical))
      Allocated (what `du` says): \(formatBytes(u.allocated))
      Private (unshared) bytes:   \(formatBytes(u.privateBytes))  <- freed if all these files were deleted
      Shared with clones or held by snapshots: \(formatBytes(u.sharedOrTrapped))
      Files that share blocks:    \(u.filesSharingBlocks) (\(u.cloneSets) sets of full clones)
      Physical footprint:         \(formatBytes(u.physical.bytes))  <- unique blocks on disk, shared blocks counted once

    `du` counts every allocated block of every file, so clones are counted once per copy.
    The physical footprint comes from each file's block map (F_LOG2PHYS_EXT): it is the
    exact space these files occupy together. Blocks they share with files outside these
    directories, or with snapshots, are included and wouldn't be freed by deleting them.
    """
}
