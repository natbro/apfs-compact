import CApfs
import Darwin
import Foundation

/// Exact on-disk footprint of a set of files: the union of their physical
/// extents (via F_LOG2PHYS_EXT), so blocks shared by clones count once.
/// This reads no file data, only block maps.
public struct Footprint: Codable {
    public var bytes: Int64
    public var extents: Int
    public var unmappedFiles: Int

    /// Physical extents (device offset, length) of one file, merged and sorted.
    static func extents(_ path: String) -> [(Int64, Int64)] {
        var r: [Int32: [(Int64, Int64)]] = [:]
        var u = 0
        collect(path, into: &r, unmapped: &u)
        return merge(r.values.first ?? [])
    }

    /// Bytes of `a` that are not also in `b` (both merged/sorted).
    static func bytesNotIn(_ a: [(Int64, Int64)], _ b: [(Int64, Int64)]) -> Int64 {
        var total: Int64 = 0
        var j = 0
        for (s, l) in a {
            var cur = s
            let end = s + l
            while j < b.count && b[j].0 + b[j].1 <= cur { j += 1 }
            var k = j
            while cur < end {
                if k >= b.count || b[k].0 >= end { total += end - cur; break }
                if b[k].0 > cur { total += b[k].0 - cur }
                cur = max(cur, b[k].0 + b[k].1)
                k += 1
            }
        }
        return total
    }

    static func merge(_ input: [(Int64, Int64)]) -> [(Int64, Int64)] {
        let rs = input.sorted { $0.0 < $1.0 }
        var out: [(Int64, Int64)] = []
        for (s, l) in rs {
            if let last = out.last, s <= last.0 + last.1 {
                out[out.count - 1].1 = max(last.0 + last.1, s + l) - last.0
            } else {
                out.append((s, l))
            }
        }
        return out
    }

    private static func collect(_ p: String, into ranges: inout [Int32: [(Int64, Int64)]], unmapped: inout Int) {
        let fd = open(p, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { unmapped += 1; return }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { unmapped += 1; return }
        let size = Int64(st.st_size)
        let bs = Int64(st.st_blksize)
        var off: Int64 = 0
        var dev: Int64 = 0, contig: Int64 = 0
        while off < size {
            if capfs_log2phys(fd, off, size - off, &dev, &contig) != 0 || contig <= 0 {
                off += bs  // hole (sparse) or unmappable
                continue
            }
            ranges[st.st_dev, default: []].append((dev, (contig + bs - 1) / bs * bs))
            off += contig
        }
    }

    public static func measure(_ paths: [String]) -> Footprint {
        var ranges: [Int32: [(Int64, Int64)]] = [:]
        var unmapped = 0
        for p in paths { collect(p, into: &ranges, unmapped: &unmapped) }
        var total: Int64 = 0, count = 0
        for rs in ranges.values {
            for (_, l) in merge(rs) { total += l; count += 1 }
        }
        return Footprint(bytes: total, extents: count, unmappedFiles: unmapped)
    }
}
