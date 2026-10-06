# apfs-compact

Finds duplicate and near-duplicate files across directories on an APFS volume
and replaces the duplicates with **APFS clones** of one copy, so they share the
same blocks on disk.

- **Exact duplicates** (any size above `--min-size`) become full clones.
- **Near-duplicates**: files larger than 100 MB that differ in less than 10% of
  their size. Each one becomes a clone of the base with only the differing
  chunks rewritten. Edits don't have to be block-aligned, and files may differ
  in length.

Each replaced file stays byte-identical (same md5) and keeps its mode, owner,
group, ACL, BSD flags (`uchg`, `hidden`, …), all extended attributes (resource
fork, Finder info, tags, quarantine, Gatekeeper provenance, custom xattrs), creation, modification,
access, backup and date-added times, and data-protection class. Two things
can't be kept, by any tool: the inode number and ctime. See
[What can't be preserved](#what-cant-be-preserved).

## Install

```bash
brew install natbro/tap/apfs-compact
```

Or build from source (Swift 5.9+ / Xcode 15+, macOS 13+):

```bash
swift build -c release
```

The binary is `.build/release/apfs-compact`. It has no dependencies beyond the
macOS SDK. `apfs-compact --version` prints the version.

## Usage

```bash
apfs-compact scan ~/Movies /Volumes/Work/Footage          # dry run: what could be reclaimed
apfs-compact scan --rehearse ~/Movies                      # also test every file's metadata on a scratch file
apfs-compact apply ~/Movies /Volumes/Work/Footage          # rehearses, shows plan, asks y/N, then does it
apfs-compact usage ~/Movies                                # du vs private vs exact physical footprint
apfs-compact inspect some/file                             # everything the tool sees about a file (JSON)
```

Options: `--min-size 16k`, `--near-min-size 100MB`, `--max-diff 10`,
`--no-near`, `--granularity SIZE`, `--exclude GLOB`, `--threads N`, `--json`,
`--yes`, `--verbose`.

`scan` modifies nothing. The only writes are a 1 MB temp file (plus a clone of
it) used to measure clone granularity, which `--granularity 16k` skips, and,
with `--rehearse`, empty scratch files. All of them are removed, and the parent
directory times are restored afterwards.

## How it works

1. **Walk** the directories (no symlink following; hard-linked paths count
   once). Gather `lstat` data plus APFS's own accounting per file:
   `ATTR_CMNEXT_PRIVATESIZE` (bytes freed if the file were deleted),
   `ATTR_CMNEXT_CLONEID`, `ATTR_CMNEXT_CLONE_REFCNT` and the `EF_*` flags.
2. **Exact duplicates:** group by volume and size, then compare first/last
   chunk, then full per-chunk hashes.
3. **Near-duplicates** (files above `--near-min-size`): sample ~256 chunks per
   100 MB at fixed offsets, pair files whose samples mostly agree and whose
   sizes are close, then hash those pairs fully and count differing chunks at
   the same offsets.
4. **Plan:** greedily pick the base that saves the most, attach the files
   within the threshold, and repeat. Savings = the target's private bytes
   minus the chunks that must be rewritten. Files that are already clones are
   handled from their block maps, so a second run finds nothing to do.
5. **Check** each target for anything that would stop a faithful replacement
   (see below). `apply` always rehearses: it gives an empty scratch file in
   the same directory each target's exact metadata before anything is
   touched, and every problem is listed before you're asked to confirm.
6. **Replace** each target:
   `clonefile(base → .tmp)` beside the target, then set the length, rewrite
   only the differing chunks, `fsync`, and **verify byte-for-byte** against the
   original. Next it applies the metadata and **verifies it field by field**,
   checks the original hasn't changed since the scan, and `rename`s the
   replacement over it. Flags like `uchg` and deny-ACLs, which would block the
   rename, are applied right after it through the still-open fd. The parent
   directory's mtime and atime are put back. If any step fails, the temp file
   is deleted and the original is untouched.

### Clone granularity

`statfs` reports a 4 KiB block size, but on Apple Silicon a write into a clone
un-shares **16 KiB**, even with `F_NOCACHE`. So the tool measures this on each
volume (clone a file, rewrite one byte, read the private size) and diffs and
rewrites in chunks of that size. Override with `--granularity`.

### Measuring what was reclaimed

`du` counts every allocated block of every file, so clones are counted once per
copy and `du` can't show the savings. The tool reports three independent
figures:

| Measure | What it is |
|---|---|
| **Physical footprint** | Union of the files' physical extents from their block maps (`F_LOG2PHYS_EXT`). Shared blocks count once. Exact, and unaffected by other activity on the volume. |
| **Private bytes** | APFS `ATTR_CMNEXT_PRIVATESIZE`: bytes freed if the file were deleted. |
| **Volume free space** | `statfs` before and after. Correct, but noisy on a busy disk. |

`apfs-compact usage DIR` shows logical, `du`-allocated, private and physical
footprint for any directory, before or after.

**Snapshots.** If the volume has local snapshots (e.g. Time Machine), the old
blocks stay allocated until the snapshots are deleted. The scan lists the
snapshots and gives both "immediate" and "after snapshots" savings.

## What can't be preserved

**For every replaced file (inherent to replacing a file):**

- **Inode / file ID changes.** macOS has no public API to make an existing
  inode share another file's blocks (no `FIDEDUPERANGE`), so the replacement
  is a new file. Apps that track files by ID rather than path may need to
  re-resolve them.
- **ctime** (inode change time) becomes the time of replacement. Only the
  kernel sets it.
- **Hard links can't be kept**, so hard-linked files are never targets. They
  can still serve as the base, which is only read.
- Backup tools that key on inode or ctime (Time Machine included) back the
  file up again once.
- The parent directory's ctime changes (its mtime and atime are restored).

**Per-file situations reported in the scan.** These files are skipped, and the
rest proceed:

| Situation | Why |
|---|---|
| Owned by another user (when not root) | Only root can create a file with someone else's owner. |
| Group differs from the directory's and you're not a member | New files inherit the directory's group; any other group needs `chown`. |
| System flags (`schg`, `sappnd`, `arch`, `restricted`/SIP, `datavault`) | Need root, or can't be set at all. |
| Hard links | See above. |
| Parent directory not writable or immutable | Can't create the replacement next to it. |
| `com.apple.macl` / `com.apple.rootless` xattrs | SIP-protected; user processes can't set them. |
| Transparently compressed (decmpfs) files | A clone-based replacement would be stored uncompressed. |
| Dataless iCloud placeholders | Reading them would trigger a download. |
| Anything the rehearsal can't reproduce exactly | Reported with the exact attribute that differs. |

**Warnings (file is still replaced):**

- **Deny ACLs** (e.g. `everyone deny delete`) block renaming over the file.
  The tool lifts the ACL from the old copy, swaps in the replacement, then
  applies the same ACL to it. For a moment the file has no ACL.
- **Document IDs** (Versions/iCloud tracking): the replacement may get a new
  one.

Repeated issues are grouped in the report (one line per message, with a file
count and a few examples; `--verbose` lists every file).

`com.apple.provenance` (added by macOS 13+ to files written by apps that came
from a quarantined download, e.g. Steam) is copied like any other xattr. If it
couldn't be set, the rehearsal would block that file and name the attribute.

**Reading files doesn't change their times.** APFS normally updates atime on
read when atime is older than mtime. The tool switches that off for its own
process (`IOPOL_TYPE_VFS_ATIME_UPDATES`), so a scan leaves every atime and ctime
alone.

Files that are open and being written by another program aren't detected
beyond the "unchanged since scan" check (size, mtime, ctime and inode compared
just before the rename). Run it on data that isn't in active use.

## Tests

```bash
swift test                                        # standard profile (default)
APFS_COMPACT_TEST_PROFILE=quick swift test         # ~15 s, small files, scaled-down thresholds
APFS_COMPACT_TEST_PROFILE=full swift test          # 4 large families up to 1 GB, ~2.5 min
APFS_COMPACT_TEST_SEED=123 swift test              # reproduce a run
```

Each test creates and mounts its own **sparse APFS disk image**, so free-space
measurements on it are exact. It then builds random directory trees:

- small files (<100 MB) with exact copies, plus slightly edited variants that
  must **not** be touched;
- large files (>100 MB, up to 1 GB) with an exact copy, two near-duplicates
  made of random **unaligned** edits (one is also truncated or extended by an
  unaligned amount), and a 30%-different variant that must **not** be touched;
- random metadata on every file: modes, resource forks, Finder info, tags,
  quarantine, custom xattrs, ACLs (including deny-delete), `hidden` and `uchg`
  flags, and random creation/modification/access/backup/date-added times with
  nanoseconds.

The randomized test checks:

- the dry run changes nothing;
- everything planted was found and nothing else was;
- every chunk-diff count matches an independent byte comparison;
- after `apply`, every file's md5 and every metadata field match the originals;
- replaced files have new inodes and untouched files don't;
- each replacement's private bytes ≤ its rewritten chunks;
- **volume free space and physical footprint both grew by the estimate**
  (within 2%);
- a second scan finds nothing left to do.

A second test covers hard links, compressed files and an immutable directory:
they are reported and left alone. A third drives the CLI binary.

## Releasing

1. Bump `apfsCompactVersion` in `Sources/ApfsCompactCore/Version.swift`, commit,
   and tag `vX.Y.Z`; push the tag.
2. In `packaging/homebrew/apfs-compact.rb`, update `url` to the new tag and set
   `sha256` to the output of
   `curl -sL https://github.com/natbro/apfs-compact/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256`.
3. Copy the formula to `Formula/apfs-compact.rb` in the `natbro/homebrew-tap`
   repo, then check it with
   `brew audit --new --strict natbro/tap/apfs-compact`,
   `brew install --build-from-source natbro/tap/apfs-compact` and
   `brew test natbro/tap/apfs-compact`.

## License

[MIT No Attribution](LICENSE) (SPDX: `MIT-0`). Use it however you like; no warranty, no liability.
