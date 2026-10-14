/*
 * Eigener Ersatz fuer das private <UserFS/UserVFS.h> (nicht im SDK).
 * Aus der Nutzung in livefiles_hfs_plugin rekonstruiert, NICHT Apples Header:
 * Layout/Zahlenwerte sind eigene Festlegungen und nur zwischen Plugin und
 * lifs_cli konsistent. Inventar: macos/livefiles_shim/INVENTAR.md
 */
#ifndef LIVEFILES_SHIM_USERVFS_H
#define LIVEFILES_SHIM_USERVFS_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>

/* ---- opake Knoten ---- */
typedef void *UVFSFileNode;
typedef void *UVFSStreamNode;
typedef uint32_t UVFSVolumeId;

/* ---- Dateiattribute ---- */
enum {
    UVFS_FA_TYPE_INVALID = 0,
    UVFS_FA_TYPE_FILE    = 1,
    UVFS_FA_TYPE_DIR     = 2,
    UVFS_FA_TYPE_SYMLINK = 3,
};

#define UVFS_FA_VALID_TYPE       (1ULL << 0)
#define UVFS_FA_VALID_MODE       (1ULL << 1)
#define UVFS_FA_VALID_NLINK      (1ULL << 2)
#define UVFS_FA_VALID_UID        (1ULL << 3)
#define UVFS_FA_VALID_GID        (1ULL << 4)
#define UVFS_FA_VALID_BSD_FLAGS  (1ULL << 5)
#define UVFS_FA_VALID_SIZE       (1ULL << 6)
#define UVFS_FA_VALID_ALLOCSIZE  (1ULL << 7)
#define UVFS_FA_VALID_FILEID     (1ULL << 8)
#define UVFS_FA_VALID_PARENTID   (1ULL << 9)
#define UVFS_FA_VALID_ATIME      (1ULL << 10)
#define UVFS_FA_VALID_MTIME      (1ULL << 11)
#define UVFS_FA_VALID_CTIME      (1ULL << 12)
#define UVFS_FA_VALID_BIRTHTIME  (1ULL << 13)
#define UVFS_FA_VALID_BACKUPTIME (1ULL << 14)
#define LI_FA_VALID_BSD_FLAGS    UVFS_FA_VALID_BSD_FLAGS

/* Modus-Bits: eigene Zaehlung, rwx je Klasse (wie POSIX-Permission-Bits) */
#define UVFS_FA_MODE_R   0x4
#define UVFS_FA_MODE_W   0x2
#define UVFS_FA_MODE_X   0x1
#define UVFS_FA_MODE_RWX 0x7
#define UVFS_FA_MODE_OTH(m) ((m) << 0)
#define UVFS_FA_MODE_GRP(m) ((m) << 3)
#define UVFS_FA_MODE_USR(m) ((m) << 6)

typedef struct UVFSFileAttributes {
    uint64_t        fa_validmask;
    uint32_t        fa_type;
    uint32_t        fa_mode;
    uint32_t        fa_nlink;
    uint32_t        fa_uid;
    uint32_t        fa_gid;
    uint32_t        fa_bsd_flags;
    uint64_t        fa_size;
    uint64_t        fa_allocsize;
    uint64_t        fa_fileid;
    uint64_t        fa_parentid;
    struct timespec fa_atime;
    struct timespec fa_mtime;
    struct timespec fa_ctime;
    struct timespec fa_birthtime;
    struct timespec fa_backuptime;
} UVFSFileAttributes;

/* ---- Verzeichniseintraege ---- */
#define UVFS_DIRCOOKIE_FIRST            0ULL
#define UVFS_DIRCOOKIE_EOF              (~0ULL)
#define UVFS_DIRCOOKIE_VERIFIER_INITIAL 0ULL

#define UVFS_READDIR_EOF_REACHED   (-1)
#define UVFS_READDIR_BAD_COOKIE    (-2)
#define UVFS_SCANVOLS_EOF_REACHED  (-3)
#define UVFS_READ_ONLY             (-4)

#define _UVFS_ALIGN8(x) (((x) + 7u) & ~7u)

typedef struct UVFSDirEntry {
    uint64_t de_nextcookie;
    uint64_t de_fileid;
    uint8_t  de_filetype;
    uint8_t  de_namelen;
    union { uint16_t de_reclen; uint16_t de_nextrec; };
    char     de_name[];
} UVFSDirEntry;
#define UVFS_DIRENTRY_RECLEN(namelen) \
    ((uint16_t)_UVFS_ALIGN8(sizeof(UVFSDirEntry) + (namelen) + 1))

typedef struct UVFSDirEntryAttr {
    uint64_t           dea_nextcookie;
    uint16_t           dea_nextrec;
    uint16_t           dea_spare0;
    uint16_t           dea_nameoff;
    uint16_t           dea_namelen;
    UVFSFileAttributes dea_attrs;
} UVFSDirEntryAttr;
#define UVFS_DIRENTRYATTR_NAMEOFF ((uint16_t)sizeof(UVFSDirEntryAttr))
#define UVFS_DIRENTRYATTR_NAMEPTR(e) ((char *)(e) + (e)->dea_nameoff)
#define _UVFS_DIRENTRYATTR_RECLEN(nameoff, namelen) \
    ((uint16_t)_UVFS_ALIGN8((nameoff) + (namelen) + 1))
#define UVFS_DIRENTRYATTR_RECLEN(e, namelen) \
    _UVFS_DIRENTRYATTR_RECLEN((e)->dea_nameoff, namelen)

/* ---- Volumes ---- */
#define UVFS_SCANVOLS_VOLNAME_MAX 256
typedef enum { UAC_UNLOCKED = 0, UAC_LOCKED = 1 } UVFSAccessControl;
typedef struct UVFSScanVolsRequest { uint32_t sr_volid; } UVFSScanVolsRequest;
typedef struct UVFSScanVolsReply {
    uint32_t sr_volid;
    uint32_t sr_volac;
    char     sr_volname[UVFS_SCANVOLS_VOLNAME_MAX];
} UVFSScanVolsReply;
typedef struct UVFSVolumeCredential { uint8_t vc_opaque[64]; } UVFSVolumeCredential;

typedef uint32_t UVFSMountFlags;
#define UVFS_MOUNT_RDONLY 0x1u
typedef enum { UVFSUnmountHintNone = 0, UVFSUnmountHintForce = 1 } UVFSUnmountHint;
typedef enum { QUICK_CHECK = 0, CHECK = 1, CHECK_AND_REPAIR = 2 } check_flags_t;

/* ---- xattr ---- */
typedef enum { UVFSXattrHowSet = 1, UVFSXattrHowCreate, UVFSXattrHowReplace, UVFSXattrHowRemove } UVFSXattrHow;

/* ---- FS-Attribute (getfsattr/setfsattr): Namen sind Strings ---- */
#define UVFS_FSATTR_PC_LINK_MAX        "_PC_LINK_MAX"
#define UVFS_FSATTR_PC_NAME_MAX        "_PC_NAME_MAX"
#define UVFS_FSATTR_PC_NO_TRUNC        "_PC_NO_TRUNC"
#define UVFS_FSATTR_PC_FILESIZEBITS    "_PC_FILESIZEBITS"
#define UVFS_FSATTR_PC_XATTR_SIZE_BITS "_PC_XATTR_SIZE_BITS"
#define UVFS_FSATTR_BLOCKSIZE          "FSAttrBlockSize"
#define UVFS_FSATTR_IOSIZE             "FSAttrIOSize"
#define UVFS_FSATTR_TOTALBLOCKS        "FSAttrTotalBlocks"
#define UVFS_FSATTR_BLOCKSFREE         "FSAttrBlocksFree"
#define UVFS_FSATTR_BLOCKSAVAIL        "FSAttrBlocksAvail"
#define UVFS_FSATTR_BLOCKSUSED         "FSAttrBlocksUsed"
#define UVFS_FSATTR_CNAME              "FSAttrCName"
#define UVFS_FSATTR_FSTYPENAME         "FSAttrFSTypeName"
#define UVFS_FSATTR_FSSUBTYPE          "FSAttrFSSubType"
#define UVFS_FSATTR_FSSUBTYPENUM       "FSAttrFSSubTypeNum"
#define UVFS_FSATTR_VOLNAME            "FSAttrVolName"
#define UVFS_FSATTR_VOLUUID            "FSAttrVolUUID"
#define UVFS_FSATTR_CAPS_FORMAT        "FSAttrCapsFormat"
#define UVFS_FSATTR_CAPS_INTERFACES    "FSAttrCapsInterfaces"
#define UVFS_FSATTR_LAST_MTIME         "FSAttrLastMTime"
#define UVFS_FSATTR_MOUNT_TIME         "FSAttrMountTime"
#define UVFS_FSATTR_MOUNTFLAGS         "FSAttrMountFlags"
#define LI_FSATTR_PREALLOCATE          "LIFSAttrPreallocate"
#define LI_FSATTR_VOLNAME              "LIFSAttrVolName"
#define LI_MNT_SUPPORT_OPEN_UNLINK     0x1ULL

typedef struct UVFSFSAttributeValue {
    union {
        uint64_t fsa_number;
        bool     fsa_bool;
        char     fsa_string[0];
        uint8_t  fsa_opaque[0];
    };
} UVFSFSAttributeValue;

/* ---- Preallocate ---- */
#define LI_PREALLOCATE_ALLOCATECONTIG   0x1
#define LI_PREALLOCATE_ALLOCATEALL      0x2
#define LI_PREALLOCATE_ALLOCATEFROMVOL  0x4
typedef struct LIFilePreallocateArgs {
    uint32_t flags;
    int64_t  offset;
    int64_t  length;
    int64_t  bytesallocated;
} LIFilePreallocateArgs_t;

/* ---- scandir / scanids ---- */
#define SEARCH_RESULT_MATCH 0x1
#define SEARCH_RESULT_PUSH  0x2
typedef struct scandir_matching_request {
    UVFSFileAttributes *smr_attribute_filter;
    char              **smr_filename_contains;
    char              **smr_filename_ends_with;
    uint64_t            smr_start_cookie;
    uint64_t            smr_verifier;
} scandir_matching_request_t;
typedef struct scandir_matching_reply {
    int               smr_result_type;
    uint64_t          smr_verifier;
    UVFSDirEntryAttr *smr_entry;
} scandir_matching_reply_t;
typedef void (^scanids_match_block_t)(unsigned int fileid_index, const UVFSFileAttributes *file_attrs, const char *file_name);

/* ---- Betriebstabelle ---- */
#define UVFS_FSOPS_VERSION_CURRENT 1
typedef struct UVFSFSOps {
    uint32_t fsops_version;
    int  (*fsops_init)(void);
    void (*fsops_fini)(void);
    int  (*fsops_taste)(int fd);
    int  (*fsops_scanvols)(int fd, UVFSScanVolsRequest *rq, UVFSScanVolsReply *rp);
    int  (*fsops_mount)(int fd, UVFSVolumeId volid, UVFSMountFlags flags, UVFSVolumeCredential *creds, UVFSFileNode *root);
    int  (*fsops_sync)(UVFSFileNode node);
    int  (*fsops_unmount)(UVFSFileNode root, UVFSUnmountHint hint);
    int  (*fsops_getfsattr)(UVFSFileNode node, const char *attr, UVFSFSAttributeValue *val, size_t len, size_t *retlen);
    int  (*fsops_setfsattr)(UVFSFileNode node, const char *attr, const UVFSFSAttributeValue *val, size_t len, UVFSFSAttributeValue *out, size_t outlen);
    int  (*fsops_getattr)(UVFSFileNode node, UVFSFileAttributes *out);
    int  (*fsops_setattr)(UVFSFileNode node, const UVFSFileAttributes *set, UVFSFileAttributes *out);
    int  (*fsops_lookup)(UVFSFileNode dir, const char *name, UVFSFileNode *out);
    int  (*fsops_reclaim)(UVFSFileNode node, unsigned int flags);
    int  (*fsops_readlink)(UVFSFileNode node, void *buf, size_t sz, size_t *actual, UVFSFileAttributes *out);
    int  (*fsops_read)(UVFSFileNode node, uint64_t off, size_t len, void *buf, size_t *actual);
    int  (*fsops_write)(UVFSFileNode node, uint64_t off, size_t len, const void *buf, size_t *actual);
    int  (*fsops_create)(UVFSFileNode dir, const char *name, const UVFSFileAttributes *attr, UVFSFileNode *out);
    int  (*fsops_mkdir)(UVFSFileNode dir, const char *name, const UVFSFileAttributes *attr, UVFSFileNode *out);
    int  (*fsops_symlink)(UVFSFileNode dir, const char *name, const char *content, const UVFSFileAttributes *attr, UVFSFileNode *out);
    int  (*fsops_remove)(UVFSFileNode dir, const char *name, UVFSFileNode victim);
    int  (*fsops_rmdir)(UVFSFileNode dir, const char *name, UVFSFileNode victim);
    int  (*fsops_rename)(UVFSFileNode fdir, UVFSFileNode fnode, const char *fname, UVFSFileNode tdir, UVFSFileNode tnode, const char *tname, uint32_t flags);
    int  (*fsops_readdir)(UVFSFileNode dir, void *buf, size_t len, uint64_t cookie, size_t *actual, uint64_t *verifier);
    int  (*fsops_readdirattr)(UVFSFileNode dir, void *buf, size_t len, uint64_t cookie, size_t *actual, uint64_t *verifier);
    int  (*fsops_link)(UVFSFileNode from, UVFSFileNode todir, const char *toname, UVFSFileAttributes *outf, UVFSFileAttributes *outd);
    int  (*fsops_check)(int fd, UVFSVolumeId volid, UVFSVolumeCredential *creds, check_flags_t how);
    int  (*fsops_getxattr)(UVFSFileNode node, const char *attr, void *buf, size_t sz, size_t *actual);
    int  (*fsops_setxattr)(UVFSFileNode node, const char *attr, const void *buf, size_t sz, UVFSXattrHow how);
    int  (*fsops_listxattr)(UVFSFileNode node, void *buf, size_t sz, size_t *actual);
    int  (*fsops_scandir)(UVFSFileNode dir, scandir_matching_request_t *rq, scandir_matching_reply_t *rp);
    int  (*fsops_scanids)(UVFSFileNode node, uint64_t attrs, const uint64_t *ids, unsigned int count, scanids_match_block_t cb);
    int  (*fsops_stream_lookup)(UVFSFileNode node, UVFSStreamNode *out);
    int  (*fsops_stream_reclaim)(UVFSStreamNode node);
    int  (*fsops_stream_read)(UVFSStreamNode node, uint64_t off, size_t len, void *buf, size_t *actual);
} UVFSFSOps;

#endif
