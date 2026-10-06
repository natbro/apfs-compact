import ApfsCompactCore
import Darwin
import Foundation

let usageText = """
usage: apfs-compact <command> [options] DIR...
       apfs-compact --version

Finds duplicate and near-duplicate files and replaces the duplicates with APFS
clones of one copy. A near-duplicate becomes a clone with only the differing
blocks rewritten. Contents, permissions, owner, ACLs, flags, extended attributes
(resource forks included) and all settable timestamps stay as they were.

commands:
  scan     (alias: dry-run) Report what could be reclaimed. Modifies nothing,
           except for a tiny temp file used to measure clone granularity
           (skip it with --granularity) and --rehearse scratch files.
  apply    Do the replacement. Rehearses every file's metadata first, prints
           the plan with anything that can't be preserved, and asks before
           changing anything (unless --yes). `apply --dry-run` = `scan`.
  usage    Show logical/allocated/private (unshared) space for DIRs: what
           `du` reports vs what deleting the files would actually free.
  inspect  Print everything the tool knows about FILE... (JSON).

options:
  --min-size SIZE        ignore files smaller than SIZE (default 16k)
  --near-min-size SIZE   near-duplicate matching for files larger than SIZE (default 100MB)
  --max-diff PCT         near-duplicates must differ by less than PCT% (default 10)
  --no-near              exact duplicates only
  --granularity SIZE     clone/CoW granularity (default: measure on each volume)
  --exclude GLOB         skip names/paths matching GLOB (repeatable)
  --threads N            parallel readers (default 4)
  --rehearse             (scan) try each target's metadata on a scratch file
  --no-restore-atime     don't put back access times changed by our reads
  --yes                  (apply) don't prompt
  --json                 machine-readable output
  -v, --verbose          list every skipped file
  --version              print the version and exit
"""

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

func stderr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usageText); exit(2) }
args.removeFirst()
if command == "-h" || command == "--help" || command == "help" { print(usageText); exit(0) }
if command == "--version" || command == "version" { print("apfs-compact \(apfsCompactVersion)"); exit(0) }

var opts = PlannerOptions()
var json = false, verbose = false, yes = false, dryRun = false
var paths: [String] = []
var i = 0
func sizeValue() -> Int64 {
    let v = value()
    guard let n = parseSize(v) else { die("bad size: \(v)") }
    return n
}
func value() -> String {
    i += 1
    guard i < args.count else { die("missing value for \(args[i - 1])") }
    return args[i]
}
while i < args.count {
    let a = args[i]
    switch a {
    case "--min-size": opts.minSize = sizeValue()
    case "--near-min-size": opts.nearMinSize = sizeValue()
    case "--max-diff":
        guard let p = Double(value().replacingOccurrences(of: "%", with: "")), p > 0, p < 100 else { die("bad --max-diff") }
        opts.maxDiff = p / 100
    case "--no-near": opts.nearEnabled = false
    case "--granularity":
        guard let g = parseSize(value()), g >= 512 else { die("bad --granularity") }
        opts.granularity = Int(g)
    case "--exclude": opts.excludes.append(value())
    case "--threads":
        guard let n = Int(value()), n > 0 else { die("bad --threads") }
        opts.threads = n
    case "--rehearse": opts.rehearse = true
    case "--no-restore-atime": AtimeGuard.enabled = false
    case "--yes", "-y": yes = true
    case "--json": json = true
    case "--dry-run", "-n": dryRun = true
    case "-v", "--verbose": verbose = true
    case "-h", "--help": print(usageText); exit(0)
    default:
        if a.hasPrefix("-") { die("unknown option \(a)\n\n\(usageText)") }
        paths.append(a)
    }
    i += 1
}
guard !paths.isEmpty else { die("no directories given\n\n\(usageText)") }
for p in paths {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { die("no such file or directory: \(p)") }
    if command != "inspect" && !isDir.boolValue { die("not a directory: \(p)") }
}
let roots = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
if !json { opts.progress = { stderr($0) } }

switch command {
case "scan", "dry-run", "apply":
    let isApply = command == "apply" && !dryRun
    if isApply { opts.rehearse = true }
    let plan: Plan
    do { plan = try Planner(options: opts).makePlan(roots: roots) } catch { die("\(error)") }
    if !isApply {
        print(json ? jsonString(plan) : renderPlan(plan, verbose: verbose, dryRun: true))
        exit(0)
    }
    if !json { print(renderPlan(plan, verbose: verbose, dryRun: false)) }
    if plan.actionableTargets.isEmpty {
        if json { print(jsonString(plan)) } else { print("Nothing to do.") }
        exit(0)
    }
    if !yes {
        let n = plan.actionableTargets.count
        let blocked = plan.blockedTargets.count
        print("\nReplace \(n) file(s) with clones\(blocked > 0 ? " and skip \(blocked) that can't keep all their properties" : "")? [y/N] ", terminator: "")
        fflush(stdout)
        guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
            print("Aborted; nothing was changed.")
            exit(1)
        }
    }
    let report = applyPlan(plan, progress: json ? nil : { stderr($0) })
    print(json ? jsonString(["plan": AnyEncodable(plan), "result": AnyEncodable(report)]) : "\n" + renderApply(report))
    exit(report.outcomes.contains { $0.status == .failed } ? 1 : 0)

case "usage":
    let u = computeUsage(roots: roots)
    print(json ? jsonString(u) : renderUsage(u, roots: roots))

case "inspect":
    struct Inspect: Encodable { var entry: FileEntry?; var metadata: MetadataSnapshot? ; var error: String? }
    var out: [String: Inspect] = [:]
    for p in roots {
        do { out[p] = Inspect(entry: FileEntry.load(p), metadata: try MetadataSnapshot.capture(p), error: nil) }
        catch { out[p] = Inspect(entry: nil, metadata: nil, error: "\(error)") }
    }
    print(jsonString(out))

default:
    die("unknown command \(command)\n\n\(usageText)")
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
