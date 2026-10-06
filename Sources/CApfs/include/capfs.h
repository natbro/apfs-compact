#ifndef CAPFS_H
#define CAPFS_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <time.h>

/* Everything we know about one file system object (never follows symlinks). */
typedef struct {
    /* from lstat */
    int32_t  dev;
    uint64_t ino;
    uint16_t mode;          /* includes S_IFMT bits */
    uint32_t nlink;
    uint32_t uid;
    uint32_t gid;
    uint32_t flags;         /* st_flags (chflags) */
    int64_t  size;          /* logical size of the data fork */
    int64_t  alloc;         /* st_blocks * 512 (what `du` reports) */
    struct timespec atime;
    struct timespec mtime;
    struct timespec ctime;
    struct timespec birthtime;

    /* from getattrlist (common attributes) */
    struct timespec crtime;
    struct timespec bkuptime;
    struct timespec addedtime;
    uint32_t document_id;
    uint32_t protection_flags;
    int has_addedtime;
    int has_document_id;
    int has_protection;

    /* from getattrlist (extended common attributes, APFS) */
    int64_t  private_size;  /* bytes that would be freed immediately if this file were deleted */
    uint64_t clone_id;      /* identical for pure clones */
    uint64_t ext_flags;     /* EF_* */
    uint32_t clone_refcnt;  /* number of full clones sharing all blocks (including this one) */
    int has_private_size;
    int has_clone_id;
    int has_ext_flags;
    int has_clone_refcnt;
} capfs_info;

typedef struct {
    uint32_t bsize;
    uint64_t avail_bytes;
    uint64_t free_bytes;
    uint64_t total_bytes;
    int32_t  fsid0;
    int32_t  fsid1;
    int supports_clone;
    char fstype[16];
    char mntonname[1024];
    char mntfromname[1024];
} capfs_vol;

/* Returns 0 on success, -1 with errno set on failure. */
int capfs_get_info(const char *path, capfs_info *out);

/* Set crtime, mtime, atime, bkuptime and (optionally) addedtime on an open fd. */
int capfs_fset_times(int fd,
                     const struct timespec *crtime,
                     const struct timespec *mtime,
                     const struct timespec *atime,
                     const struct timespec *bkuptime,
                     const struct timespec *addedtime /* may be NULL */);

/* Set only mtime+atime on a path (no follow). Used to restore directory times. */
int capfs_set_mtime_atime(const char *path, const struct timespec *mtime, const struct timespec *atime);

/* Set only atime on a path (no follow). */
int capfs_set_atime(const char *path, const struct timespec *atime);

int capfs_vol_info(const char *path, capfs_vol *out);

/* 64-bit non-cryptographic hash (XXH64 algorithm). */
uint64_t capfs_hash64(const void *data, size_t len, uint64_t seed);

/* Compare `len` bytes of a and b in chunks of `chunk` bytes. Writes 1/0 into
   `differs[i]` for each chunk (the last chunk may be partial). Returns the
   number of differing chunks. */
size_t capfs_chunk_diff(const void *a, const void *b, size_t len, size_t chunk, uint8_t *differs);

/* Returns 1 if every byte in buf is zero. */
int capfs_is_zero(const void *buf, size_t len);

/* 1 if uid is a member of gid (directory services aware), 0 if not, -1 on error. */
int capfs_is_member_of_group(uint32_t uid, uint32_t gid);

/* Physical mapping of the file range starting at `offset`: on success stores
   the device offset and the number of contiguous bytes from there. Returns 0,
   or -1 (errno) if the range is a hole or the mapping is unavailable. */
int capfs_log2phys(int fd, int64_t offset, int64_t length, int64_t *devoffset, int64_t *contig);

#endif
