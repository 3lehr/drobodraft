/* Siehe lifs_devio.h. Diese Datei wird OHNE die pwrite/ioctl-Umbenennung gebaut. */
#include "lifs_devio.h"
#include <errno.h>
#include <stdio.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <signal.h>
#include <unistd.h>

lifs_dev_stats_t lifs_dev_stats;

/* Absturzprobe: LIFS_DIE_AFTER_WRITES=N beendet den Prozess per SIGKILL nach dem N-ten Geraete-Schreibbefehl.
 * Ersetzt kein kill -9 von aussen, trifft aber jede Stelle der Schreibfolge reproduzierbar. */
static uint64_t die_after(void)
{
    static int init; static uint64_t n;
    if (!init) { const char *e = getenv("LIFS_DIE_AFTER_WRITES"); n = e ? strtoull(e, NULL, 10) : 0; init = 1; }
    return n;
}

ssize_t lifs_dev_pwrite(int fd, const void *buf, size_t n, off_t off)
{
    size_t done = 0;
    if (n > lifs_dev_stats.max_call) lifs_dev_stats.max_call = n;
    if (n > LIFS_MAX_WRITE) lifs_dev_stats.chunked_calls++;
    while (done < n) {
        size_t c = n - done < LIFS_MAX_WRITE ? n - done : LIFS_MAX_WRITE;
        ssize_t r = pwrite(fd, (const char *)buf + done, c, off + (off_t)done);
        if (r < 0) return done ? (ssize_t)done : -1;
        lifs_dev_stats.writes++;
        if (getenv("LIFS_TRACE")) fprintf(stderr, "W #%llu off=%lld len=%zd\n", (unsigned long long)lifs_dev_stats.writes, (long long)(off + (off_t)done), r);
        if (die_after() && lifs_dev_stats.writes == die_after()) raise(SIGKILL);
        lifs_dev_stats.bytes += (uint64_t)r;
        if ((uint64_t)r > lifs_dev_stats.max_cmd) lifs_dev_stats.max_cmd = (uint64_t)r;
        done += (size_t)r;
        if ((size_t)r < c) break;                /* Kurzschreiben: wie pwrite melden */
    }
    return (ssize_t)done;
}

/* Abbilddateien haben kein Platten-ioctl: die von livefiles_hfs benutzten werden nachgebildet.
 * Geraete (Zeichen-/Blockdatei) gehen an die echte ioctl, ausser dem Schreib-Maximum. */
int lifs_dev_ioctl(int fd, unsigned long req, ...)
{
    va_list ap; va_start(ap, req);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    struct stat st;
    if (fstat(fd, &st) != 0) return -1;
    if (req == DKIOCGETMAXBYTECOUNTWRITE) {      /* Drobo-Grenze, gilt auch am echten Geraet */
        *(uint64_t *)arg = LIFS_MAX_WRITE;
        return 0;
    }
    if (!S_ISREG(st.st_mode)) return ioctl(fd, req, arg);
    switch (req) {
    case DKIOCGETBLOCKSIZE:
    case DKIOCGETPHYSICALBLOCKSIZE: *(uint32_t *)arg = 512; return 0;
    case DKIOCGETBLOCKCOUNT:        *(uint64_t *)arg = (uint64_t)st.st_size / 512; return 0;
    case DKIOCGETFEATURES:          *(uint32_t *)arg = 0; return 0;
    case DKIOCISWRITABLE: {
        int fl = fcntl(fd, F_GETFL);
        *(uint32_t *)arg = (fl >= 0 && (fl & O_ACCMODE) != O_RDONLY);
        return 0;
    }
    case DKIOCSYNCHRONIZE:                       /* Cache-Flush: Journal-Reihenfolge haengt daran */
        lifs_dev_stats.syncs++;
        if (getenv("LIFS_NOSYNC")) return 0;     /* nur fuer Durchsatzvergleich */
        return fcntl(fd, F_FULLFSYNC) == 0 ? 0 : fsync(fd);
    case DKIOCUNMAP:                return 0;
    default: errno = ENOTTY; return -1;          /* u.a. MAXBLOCK/SEGMENTCOUNT -> Plugin nimmt Default */
    }
}
