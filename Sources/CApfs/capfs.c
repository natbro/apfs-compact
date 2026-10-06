#include "capfs.h"

#include <errno.h>
#include <membership.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/stat.h>

/* ---- file info ------------------------------------------------------------ */

/* Attribute buffers are packed in the order of the attribute bits. With
   FSOPT_PACK_INVAL_ATTRS, unsupported attributes still occupy their slot, so
   the layout is fixed and ATTR_CMN_RETURNED_ATTRS tells us which are valid. */
typedef struct {
    uint32_t length;
    attribute_set_t returned;
    struct timespec crtime;      /* ATTR_CMN_CRTIME      0x00000200 */
    struct timespec bkuptime;    /* ATTR_CMN_BKUPTIME    0x00002000 */
    uint32_t document_id;        /* ATTR_CMN_DOCUMENT_ID 0x00100000 */
    struct timespec addedtime;   /* ATTR_CMN_ADDEDTIME   0x10000000 */
    uint32_t protection_flags;   /* ATTR_CMN_DATA_PROTECT_FLAGS 0x40000000 */
} __attribute__((packed)) cmn_buf;

typedef struct {
    uint32_t length;
    attribute_set_t returned;
    off_t private_size;          /* ATTR_CMNEXT_PRIVATESIZE  0x008 */
    uint64_t clone_id;           /* ATTR_CMNEXT_CLONEID      0x100 */
    uint64_t ext_flags;          /* ATTR_CMNEXT_EXT_FLAGS    0x200 */
    uint32_t clone_refcnt;       /* ATTR_CMNEXT_CLONE_REFCNT 0x1000 */
} __attribute__((packed)) ext_buf;

int capfs_get_info(const char *path, capfs_info *out) {
    memset(out, 0, sizeof(*out));

    struct stat st;
    if (lstat(path, &st) != 0) return -1;
    out->dev = st.st_dev;
    out->ino = st.st_ino;
    out->mode = st.st_mode;
    out->nlink = st.st_nlink;
    out->uid = st.st_uid;
    out->gid = st.st_gid;
    out->flags = st.st_flags;
    out->size = st.st_size;
    out->alloc = (int64_t)st.st_blocks * 512;
    out->atime = st.st_atimespec;
    out->mtime = st.st_mtimespec;
    out->ctime = st.st_ctimespec;
    out->birthtime = st.st_birthtimespec;
    out->crtime = st.st_birthtimespec;

    struct attrlist al;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_CRTIME | ATTR_CMN_BKUPTIME |
                    ATTR_CMN_DOCUMENT_ID | ATTR_CMN_ADDEDTIME | ATTR_CMN_DATA_PROTECT_FLAGS;
    cmn_buf cb;
    memset(&cb, 0, sizeof(cb));
    if (getattrlist(path, &al, &cb, sizeof(cb), FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS) == 0) {
        if (cb.returned.commonattr & ATTR_CMN_CRTIME) out->crtime = cb.crtime;
        if (cb.returned.commonattr & ATTR_CMN_BKUPTIME) out->bkuptime = cb.bkuptime;
        if (cb.returned.commonattr & ATTR_CMN_DOCUMENT_ID) {
            out->document_id = cb.document_id;
            out->has_document_id = 1;
        }
        if (cb.returned.commonattr & ATTR_CMN_ADDEDTIME) {
            out->addedtime = cb.addedtime;
            out->has_addedtime = 1;
        }
        if (cb.returned.commonattr & ATTR_CMN_DATA_PROTECT_FLAGS) {
            out->protection_flags = cb.protection_flags;
            out->has_protection = 1;
        }
    }

    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS;
    al.forkattr = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS |
                  ATTR_CMNEXT_CLONE_REFCNT;
    ext_buf eb;
    memset(&eb, 0, sizeof(eb));
    if (getattrlist(path, &al, &eb, sizeof(eb),
                    FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS | FSOPT_ATTR_CMN_EXTENDED) == 0) {
        if (eb.returned.forkattr & ATTR_CMNEXT_PRIVATESIZE) {
            out->private_size = eb.private_size;
            out->has_private_size = 1;
        }
        if (eb.returned.forkattr & ATTR_CMNEXT_CLONEID) {
            out->clone_id = eb.clone_id;
            out->has_clone_id = 1;
        }
        if (eb.returned.forkattr & ATTR_CMNEXT_EXT_FLAGS) {
            out->ext_flags = eb.ext_flags;
            out->has_ext_flags = 1;
        }
        if (eb.returned.forkattr & ATTR_CMNEXT_CLONE_REFCNT) {
            out->clone_refcnt = eb.clone_refcnt;
            out->has_clone_refcnt = 1;
        }
    }
    return 0;
}

/* ---- setting times -------------------------------------------------------- */

int capfs_fset_times(int fd,
                     const struct timespec *crtime,
                     const struct timespec *mtime,
                     const struct timespec *atime,
                     const struct timespec *bkuptime,
                     const struct timespec *addedtime) {
    struct attrlist al;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME | ATTR_CMN_BKUPTIME;
    struct {
        struct timespec t[5];
    } __attribute__((packed)) buf;
    buf.t[0] = *crtime;
    buf.t[1] = *mtime;
    buf.t[2] = *atime;
    buf.t[3] = *bkuptime;
    size_t len = 4 * sizeof(struct timespec);
    if (addedtime) {
        al.commonattr |= ATTR_CMN_ADDEDTIME;
        buf.t[4] = *addedtime;
        len += sizeof(struct timespec);
    }
    return fsetattrlist(fd, &al, &buf, len, 0);
}

int capfs_set_mtime_atime(const char *path, const struct timespec *mtime, const struct timespec *atime) {
    struct attrlist al;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME;
    struct {
        struct timespec m, a;
    } __attribute__((packed)) buf = {*mtime, *atime};
    return setattrlist(path, &al, &buf, sizeof(buf), FSOPT_NOFOLLOW);
}

int capfs_set_atime(const char *path, const struct timespec *atime) {
    struct attrlist al;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_ACCTIME;
    struct timespec a = *atime;
    return setattrlist(path, &al, &a, sizeof(a), FSOPT_NOFOLLOW);
}

/* ---- volume info ---------------------------------------------------------- */

typedef struct {
    uint32_t length;
    vol_capabilities_attr_t caps;
} __attribute__((packed)) vol_caps_buf;

int capfs_vol_info(const char *path, capfs_vol *out) {
    memset(out, 0, sizeof(*out));
    struct statfs sf;
    if (statfs(path, &sf) != 0) return -1;
    out->bsize = sf.f_bsize;
    out->avail_bytes = (uint64_t)sf.f_bavail * sf.f_bsize;
    out->free_bytes = (uint64_t)sf.f_bfree * sf.f_bsize;
    out->total_bytes = (uint64_t)sf.f_blocks * sf.f_bsize;
    out->fsid0 = sf.f_fsid.val[0];
    out->fsid1 = sf.f_fsid.val[1];
    strlcpy(out->fstype, sf.f_fstypename, sizeof(out->fstype));
    strlcpy(out->mntonname, sf.f_mntonname, sizeof(out->mntonname));
    strlcpy(out->mntfromname, sf.f_mntfromname, sizeof(out->mntfromname));

    struct attrlist al;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.volattr = ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES;
    vol_caps_buf vb;
    memset(&vb, 0, sizeof(vb));
    if (getattrlist(sf.f_mntonname, &al, &vb, sizeof(vb), 0) == 0) {
        uint32_t valid = vb.caps.valid[VOL_CAPABILITIES_INTERFACES];
        uint32_t caps = vb.caps.capabilities[VOL_CAPABILITIES_INTERFACES];
        out->supports_clone = (valid & VOL_CAP_INT_CLONE) && (caps & VOL_CAP_INT_CLONE);
    }
    return 0;
}

/* ---- hashing (XXH64) ------------------------------------------------------ */

#define P1 0x9E3779B185EBCA87ULL
#define P2 0xC2B2AE3D27D4EB4FULL
#define P3 0x165667B19E3779F9ULL
#define P4 0x85EBCA77C2B2AE63ULL
#define P5 0x27D4EB2F165667C5ULL

static inline uint64_t rotl64(uint64_t x, int r) { return (x << r) | (x >> (64 - r)); }
static inline uint64_t rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static inline uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static inline uint64_t xround(uint64_t acc, uint64_t input) {
    acc += input * P2;
    acc = rotl64(acc, 31);
    return acc * P1;
}
static inline uint64_t xmerge(uint64_t acc, uint64_t val) {
    acc ^= xround(0, val);
    return acc * P1 + P4;
}

uint64_t capfs_hash64(const void *data, size_t len, uint64_t seed) {
    const uint8_t *p = (const uint8_t *)data;
    const uint8_t *end = p + len;
    uint64_t h;
    if (len >= 32) {
        const uint8_t *limit = end - 32;
        uint64_t v1 = seed + P1 + P2, v2 = seed + P2, v3 = seed, v4 = seed - P1;
        do {
            v1 = xround(v1, rd64(p)); p += 8;
            v2 = xround(v2, rd64(p)); p += 8;
            v3 = xround(v3, rd64(p)); p += 8;
            v4 = xround(v4, rd64(p)); p += 8;
        } while (p <= limit);
        h = rotl64(v1, 1) + rotl64(v2, 7) + rotl64(v3, 12) + rotl64(v4, 18);
        h = xmerge(h, v1);
        h = xmerge(h, v2);
        h = xmerge(h, v3);
        h = xmerge(h, v4);
    } else {
        h = seed + P5;
    }
    h += (uint64_t)len;
    while (p + 8 <= end) {
        h ^= xround(0, rd64(p));
        h = rotl64(h, 27) * P1 + P4;
        p += 8;
    }
    if (p + 4 <= end) {
        h ^= (uint64_t)rd32(p) * P1;
        h = rotl64(h, 23) * P2 + P3;
        p += 4;
    }
    while (p < end) {
        h ^= (*p) * P5;
        h = rotl64(h, 11) * P1;
        p++;
    }
    h ^= h >> 33;
    h *= P2;
    h ^= h >> 29;
    h *= P3;
    h ^= h >> 32;
    return h;
}

size_t capfs_chunk_diff(const void *a, const void *b, size_t len, size_t chunk, uint8_t *differs) {
    const uint8_t *pa = a, *pb = b;
    size_t n = 0, i = 0;
    for (size_t off = 0; off < len; off += chunk, i++) {
        size_t l = len - off < chunk ? len - off : chunk;
        int d = memcmp(pa + off, pb + off, l) != 0;
        differs[i] = (uint8_t)d;
        n += d;
    }
    return n;
}

int capfs_is_zero(const void *buf, size_t len) {
    const uint8_t *p = buf;
    size_t i = 0;
    for (; i + 8 <= len; i += 8) {
        uint64_t v;
        memcpy(&v, p + i, 8);
        if (v) return 0;
    }
    for (; i < len; i++)
        if (p[i]) return 0;
    return 1;
}

int capfs_is_member_of_group(uint32_t uid, uint32_t gid) {
    uuid_t u, g;
    int member = 0;
    if (mbr_uid_to_uuid(uid, u) != 0 || mbr_gid_to_uuid(gid, g) != 0) return -1;
    if (mbr_check_membership(u, g, &member) != 0) return -1;
    return member ? 1 : 0;
}

int capfs_log2phys(int fd, int64_t offset, int64_t length, int64_t *devoffset, int64_t *contig) {
    struct log2phys l2p;
    memset(&l2p, 0, sizeof(l2p));
    l2p.l2p_contigbytes = length;
    l2p.l2p_devoffset = offset;
    if (fcntl(fd, F_LOG2PHYS_EXT, &l2p) == -1) return -1;
    *devoffset = l2p.l2p_devoffset;
    *contig = l2p.l2p_contigbytes;
    return 0;
}
