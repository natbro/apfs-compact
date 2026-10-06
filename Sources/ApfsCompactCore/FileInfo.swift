import CApfs
import Darwin
import Foundation

// Flags that may be missing from the Swift overlay.
let kSF_DATALESS: UInt32 = 0x4000_0000
let kSF_RESTRICTED: UInt32 = 0x0008_0000
let kSF_FIRMLINK: UInt32 = 0x0080_0000
let kUF_COMPRESSED: UInt32 = 0x0000_0020
let kUF_TRACKED: UInt32 = 0x0000_0040
let kUF_DATAVAULT: UInt32 = 0x0000_0080
let kEF_MAY_SHARE_BLOCKS: UInt64 = 0x1
let kEF_SHARES_ALL_BLOCKS: UInt64 = 0x40
/// Flags that block writes/renames and therefore must be applied after the final rename.
let kImmutableLikeFlags: UInt32 = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
/// Flags only root can set (or that nobody can set, like SF_RESTRICTED).
let kSystemFlags: UInt32 = 0xFFFF_0000

/// A scanned regular file.
public struct FileEntry: Codable, Hashable {
    public var path: String
    public var dev: Int32
    public var ino: UInt64
    public var size: Int64
    public var alloc: Int64
    public var nlink: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var mode: UInt16
    public var flags: UInt32
    public var privateSize: Int64?
    public var cloneID: UInt64
    public var extFlags: UInt64
    public var cloneRefcnt: UInt32
    public var mtime: TS
    public var ctime: TS
    public var crtime: TS
    public var documentID: UInt32

    public static func load(_ path: String) -> FileEntry? {
        var info = capfs_info()
        guard capfs_get_info(path, &info) == 0 else { return nil }
        return FileEntry(path: path, info: info)
    }

    init(path: String, info: capfs_info) {
        self.path = path
        dev = info.dev
        ino = info.ino
        size = info.size
        alloc = info.alloc
        nlink = info.nlink
        uid = info.uid
        gid = info.gid
        mode = info.mode
        flags = info.flags
        privateSize = info.has_private_size != 0 ? info.private_size : nil
        cloneID = info.has_clone_id != 0 ? info.clone_id : 0
        extFlags = info.has_ext_flags != 0 ? info.ext_flags : 0
        cloneRefcnt = info.has_clone_refcnt != 0 ? info.clone_refcnt : 0
        mtime = TS(info.mtime)
        ctime = TS(info.ctime)
        crtime = TS(info.crtime)
        documentID = info.has_document_id != 0 ? info.document_id : 0
    }

    public var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    public var isCompressed: Bool { flags & kUF_COMPRESSED != 0 }
    public var isDataless: Bool { flags & kSF_DATALESS != 0 }
    public var mayShareBlocks: Bool { extFlags & kEF_MAY_SHARE_BLOCKS != 0 }
    public var sharesAllBlocks: Bool { extFlags & kEF_SHARES_ALL_BLOCKS != 0 }
    /// Bytes that would be freed right now if this file disappeared.
    public var currentPrivate: Int64 { privateSize ?? alloc }

    /// Same inode, size, mtime and ctime as when scanned. atime is ignored
    /// because our own reads may legitimately touch it.
    func unchanged(comparedTo other: FileEntry) -> Bool {
        dev == other.dev && ino == other.ino && size == other.size && mtime == other.mtime && ctime == other.ctime
    }
}

// MARK: - Full metadata snapshot

public struct XAttr: Codable, Equatable {
    public var name: String
    public var value: Data
}

/// Everything about a file that should look identical after replacement.
public struct MetadataSnapshot: Codable, Equatable {
    // Preserved (compared) properties
    public var size: Int64
    public var mode: UInt16
    public var uid: UInt32
    public var gid: UInt32
    public var flags: UInt32
    public var crtime: TS
    public var mtime: TS
    public var atime: TS
    public var bkuptime: TS
    public var addedtime: TS?
    public var xattrs: [XAttr]
    public var acl: String?
    public var protectionClass: Int32?

    // Informational (cannot be preserved by any replacement)
    public var dev: Int32
    public var ino: UInt64
    public var ctime: TS
    public var nlink: UInt32
    public var documentID: UInt32

    public static func capture(_ path: String) throws -> MetadataSnapshot {
        var info = capfs_info()
        guard capfs_get_info(path, &info) == 0 else { throw posixFailure("stat", path) }
        var snap = MetadataSnapshot(
            size: info.size, mode: info.mode, uid: info.uid, gid: info.gid, flags: info.flags,
            crtime: TS(info.crtime), mtime: TS(info.mtime), atime: TS(info.atime), bkuptime: TS(info.bkuptime),
            addedtime: info.has_addedtime != 0 ? TS(info.addedtime) : nil,
            xattrs: try readXattrs(path), acl: try readACL(path), protectionClass: nil,
            dev: info.dev, ino: info.ino, ctime: TS(info.ctime), nlink: info.nlink,
            documentID: info.has_document_id != 0 ? info.document_id : 0)
        // Protection class needs an fd. Opening for read doesn't change atime.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd >= 0 {
            let c = fcntl(fd, F_GETPROTECTIONCLASS)
            if c >= 0 { snap.protectionClass = c }
            close(fd)
        }
        return snap
    }

    /// Differences in preserved properties. `ignoreSize` is for rehearsals on
    /// empty files; `ignoreFlags` masks flags that are applied after rename.
    public func differences(to other: MetadataSnapshot, ignoreSize: Bool = false, ignoreFlags: UInt32 = 0,
                            ignoreACL: Bool = false) -> [String] {
        var d: [String] = []
        func check<T: Equatable>(_ name: String, _ a: T, _ b: T) {
            if a != b { d.append("\(name): expected \(a), got \(b)") }
        }
        if !ignoreSize { check("size", size, other.size) }
        check("mode", String(mode, radix: 8), String(other.mode, radix: 8))
        check("owner uid", uid, other.uid)
        check("group gid", gid, other.gid)
        check("flags", String(flags & ~ignoreFlags, radix: 16), String(other.flags & ~ignoreFlags, radix: 16))
        check("creation time", crtime, other.crtime)
        check("modification time", mtime, other.mtime)
        check("access time", atime, other.atime)
        check("backup time", bkuptime, other.bkuptime)
        if let a = addedtime { check("date added", a, other.addedtime ?? TS(sec: 0, nsec: 0)) }
        let names = xattrs.map(\.name), otherNames = other.xattrs.map(\.name)
        if names != otherNames {
            d.append("xattr names: expected \(names), got \(otherNames)")
        } else {
            for (a, b) in zip(xattrs, other.xattrs) where a.value != b.value {
                d.append("xattr \(a.name): value differs (\(a.value.count) vs \(b.value.count) bytes)")
            }
        }
        if !ignoreACL { check("ACL", acl ?? "(none)", other.acl ?? "(none)") }
        if let p = protectionClass, let q = other.protectionClass { check("data protection class", p, q) }
        return d
    }

    static func readXattrs(_ path: String) throws -> [XAttr] {
        let len = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        if len < 0 {
            if errno == ENOTSUP || errno == EPERM { return [] }
            throw posixFailure("listxattr", path)
        }
        if len == 0 { return [] }
        var names = [CChar](repeating: 0, count: len)
        let got = listxattr(path, &names, len, XATTR_NOFOLLOW)
        if got < 0 { throw posixFailure("listxattr", path) }
        var result: [XAttr] = []
        var start = 0
        for i in 0..<got where names[i] == 0 {
            let name = names[start..<i].withUnsafeBufferPointer { String(cString: Array($0) + [0]) }
            start = i + 1
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            if size < 0 { throw posixFailure("getxattr \(name) on", path) }
            var data = Data(count: size)
            if size > 0 {
                let n = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
                if n < 0 { throw posixFailure("getxattr \(name) on", path) }
                data = data.prefix(n)
            }
            result.append(XAttr(name: name, value: data))
        }
        return result.sorted { $0.name < $1.name }
    }

    static func readACL(_ path: String) throws -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP || errno == EINVAL { return nil }
            throw posixFailure("acl_get_link_np", path)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var len = 0
        guard let text = acl_to_text(acl, &len) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    /// Applies this snapshot to an open file. Data and size are not touched.
    /// Returns a list of failures (empty on success).
    /// An ACL that denies delete would stop the replacement from being renamed
    /// into place, so such ACLs are applied after the rename.
    var aclBlocksRename: Bool { (acl ?? "").contains(":deny:") }

    func apply(toFD fd: Int32, deferFlags: UInt32, deferACL: Bool = false) -> [String] {
        var failures: [String] = []

        // 1. Replace extended attributes (a clone starts with the base file's).
        let len = flistxattr(fd, nil, 0, 0)
        if len > 0 {
            var names = [CChar](repeating: 0, count: len)
            let got = flistxattr(fd, &names, len, 0)
            var start = 0
            for i in 0..<max(got, 0) where names[i] == 0 {
                let name = names[start..<i].withUnsafeBufferPointer { String(cString: Array($0) + [0]) }
                start = i + 1
                if fremovexattr(fd, name, 0) != 0 { failures.append("remove xattr \(name): \(errnoString())") }
            }
        }
        for x in xattrs {
            let r = x.value.withUnsafeBytes { fsetxattr(fd, x.name, $0.baseAddress, x.value.count, 0, 0) }
            if r != 0 { failures.append("set xattr \(x.name): \(errnoString())") }
        }

        // 2. Owner, group, mode.
        var st = stat()
        if fstat(fd, &st) != 0 || st.st_uid != uid || st.st_gid != gid {
            if fchown(fd, uid, gid) != 0 { failures.append("set owner \(uid):\(gid): \(errnoString())") }
        }
        if fchmod(fd, mode & 0o7777) != 0 { failures.append("set mode \(String(mode & 0o7777, radix: 8)): \(errnoString())") }

        // 3. Data protection class (only if it differs; usually it doesn't).
        if let want = protectionClass {
            let have = fcntl(fd, F_GETPROTECTIONCLASS)
            if have != want, fcntl(fd, F_SETPROTECTIONCLASS, want) != 0 {
                failures.append("set data protection class \(want): \(errnoString())")
            }
        }

        // 4. Times. Done before the ACL because a deny-writeattr ACL would block it.
        var cr = crtime.timespec, m = mtime.timespec, a = atime.timespec, bk = bkuptime.timespec
        var added = addedtime?.timespec ?? timespec()
        let r = addedtime == nil
            ? capfs_fset_times(fd, &cr, &m, &a, &bk, nil)
            : capfs_fset_times(fd, &cr, &m, &a, &bk, &added)
        if r != 0 { failures.append("set times: \(errnoString())") }

        // 5. ACL (an empty ACL removes one inherited from the directory).
        if let f = applyACL(toFD: fd, deferACL ? nil : acl) { failures.append(f) }

        // 6. Flags last (minus anything that would block the rename).
        if fchflags(fd, flags & ~deferFlags) != 0 {
            failures.append("set flags 0x\(String(flags, radix: 16)): \(errnoString())")
        }
        return failures
    }
}

/// Sets (or with nil, clears) the extended ACL. Returns an error message on failure.
func applyACL(toFD fd: Int32, _ text: String?) -> String? {
    guard let a = text.map({ acl_from_text($0) }) ?? acl_init(0) else { return "parse ACL: \(errnoString())" }
    defer { acl_free(UnsafeMutableRawPointer(a)) }
    return acl_set_fd_np(fd, a, ACL_TYPE_EXTENDED) == 0 ? nil : "set ACL: \(errnoString())"
}

func canAssignGroup(_ gid: UInt32) -> Bool {
    isRoot || myGroups.contains(gid) || capfs_is_member_of_group(geteuid(), gid) == 1
}
