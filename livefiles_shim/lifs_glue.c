/* Siehe lifs_glue.h. Wird mit den Vendor-Flags gebaut (pwrite/ioctl-Umleitung), braucht Apples interne Header. */
#include "lifs_glue.h"
#include "lf_hfs.h"
#include "lf_hfs_vnode.h"
#include "lf_hfs_journal.h"
#include "lf_hfs_vfsutils.h"
#include "lf_hfs_dirops_handler.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/attr.h>
#include <CommonCrypto/CommonDigest.h>
#include <System/uuid/namespace.h>

#define OPS HFS_fsOps
static uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static uint64_t be64(const uint8_t *p) { return (uint64_t)be32(p) << 32 | be32(p + 4); }
static uint64_t le64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }

int lifs_prepare_volume(int fd)
{
    uint8_t vh[512], jib[512], jh[512];
    if (lifs_dev_pread(fd, vh, 512, 1024) != 512) return -EIO;
    uint16_t sig = be16(vh);
    if (sig != 0x482B && sig != 0x4858) return 0;                 /* kein HFS+/HFSX */
    if (!(be32(vh + 4) & 0x2000)) return 0;                       /* nicht journaled */
    if (!memcmp(vh + 8, "HFSJ", 4)) return 0;
    uint32_t bs = be32(vh + 40);
    if (bs < 512) return 0;
    if (lifs_dev_pread(fd, jib, 512, (off_t)be32(vh + 12) * bs) != 512) return -EIO;
    if (!(be32(jib) & 1)) return 0;                               /* Journal nicht auf dem Volume */
    if (!(be32(jib) & 4)) {                                       /* Bit 2 = "needs init" (frisch newfs): Journal noch gar nicht benutzt, leer */
        if (lifs_dev_pread(fd, jh, 512, (off_t)be64(jib + 36)) != 512) return -EIO;
        if (jh[0] != 0x78 || jh[1] != 0x4c || jh[2] != 0x4e || jh[3] != 0x4a) return 0;   /* Magic 'JNLx' little endian */
        if (le64(jh + 8) != le64(jh + 16)) return 0;              /* Journal nicht leer: nicht anfassen, Plugin verwirft es */
    }
    memcpy(vh + 8, "HFSJ", 4);
    if (lifs_dev_pwrite(fd, vh, 512, 1024) != 512) return -EIO;
    int dk = 0; lifs_dev_ioctl(fd, DKIOCSYNCHRONIZE, &dk);
    return 1;
}

int lifs_unmount_clean(UVFSFileNode root)
{
    struct hfsmount *hfsmp = VTOHFS(((vnode_t)root));
    int err = OPS.fsops_sync(root);
    if (hfsmp->jnl) {                                             /* wie der Kernel: journal_close schreibt alles zurueck, start==end */
        hfs_flush(hfsmp, HFS_FLUSH_FULL);
        journal_close(hfsmp->jnl);
        hfsmp->jnl = NULL;
    }
    int e2 = OPS.fsops_unmount(root, UVFSUnmountHintNone);        /* ohne jnl schreibt LFHFS_Unmount den Volume-Header direkt */
    return err ? err : e2;
}

int lifs_readdir_chunk(UVFSFileNode dir, uint64_t cookie, uint64_t *verifier, int want_attrs, lifs_dirent_t *out, int maxn, int *n)
{
    *n = 0;
    size_t bsz = 16384, got = 0;
    uint8_t *buf = malloc(bsz);
    if (!buf) return ENOMEM;
    int r = want_attrs ? OPS.fsops_readdirattr(dir, buf, bsz, cookie, &got, verifier)
                       : OPS.fsops_readdir(dir, buf, bsz, cookie, &got, verifier);
    if (r || got == 0) { free(buf); return r ? r : EIO; }
    size_t off = 0;
    while (*n < maxn && off < got) {
        lifs_dirent_t *o = &out[*n];
        uint16_t rec; int more;
        if (want_attrs) {
            UVFSDirEntryAttr *e = (UVFSDirEntryAttr *)(buf + off);
            const char *nm = UVFS_DIRENTRYATTR_NAMEPTR(e);
            o->nextcookie = e->dea_nextcookie; o->attrs = e->dea_attrs; o->fileid = e->dea_attrs.fa_fileid; o->type = e->dea_attrs.fa_type;
            o->namelen = e->dea_namelen < sizeof o->name - 1 ? e->dea_namelen : sizeof o->name - 1; memcpy(o->name, nm, o->namelen);
            rec = e->dea_nextrec; more = rec != 0 && e->dea_nextcookie != UVFS_DIRCOOKIE_EOF;
            off += rec;
        } else {
            UVFSDirEntry *e = (UVFSDirEntry *)(buf + off);
            o->nextcookie = e->de_nextcookie; o->fileid = e->de_fileid; o->type = e->de_filetype;
            o->namelen = e->de_namelen; memcpy(o->name, e->de_name, o->namelen);
            rec = e->de_reclen; more = rec != 0 && e->de_nextcookie != UVFS_DIRCOOKIE_EOF;
            off += UVFS_DIRENTRY_RECLEN(strlen(e->de_name));
        }
        o->name[o->namelen] = 0;
        if (o->fileid != 0) (*n)++;                               /* fileid 0 = versteckt (Journal-Dateien) */
        if (!more) break;
    }
    free(buf);
    return 0;
}

static int fsattr_num(UVFSFileNode root, const char *a, uint64_t *v)
{
    UVFSFSAttributeValue val; size_t len = 0; memset(&val, 0, sizeof val);
    int r = OPS.fsops_getfsattr(root, a, &val, sizeof val, &len);
    if (!r) *v = val.fsa_number;
    return r;
}

int lifs_volinfo(UVFSFileNode root, lifs_volinfo_t *o)
{
    memset(o, 0, sizeof *o);
    int r = 0;
    r |= fsattr_num(root, UVFS_FSATTR_BLOCKSIZE, &o->blocksize);
    r |= fsattr_num(root, UVFS_FSATTR_TOTALBLOCKS, &o->total);
    r |= fsattr_num(root, UVFS_FSATTR_BLOCKSFREE, &o->free_);
    r |= fsattr_num(root, UVFS_FSATTR_BLOCKSAVAIL, &o->avail);
    fsattr_num(root, UVFS_FSATTR_CAPS_FORMAT, &o->caps_format);
    fsattr_num(root, UVFS_FSATTR_CAPS_INTERFACES, &o->caps_interfaces);
    union { UVFSFSAttributeValue v; char raw[512]; } u; size_t len = 0; memset(&u, 0, sizeof u);
    if (!OPS.fsops_getfsattr(root, UVFS_FSATTR_VOLNAME, &u.v, sizeof u.raw, &len)) strlcpy(o->name, u.v.fsa_string, sizeof o->name);
    return r;
}

#include <unistd.h>
#include "lf_hfs_cnode.h"
#include "lf_hfs_readwrite_ops.h"

static uint64_t default_journal_size(uint64_t vol_bytes)
{   /* Eigene Regel (Kernel-Formel nicht belegt): 8 MiB, ab 64 GiB vol/8192, hoechstens 512 MiB. Bis 16 GiB = diskutil/newfs (8 MiB gemessen). */
    uint64_t s = vol_bytes / 8192;
    if (s < (8u << 20)) s = 8u << 20;
    if (s > (512u << 20)) s = 512u << 20;
    return s;
}

static void be32w(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void be64w(uint8_t *p, uint64_t v) { be32w(p, (uint32_t)(v >> 32)); be32w(p + 4, (uint32_t)v); }

static int make_hidden(UVFSFileNode root, const char *name, UVFSFileNode *out)
{
    UVFSFileAttributes a; memset(&a, 0, sizeof a);
    a.fa_validmask = UVFS_FA_VALID_MODE | UVFS_FA_VALID_UID | UVFS_FA_VALID_GID;
    a.fa_mode = 0; a.fa_uid = geteuid(); a.fa_gid = getegid();       /* mode 100000 wie beim Kernel */
    int r = OPS.fsops_create(root, name, &a, out);
    if (r) return r;
    uint8_t fi[32] = {'j','r','n','l','h','f','s','+', 0x50, 0x00};   /* wie newfs_hfs: Typ jrnl, Ersteller hfs+, unsichtbar+gesperrt */
    return OPS.fsops_setxattr(*out, "com.apple.FinderInfo", fi, sizeof fi, UVFSXattrHowSet);
}

int lifs_enable_journal(UVFSFileNode root, uint64_t jsize)
{
    struct hfsmount *hfsmp = VTOHFS(((vnode_t)root));
    ExtendedVCB *vcb = HFSTOVCB(hfsmp);
    if (hfsmp->jnl || (vcb->vcbAtrb & kHFSVolumeJournaledMask)) return EEXIST;
    if (hfsmp->hfs_flags & HFS_READ_ONLY) return EROFS;
    uint32_t bs = vcb->blockSize;
    if (!jsize) jsize = default_journal_size((uint64_t)vcb->totalBlocks * bs);
    jsize = (jsize + bs - 1) / bs * bs;
    UVFSFileNode t = NULL, jn = NULL, ji = NULL; int r;
    if (!OPS.fsops_lookup(root, ".journal", &t)) { OPS.fsops_reclaim(t, 0); return EEXIST; }
    if (!OPS.fsops_lookup(root, ".journal_info_block", &t)) { OPS.fsops_reclaim(t, 0); return EEXIST; }

    /* 1. Journal: ein Extent, vorab zusammenhaengend belegt, dann Groesse setzen */
    if ((r = make_hidden(root, ".journal", &jn))) return r;
    union { UVFSFSAttributeValue v; LIFilePreallocateArgs_t a; char raw[64]; } rq, rs;
    memset(&rq, 0, sizeof rq); memset(&rs, 0, sizeof rs);
    rq.a.flags = LI_PREALLOCATE_ALLOCATECONTIG | LI_PREALLOCATE_ALLOCATEALL; rq.a.length = (int64_t)jsize;
    if ((r = OPS.fsops_setfsattr(jn, LI_FSATTR_PREALLOCATE, &rq.v, sizeof rq.a, &rs.v, sizeof rs.a))) goto undo;
    UVFSFileAttributes sa; memset(&sa, 0, sizeof sa); sa.fa_validmask = UVFS_FA_VALID_SIZE; sa.fa_size = jsize;
    UVFSFileAttributes out;
    if ((r = OPS.fsops_setattr(jn, &sa, &out))) goto undo;
    struct filefork *jf = VTOF(((vnode_t)jn));
    if (jf->ff_extents[0].blockCount * (uint64_t)bs < jsize || jf->ff_extents[1].blockCount != 0) { r = ENOSPC; goto undo; }   /* nicht zusammenhaengend */
    uint32_t jstart = jf->ff_extents[0].startBlock;

    /* 2. Journal-Info-Block: eine Allokationseinheit, Inhalt InFS|NeedInit + Ort/Groesse des Journals */
    if ((r = make_hidden(root, ".journal_info_block", &ji))) goto undo;
    uint8_t *blk = calloc(1, bs);
    if (!blk) { r = ENOMEM; goto undo; }
    be32w(blk, 0x5); be64w(blk + 36, (uint64_t)jstart * bs); be64w(blk + 44, jsize);
    size_t act = 0;
    r = OPS.fsops_write(ji, 0, bs, blk, &act); free(blk);
    if (r || act != bs) { if (!r) r = EIO; goto undo; }
    struct filefork *iff = VTOF(((vnode_t)ji));
    if (iff->ff_extents[0].blockCount != 1 || iff->ff_extents[1].blockCount != 0) { r = ENOSPC; goto undo; }
    uint32_t jibstart = iff->ff_extents[0].startBlock;

    /* 3. Volume-Header (wird von LFHFS_Unmount direkt geschrieben, Haupt- und Alternativ-Header) */
    vcb->vcbJinfoBlock = jibstart;
    vcb->vcbAtrb |= kHFSVolumeJournaledMask;
    OPS.fsops_reclaim(ji, 0); OPS.fsops_reclaim(jn, 0);
    return 0;
undo:
    if (ji) { OPS.fsops_remove(root, ".journal_info_block", ji); OPS.fsops_reclaim(ji, 0); }
    if (jn) { OPS.fsops_remove(root, ".journal", jn); OPS.fsops_reclaim(jn, 0); }
    return r;
}

int lifs_volume_uuid(const uint8_t *vh, uint8_t out[16])
{
    const uint8_t *raw = vh + 80 + 24;                              /* finderInfo[6..7] */
    if (be32(raw) == 0 || be32(raw + 4) == 0) { memset(out, 0, 16); return 1; }
    CC_MD5_CTX c; CC_MD5_Init(&c);
    CC_MD5_Update(&c, kFSUUIDNamespaceSHA1, 16); CC_MD5_Update(&c, raw, 8); CC_MD5_Final(out, &c);
    out[6] = (out[6] & 0x0F) | 0x30; out[8] = (out[8] & 0x3F) | 0x80;
    return 0;
}

int lifs_journal_dirty(int fd)
{
    uint8_t vh[512], jib[512], jh[512];
    if (lifs_dev_pread(fd, vh, 512, 1024) != 512) return -EIO;
    uint16_t sig = be16(vh);
    if ((sig != 0x482B && sig != 0x4858) || !(be32(vh + 4) & 0x2000)) return 0;
    uint32_t bs = be32(vh + 40);
    if (bs < 512) return 0;
    if (lifs_dev_pread(fd, jib, 512, (off_t)be32(vh + 12) * bs) != 512) return -EIO;
    if (!(be32(jib) & 1) || (be32(jib) & 4)) return 0;             /* extern oder "needs init": nie benutzt, leer */
    if (lifs_dev_pread(fd, jh, 512, (off_t)be64(jib + 36)) != 512) return -EIO;
    if (jh[0] != 0x78 || jh[1] != 0x4c || jh[2] != 0x4e || jh[3] != 0x4a) return -EINVAL;   /* Journal-Kopf unlesbar: nicht anfassen */
    return le64(jh + 8) != le64(jh + 16);
}
