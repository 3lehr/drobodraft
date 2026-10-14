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
ssize_t lifs_dev_pread(int fd, void *buf, size_t n, off_t off);
int     lifs_dev_ioctl(int fd, unsigned long req, ...);
/* posix_spawn aus Apples Quellen (fsck_hfs-Aufruf) ist gesperrt: der Kindprozess schriebe ohne Kappung. */
struct _posix_spawn_args_desc;
int     lifs_blocked_spawn(void);

/* Geraete-Rueckgriff statt Dateideskriptor (FSKit-Modul: FSBlockDeviceResource). register liefert einen virtuellen fd (>= 1000).
 * pwrite der Rueckgriffs wird nur mit n <= LIFS_MAX_WRITE aufgerufen. */
typedef struct {
    void *ctx;
    ssize_t (*pread)(void *ctx, void *buf, size_t n, off_t off);
    ssize_t (*pwrite)(void *ctx, const void *buf, size_t n, off_t off);
    int (*flush)(void *ctx);                 /* DKIOCSYNCHRONIZE */
    uint32_t block_size, phys_block_size;
    uint64_t block_count;
    int writable;
} lifs_backend_t;
int  lifs_dev_register(const lifs_backend_t *b);
void lifs_dev_unregister(int vfd);

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
