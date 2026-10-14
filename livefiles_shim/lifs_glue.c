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
