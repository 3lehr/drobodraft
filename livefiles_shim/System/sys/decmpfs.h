/* Ersatz fuer XNU <sys/decmpfs.h>: nur die von lf_hfs_vnode.c genutzten Typen (Layout wie XNU). */
#ifndef SHIM_DECMPFS_H
#define SHIM_DECMPFS_H
#include <stdint.h>
#define MAX_DECMPFS_XATTR_SIZE 3802
typedef struct __attribute__((packed)) {
    uint32_t compression_magic;
    uint32_t compression_type;
    uint64_t uncompressed_size;
} decmpfs_disk_header;
typedef struct __attribute__((packed)) {
    uint32_t attr_size;
    uint32_t compression_magic;
    uint32_t compression_type;
    uint64_t uncompressed_size;
    unsigned char attr_bytes[0];
} decmpfs_header;
#endif
