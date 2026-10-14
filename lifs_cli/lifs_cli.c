/*
 * lifs_cli: Testwerkzeug fuer livefiles_hfs (Apples HFS+-Code) gegen ein Abbild (Datei oder /dev/rdiskN).
 * Jeder Aufruf: init, taste, mount, EIN Befehl, sync, unmount. Plan: docs/PLAN_FSKIT_HFS_2026-10-14.md Phase 1.
 *   lifs_cli [-r] [-s] <abbild> <befehl> [args]      -r schreibgeschuetzt, -s Zaehler/Durchsatz auf stderr
 *   info | ls <p> | stat <p> | tree | get <p> <lokal> | put <lokal> <p> | export <lokaldir> | import <lokaldir> <p>
 *   mkdir <p> | rm <p> | rmdir <p> | mv <von> <nach> | xset <p> <name> <wert> | xget <p> <name> | xls <p>
 */
#include <UserFS/UserVFS.h>
#include "lifs_devio.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>

extern UVFSFSOps HFS_fsOps;
#define OPS HFS_fsOps
#define CHUNK (1u << 20)
#define MODE_ALL (UVFS_FA_MODE_OTH(UVFS_FA_MODE_RWX) | UVFS_FA_MODE_GRP(UVFS_FA_MODE_RWX) | UVFS_FA_MODE_USR(UVFS_FA_MODE_RWX))

static UVFSFileNode g_root;
static uint64_t g_bytes_moved;   /* Nutzdaten fuer MB/s */

static int die(const char *what, int err) { fprintf(stderr, "ERR %s: %d\n", what, err); return err ? err : 1; }

static const char *leaf(const char *p) { const char *s = strrchr(p, '/'); return s ? s + 1 : p; }

/* Pfad -> Knoten. Aufrufer reclaimt. dirpart=1: nur Elternverzeichnis (ohne letzte Komponente). */
static int resolve(const char *path, int dirpart, UVFSFileNode *out)
{
    char *dup = strdup(path), *save = NULL, *tok;
    char *last = strrchr(dup, '/');
    if (dirpart) { if (last) *last = 0; else dup[0] = 0; }
    UVFSFileNode cur = g_root; int owned = 0, err = 0;
    for (tok = strtok_r(dup, "/", &save); tok && !err; tok = strtok_r(NULL, "/", &save)) {
        UVFSFileNode nxt = NULL;
        err = OPS.fsops_lookup(cur, tok, &nxt);
        if (owned) OPS.fsops_reclaim(cur, 0);
        cur = nxt; owned = 1;
    }
    free(dup);
    if (err) return err;
    if (!owned) { /* Wurzel selbst: eigener Verweis per Lookup "." geht nicht -> Wurzel nicht reclaimen */
        *out = g_root; return 0;
    }
    *out = cur; return 0;
}
static void release(UVFSFileNode n) { if (n && n != g_root) OPS.fsops_reclaim(n, 0); }

typedef int (*entry_cb)(UVFSFileNode dir, const char *name, uint32_t type, void *ctx);

static int each_entry(UVFSFileNode dir, entry_cb cb, void *ctx)
{
    size_t bsz = 16384; uint8_t *buf = malloc(bsz);
    uint64_t cookie = UVFS_DIRCOOKIE_FIRST, verifier = UVFS_DIRCOOKIE_VERIFIER_INITIAL;
    int err = 0;
    while (!err) {
        size_t got = 0;
        int r = OPS.fsops_readdir(dir, buf, bsz, cookie, &got, &verifier);
        if (r == UVFS_READDIR_EOF_REACHED) break;
        if (r || got == 0) { err = r ? r : EIO; break; }
        size_t off = 0; int more = 1;
        while (more) {
            UVFSDirEntry *e = (UVFSDirEntry *)(buf + off);
            cookie = e->de_nextcookie;
            if (e->de_fileid != 0 && strcmp(e->de_name, ".") && strcmp(e->de_name, "..")) {
                err = cb(dir, e->de_name, e->de_filetype, ctx);
                if (err) break;
            }
            if (e->de_nextcookie == UVFS_DIRCOOKIE_EOF) { free(buf); return 0; }
            if (e->de_reclen == 0) more = 0; else off += UVFS_DIRENTRY_RECLEN(strlen(e->de_name));
        }
    }
    free(buf);
    return err;
}

static int create_node(UVFSFileNode dir, const char *name, int isdir, UVFSFileNode *out)
{
    UVFSFileAttributes a; memset(&a, 0, sizeof a);
    a.fa_validmask = UVFS_FA_VALID_MODE;   /* TYPE ist beim Anlegen schreibgeschuetzt (READ_ONLY_FA_FIELDS) */
    a.fa_type = isdir ? UVFS_FA_TYPE_DIR : UVFS_FA_TYPE_FILE;
    a.fa_mode = MODE_ALL & ~UVFS_FA_MODE_OTH(UVFS_FA_MODE_W) & ~UVFS_FA_MODE_GRP(UVFS_FA_MODE_W);
    return isdir ? OPS.fsops_mkdir(dir, name, &a, out) : OPS.fsops_create(dir, name, &a, out);
}

static int put_fd(UVFSFileNode node, int lfd)
{
    uint8_t *buf = malloc(CHUNK); uint64_t off = 0; int err = 0;
    for (;;) {
        ssize_t n = read(lfd, buf, CHUNK);
        if (n < 0) { err = errno; break; }
        if (n == 0) break;
        size_t act = 0;
        err = OPS.fsops_write(node, off, (size_t)n, buf, &act);
        if (err) break;
        if (act != (size_t)n) { err = EIO; break; }
        off += act;
    }
    g_bytes_moved += off; free(buf);
    return err;
}

static int put_file(UVFSFileNode dir, const char *name, const char *local)
{
    int lfd = open(local, O_RDONLY); if (lfd < 0) return errno;
    UVFSFileNode n = NULL; int err = create_node(dir, name, 0, &n);
    if (!err) { err = put_fd(n, lfd); OPS.fsops_reclaim(n, 0); }
    close(lfd);
    return err;
}

static int get_file(UVFSFileNode node, const char *local)
{
    int lfd = open(local, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (lfd < 0) return errno;
    UVFSFileAttributes a; int err = OPS.fsops_getattr(node, &a);
    uint8_t *buf = malloc(CHUNK); uint64_t off = 0;
    while (!err && off < a.fa_size) {
        size_t want = a.fa_size - off < CHUNK ? (size_t)(a.fa_size - off) : CHUNK, act = 0;
        err = OPS.fsops_read(node, off, want, buf, &act);
        if (err) break;
        if (act == 0) { err = EIO; break; }
        if (write(lfd, buf, act) != (ssize_t)act) { err = errno ? errno : EIO; break; }
        off += act;
    }
    g_bytes_moved += off; free(buf); close(lfd);
    return err;
}

/* ---- tree / export / import ---- */
struct walk { char path[4096]; const char *local; int mode; };   /* mode 0 tree, 1 export */
static int walk_dir(UVFSFileNode dir, struct walk *w);
static int walk_cb(UVFSFileNode dir, const char *name, uint32_t type, void *ctx)
{
    struct walk *w = ctx; size_t keep = strlen(w->path);
    snprintf(w->path + keep, sizeof w->path - keep, "/%s", name);
    UVFSFileNode n = NULL; UVFSFileAttributes a;
    int err = OPS.fsops_lookup(dir, name, &n);
    if (!err) err = OPS.fsops_getattr(n, &a);
    if (!err) {
        if (w->mode == 0) printf("%c %llu %s\n", type == UVFS_FA_TYPE_DIR ? 'd' : type == UVFS_FA_TYPE_SYMLINK ? 'l' : 'f',
                                 (unsigned long long)a.fa_size, w->path);
        else {
            char lp[4096]; snprintf(lp, sizeof lp, "%s%s", w->local, w->path);
            if (type == UVFS_FA_TYPE_DIR) { if (mkdir(lp, 0755) && errno != EEXIST) err = errno; }
            else if (type == UVFS_FA_TYPE_FILE) err = get_file(n, lp);
        }
        if (!err && type == UVFS_FA_TYPE_DIR) err = walk_dir(n, w);
    }
    if (n) OPS.fsops_reclaim(n, 0);
    w->path[keep] = 0;
    return err;
}
static int walk_dir(UVFSFileNode dir, struct walk *w) { return each_entry(dir, walk_cb, w); }

static int import_dir(UVFSFileNode dir, const char *local)
{
    DIR *d = opendir(local); if (!d) return errno;
    struct dirent *de; int err = 0;
    while (!err && (de = readdir(d))) {
        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
        char lp[4096]; snprintf(lp, sizeof lp, "%s/%s", local, de->d_name);
        if (de->d_type == DT_DIR) {
            UVFSFileNode sub = NULL; err = create_node(dir, de->d_name, 1, &sub);
            if (!err) { err = import_dir(sub, lp); OPS.fsops_reclaim(sub, 0); }
        } else if (de->d_type == DT_REG) err = put_file(dir, de->d_name, lp);
    }
    closedir(d);
    return err;
}

static int ls_cb(UVFSFileNode dir, const char *name, uint32_t type, void *ctx)
{
    UVFSFileNode n = NULL; UVFSFileAttributes a;
    int err = OPS.fsops_lookup(dir, name, &n);
    if (!err) err = OPS.fsops_getattr(n, &a);
    if (!err) printf("%c %10llu  %s\n", type == UVFS_FA_TYPE_DIR ? 'd' : type == UVFS_FA_TYPE_SYMLINK ? 'l' : 'f',
                     (unsigned long long)a.fa_size, name);
    if (n) OPS.fsops_reclaim(n, 0);
    return err;
}

static void print_fsattr(const char *label, const char *attr, int is_str)
{
    union { UVFSFSAttributeValue v; char raw[512]; } u; size_t len = 0;
    memset(&u, 0, sizeof u);
    if (OPS.fsops_getfsattr(g_root, attr, &u.v, sizeof u.raw, &len)) { printf("%s: (fehlt)\n", label); return; }
    if (is_str) printf("%s: %s\n", label, u.v.fsa_string); else printf("%s: %llu\n", label, (unsigned long long)u.v.fsa_number);
}

static int run(int argc, char **argv)
{
    const char *cmd = argv[0]; UVFSFileNode a = NULL, b = NULL; int err = 0;
#define NEED(n) if (argc < (n) + 1) return die("Argumente fehlen", EINVAL)
    if (!strcmp(cmd, "info")) {
        print_fsattr("volname", UVFS_FSATTR_VOLNAME, 1); print_fsattr("blocksize", UVFS_FSATTR_BLOCKSIZE, 0);
        print_fsattr("totalblocks", UVFS_FSATTR_TOTALBLOCKS, 0); print_fsattr("blocksfree", UVFS_FSATTR_BLOCKSFREE, 0);
        print_fsattr("subtype", UVFS_FSATTR_FSSUBTYPE, 1);
    } else if (!strcmp(cmd, "ls")) {
        NEED(1); if ((err = resolve(argv[1], 0, &a))) return die("ls", err);
        err = each_entry(a, ls_cb, NULL); release(a);
    } else if (!strcmp(cmd, "stat")) {
        NEED(1); UVFSFileAttributes at;
        if ((err = resolve(argv[1], 0, &a)) || (err = OPS.fsops_getattr(a, &at))) return die("stat", err);
        printf("type=%u mode=%o size=%llu alloc=%llu nlink=%u fileid=%llu mtime=%ld\n", at.fa_type, at.fa_mode,
               (unsigned long long)at.fa_size, (unsigned long long)at.fa_allocsize, at.fa_nlink,
               (unsigned long long)at.fa_fileid, (long)at.fa_mtime.tv_sec);
        release(a);
    } else if (!strcmp(cmd, "tree") || !strcmp(cmd, "export")) {
        struct walk w = {.path = "", .local = argc > 1 ? argv[1] : "", .mode = !strcmp(cmd, "export")};
        err = walk_dir(g_root, &w);
    } else if (!strcmp(cmd, "get")) {
        NEED(2); if ((err = resolve(argv[1], 0, &a))) return die("get lookup", err);
        err = get_file(a, argv[2]); release(a);
    } else if (!strcmp(cmd, "put")) {
        NEED(2); if ((err = resolve(argv[2], 1, &a))) return die("put dir", err);
        err = put_file(a, leaf(argv[2]), argv[1]); release(a);
    } else if (!strcmp(cmd, "import")) {
        NEED(2); if ((err = resolve(argv[2], 0, &a))) return die("import dir", err);
        err = import_dir(a, argv[1]); release(a);
    } else if (!strcmp(cmd, "mkdir")) {
        NEED(1); if ((err = resolve(argv[1], 1, &a))) return die("mkdir dir", err);
        err = create_node(a, leaf(argv[1]), 1, &b); if (!err) OPS.fsops_reclaim(b, 0); release(a);
    } else if (!strcmp(cmd, "rm") || !strcmp(cmd, "rmdir")) {
        NEED(1); if ((err = resolve(argv[1], 1, &a))) return die("rm dir", err);
        if (cmd[2]) err = OPS.fsops_rmdir(a, leaf(argv[1]), NULL);   /* rmdir sucht das Opfer selbst und reclaimt es */
        else if (!(err = OPS.fsops_lookup(a, leaf(argv[1]), &b))) { err = OPS.fsops_remove(a, leaf(argv[1]), b); OPS.fsops_reclaim(b, 0); }   /* remove verlangt den Opferknoten (sonst EINVAL) */
        release(a);
    } else if (!strcmp(cmd, "mv")) {
        NEED(2); UVFSFileNode fd_ = NULL, fn = NULL, td = NULL, tn = NULL;
        if ((err = resolve(argv[1], 1, &fd_)) || (err = resolve(argv[1], 0, &fn)) || (err = resolve(argv[2], 1, &td))) return die("mv", err);
        if (resolve(argv[2], 0, &tn)) tn = NULL;
        err = OPS.fsops_rename(fd_, fn, leaf(argv[1]), td, tn, leaf(argv[2]), 0);
        release(fd_); release(fn); release(td); release(tn);
    } else if (!strcmp(cmd, "xset") || !strcmp(cmd, "xget") || !strcmp(cmd, "xls")) {
        NEED(cmd[1] == 'l' ? 1 : 2); if ((err = resolve(argv[1], 0, &a))) return die("x lookup", err);
        char buf[8192]; size_t act = 0;
        if (cmd[1] == 's') err = OPS.fsops_setxattr(a, argv[2], argc > 3 ? argv[3] : "", argc > 3 ? strlen(argv[3]) : 0, UVFSXattrHowSet);
        else if (cmd[1] == 'g') { err = OPS.fsops_getxattr(a, argv[2], buf, sizeof buf, &act); if (!err) fwrite(buf, 1, act, stdout); }
        else { err = OPS.fsops_listxattr(a, buf, sizeof buf, &act); for (size_t i = 0; !err && i < act; i += strlen(buf + i) + 1) puts(buf + i); }
        release(a);
    } else return die("unbekannter Befehl", EINVAL);
    return err ? die(cmd, err) : 0;
}

int main(int argc, char **argv)
{
    int ro = 0, stats = 0, i = 1;
    for (; i < argc && argv[i][0] == '-'; i++) { if (argv[i][1] == 'r') ro = 1; else if (argv[i][1] == 's') stats = 1; }
    if (argc - i < 2) { fprintf(stderr, "usage: lifs_cli [-r] [-s] <abbild> <befehl> [args]\n"); return 2; }
    int fd = open(argv[i], ro ? O_RDONLY : O_RDWR);
    if (fd < 0) return die("open", errno);
    int rc;
    if ((rc = OPS.fsops_init())) return die("init", rc);
    if ((rc = OPS.fsops_taste(fd))) return die("taste (kein HFS+?)", rc);
    UVFSScanVolsRequest rq = {0}; UVFSScanVolsReply rp; memset(&rp, 0, sizeof rp);
    if ((rc = OPS.fsops_scanvols(fd, &rq, &rp))) return die("scanvols", rc);
    if ((rc = OPS.fsops_mount(fd, rp.sr_volid, ro ? UVFS_MOUNT_RDONLY : 0, NULL, &g_root))) return die("mount", rc);
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    rc = run(argc - i - 1, argv + i + 1);
    int r2 = ro ? 0 : OPS.fsops_sync(g_root);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (r2) rc = rc ? rc : die("sync", r2);
    r2 = OPS.fsops_unmount(g_root, UVFSUnmountHintNone);
    if (r2) rc = rc ? rc : die("unmount", r2);
    OPS.fsops_fini();
    if (stats) {
        double s = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
        fprintf(stderr, "STATS cmd=%s sek=%.3f nutz_MB=%.1f MB/s=%.1f | dev: writes=%llu bytes=%llu max_cmd=%llu max_call=%llu chunked=%llu syncs=%llu\n",
                argv[i + 1], s, g_bytes_moved / 1048576.0, s > 0 ? g_bytes_moved / 1048576.0 / s : 0,
                (unsigned long long)lifs_dev_stats.writes, (unsigned long long)lifs_dev_stats.bytes,
                (unsigned long long)lifs_dev_stats.max_cmd, (unsigned long long)lifs_dev_stats.max_call,
                (unsigned long long)lifs_dev_stats.chunked_calls, (unsigned long long)lifs_dev_stats.syncs);
    }
    close(fd);
    return rc;
}
