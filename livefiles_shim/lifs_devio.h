/*
 * EINE Stelle fuer alle Geraete-Schreibzugriffe von livefiles_hfs.
 * Der Build ersetzt in Apples Quellen per -Dpwrite=lifs_dev_pwrite und
 * -Dioctl=lifs_dev_ioctl; kein anderer Code ruft pwrite/ioctl der libc.
 * Grund: die Drobo 5C verkraftet Schreibbefehle nur bis 512 KiB.
 */
#ifndef LIFS_DEVIO_H
#define LIFS_DEVIO_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifndef LIFS_MAX_WRITE
#define LIFS_MAX_WRITE 524288u   /* harte Kappung je Schreibbefehl; Override nur fuer die Rot-Probe (make EXTRA=...) */
#endif

ssize_t lifs_dev_pwrite(int fd, const void *buf, size_t n, off_t off);
int     lifs_dev_ioctl(int fd, unsigned long req, ...);

/* Zaehler fuer Eichung (Befehlsgroessen am Geraet) */
typedef struct {
    uint64_t writes;         /* Zahl der Schreibbefehle (nach Stueckelung) */
    uint64_t bytes;
    uint64_t max_cmd;        /* groesster Einzelbefehl */
    uint64_t max_call;       /* groesster Aufrufer-Wunsch vor Stueckelung */
    uint64_t chunked_calls;  /* Aufrufe, die gestueckelt werden mussten */
    uint64_t syncs;
} lifs_dev_stats_t;
extern lifs_dev_stats_t lifs_dev_stats;

#endif
