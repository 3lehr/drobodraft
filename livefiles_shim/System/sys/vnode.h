/* Ersatz fuer XNU <sys/vnode.h> (Kernel-intern): nur enum vtype + readdir-Flags. */
#ifndef SHIM_SYS_VNODE_H
#define SHIM_SYS_VNODE_H
enum vtype { VNON, VREG, VDIR, VBLK, VCHR, VLNK, VSOCK, VFIFO, VBAD, VSTR, VCPLX };
#define VNODE_READDIR_EXTENDED    0x0001
#define VNODE_READDIR_REQSEEKOFF  0x0002
#define VNODE_READDIR_SEEKOFF32   0x0004
#define VNODE_READDIR_NAMEMAX     0x0008
#endif
