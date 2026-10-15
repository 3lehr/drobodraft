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
/* Journal auf einem nicht-journaled HFS+ anlegen (Gegenstueck zu diskutil enableJournal / Kernel): .journal_info_block + .journal im Wurzelverzeichnis
 * (Journal ein zusammenhaengender Extent), Journal-Info-Block (InFS|NeedInit), VH.journalInfoBlock und Bit 0x2000 (wird beim Unmount geschrieben).
 * Aufrufen mit rw gemountetem, nicht-journaled Volume, danach normal unmounten. jsize 0 = Standard. Rueckgabe 0 oder errno; bei Fehler Rueckbau. */
int lifs_enable_journal(UVFSFileNode root, uint64_t jsize);
/* HFS-Volume-UUID wie diskutil/Kernel sie zeigt: MD5(kFSUUIDNamespaceSHA1 || VH.finderInfo[24..31]) mit Version-3-Bits (Quelle: lf_hfs_volume_identifiers.c).
 * vh = die 512 Byte des Volume-Headers (Offset 1024). 0 = ok, 1 = Volume hat keine ID (Null-UUID). */
int lifs_volume_uuid(const uint8_t *vh, uint8_t out[16]);

/* 1 = Journal vorhanden, initialisiert und NICHT leer (Replay noetig, schreibt), 0 = leer/kein Journal, <0 = -errno. Liest nur. */
int lifs_journal_dirty(int fd);

/* Hebel B (Phase 5): Zuordnung Datei-Bereich -> Geraete-Bereiche, NUR LESEN, unter libLock aufzurufen (liest ggf. den Extents-Baum ueber das Geraet).
 * off/len = gewuenschter Bereich der Datendatei; gekappt auf die Dateigroesse. out[0..*n) = zusammenhaengende Geraete-Stuecke in Dateireihenfolge
 * (benachbarte werden verschmolzen), *total = Summe der Laengen. Rueckgabe 0 = Zuordnung vollstaendig (auch *total==0 bei off >= Dateigroesse),
 * 2 = komprimierte Datei (UF_COMPRESSED): Aufrufer liest ueber decmpfs, NIE ueber Datengabel/Direktweg.
 * 1 = KEIN DIREKTWEG (keine regulaere Datei, Luecke/ERANGE/Fehler im Mapping, mehr als max Stuecke) -> Aufrufer nimmt fsops_read. */
typedef struct { uint64_t dev_off, len; } lifs_extent_t;
int lifs_map_read(UVFSFileNode node, uint64_t off, uint64_t len, lifs_extent_t *out, int max, int *n, uint64_t *total);
/* 1 = regulaere Datei mit UF_COMPRESSED (unter libLock aufrufen). */
int lifs_is_compressed(UVFSFileNode node);
/* Geometrie des Volumes fuer das Mount-Log (Phase 5c): Sektorgroessen der Bibliothek und Versatz des HFS+-Volumes im Geraet (0 = kein Wrapper). */
void lifs_geometry(UVFSFileNode node, uint32_t *logical, uint32_t *physical, uint64_t *io_pos_offset);
/* Phase 5d: Lage der Sonderdateien im Geraet (which 0 Allokationsbitmap, 1 Extents-Ueberlaufbaum, 2 Katalog, 3 Attribute), alle Stuecke inkl. Ueberlaufbaum.
 * Schreibt die ersten max nach out, *n = Gesamtzahl (n > max: mit groesserem Feld wiederholen). Rueckgabe 0 ok, 1 Mapping-Fehler. Unter libLock. */
int lifs_special_extents(UVFSFileNode root, int which, lifs_extent_t *out, int max, int *n);
/* Phase 5g: ALLE Geraete-Stuecke einer regulaeren Datei (Dateireihenfolge, benachbarte verschmolzen, inkl. Ueberlaufbaum) fuer den Lagecache.
 * Rueckgabe wie lifs_map_read: 0 ok (*n Gesamtzahl, *fsize Dateigroesse; n > max -> mit groesserem Feld wiederholen), 1 kein Direktweg, 2 komprimiert. Unter libLock. */
int lifs_map_all(UVFSFileNode node, lifs_extent_t *out, int max, int *n, uint64_t *fsize);
#endif
