/* Duenne C-Schicht ueber Apples LFHFS-Ops fuer lifs_cli und das FSKit-Modul (Swift). */
#ifndef LIFS_GLUE_H
#define LIFS_GLUE_H
#include <UserFS/UserVFS.h>
#include "lifs_devio.h"

extern UVFSFSOps HFS_fsOps;

/* VOR dem Mount aufrufen. Journaled Volume, leeres Journal, lastMountedVersion != 'HFSJ' (frisch newfs): setzt 'HFSJ' direkt
 * (nicht ueber das Journal), weil jeder Replay ein Journal ignoriert, dessen Volume nicht zuletzt von einem Journal-Treiber
 * gemountet war (Befund Phase 1). Rueckgabe 1 = geschrieben, 0 = nichts noetig, <0 = -errno. */
int lifs_prepare_volume(int fd);

/* Sync, Journal vollstaendig einspielen und schliessen (start==end), dann unmount. Der Kernel verweigert sonst den ro-Mount. */
int lifs_unmount_clean(UVFSFileNode root);

typedef struct {
    uint64_t fileid, nextcookie;
    uint32_t type, namelen;
    char name[1024];
    UVFSFileAttributes attrs;   /* nur bei want_attrs */
} lifs_dirent_t;
/* Liest bis maxn Eintraege ab cookie. *n=0 und Rueckgabe UVFS_READDIR_EOF_REACHED am Ende. want_attrs: ohne "." und "..". */
int lifs_readdir_chunk(UVFSFileNode dir, uint64_t cookie, uint64_t *verifier, int want_attrs, lifs_dirent_t *out, int maxn, int *n);

typedef struct {
    uint64_t blocksize, total, free_, avail, files_hint;
    uint64_t caps_format, caps_interfaces;
    char name[256];
} lifs_volinfo_t;
int lifs_volinfo(UVFSFileNode root, lifs_volinfo_t *out);
#endif
