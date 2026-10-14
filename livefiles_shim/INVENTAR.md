# Inventar: private Symbole, die livefiles_hfs (hfs-715.100.10) braucht

Erzeugt am 2026-10-14 per grep aus dem Quelltext. Quelle der Namen: `macos/livefiles_shim/UserFS/UserVFS.h` (eigener Ersatz).
Spalten: Symbol, Zahl der Fundstellen in `vendor/.../livefiles_hfs_plugin/*.[ch]` (ohne livefiles_hfs_tester), erste Fundstellen `datei:zeile`.

## Nicht im SDK vorhandene Header (Compilerfehler `file not found` beim ersten Lauf)

| Header | Fundstelle | Ersatz |
|---|---|---|
| `<UserFS/UserVFS.h>` | 6 Dateien, z.B. lf_hfs_common.h | `livefiles_shim/UserFS/UserVFS.h` (rekonstruiert, siehe unten) |
| `<System/sys/vnode.h>` | lf_hfs_vnode.h:15 | `livefiles_shim/System/sys/vnode.h` (enum vtype, VNODE_READDIR_*) |
| `<System/sys/decmpfs.h>` | lf_hfs_vnode.c:15 | `livefiles_shim/System/sys/decmpfs.h` (decmpfs_header, decmpfs_disk_header, MAX_DECMPFS_XATTR_SIZE) |
| `<System/uuid/namespace.h>` | lf_hfs_volume_identifiers.c:23 | `livefiles_shim/System/uuid/namespace.h` (kFSUUIDNamespaceSHA1) |

Weitere Include-Zeilen (sys/kernel_types.h, sys/loadable_fs.h, sys/disk.h, CommonCrypto, os/log ...) liegen im macOS-26.5-SDK.

Kein Header liefert `FS_BUNDLE_BIN_PATH` (Pfad zu fsck_hfs): `-DFS_BUNDLE_BIN_PATH="/sbin"` im Makefile; nur `LFHFS_Check`/`fsck_hfs()` nutzt es, `lifs_cli` ruft beides nie.

## Symbole aus UserVFS.h (und LiveFS-Verwandten) mit Fundstellen

| Symbol | Treffer | Fundstellen |
|---|---|---|
| `CHECK` | 1 | lf_hfs_vfsops.c:181 |
| `CHECK_AND_REPAIR` | 2 | lf_hfs_vfsops.c:184,274 |
| `LIFilePreallocateArgs_t` | 6 | lf_hfs_fsops_handler.c:400,403,404+1; lf_hfs_readwrite_ops.c:764; lf_hfs_readwrite_ops.h:31 |
| `LI_FA_VALID_BSD_FLAGS` | 1 | lf_hfs_attrlist.c:112 |
| `LI_FSATTR_PREALLOCATE` | 1 | lf_hfs_fsops_handler.c:398 |
| `LI_FSATTR_VOLNAME` | 1 | lf_hfs_fsops_handler.c:409 |
| `LI_MNT_SUPPORT_OPEN_UNLINK` | 1 | lf_hfs_fsops_handler.c:442 |
| `LI_PREALLOCATE_ALLOCATEALL` | 1 | lf_hfs_readwrite_ops.c:805 |
| `LI_PREALLOCATE_ALLOCATECONTIG` | 1 | lf_hfs_readwrite_ops.c:803 |
| `LI_PREALLOCATE_ALLOCATEFROMVOL` | 2 | lf_hfs_readwrite_ops.c:783,784 |
| `QUICK_CHECK` | 2 | lf_hfs_vfsops.c:166,178 |
| `SEARCH_RESULT_MATCH` | 1 | lf_hfs_attrlist.c:210 |
| `SEARCH_RESULT_PUSH` | 1 | lf_hfs_attrlist.c:217 |
| `UAC_LOCKED` | 0 | (vom Plugin nicht benutzt; Tester/lifs_cli) |
| `UAC_UNLOCKED` | 1 | lf_hfs_fsops_handler.c:234 |
| `UVFSAccessControl` | 0 | (vom Plugin nicht benutzt; Tester/lifs_cli) |
| `UVFSDirEntry` | 16 | lf_hfs_catalog.c:158,159,160+6; lf_hfs_catalog.h:263; lf_hfs_vnops.c:69,91,139+3 |
| `UVFSDirEntryAttr` | 6 | lf_hfs_attrlist.c:18,55,57+3 |
| `UVFSFSAttributeValue` | 2 | lf_hfs_fsops_handler.c:390,427 |
| `UVFSFSOps` | 3 | lf_hfs_fsops_handler.c:825,876; lf_hfs_fsops_handler.h:24 |
| `UVFSFileAttributes` | 33 | lf_hfs_dirops_handler.c:141,160,418; lf_hfs_dirops_handler.h:17; lf_hfs_fileops_handler.c:314,333,354+5; +7 Dateien |
| `UVFSFileNode` | 68 | lf_hfs.h:580; lf_hfs_dirops_handler.c:62,66,105+12; lf_hfs_dirops_handler.h:17,18,19+7; +7 Dateien |
| `UVFSMountFlags` | 2 | lf_hfs_fsops_handler.c:283; lf_hfs_fsops_handler.h:18 |
| `UVFSScanVolsReply` | 3 | lf_hfs_fsops_handler.c:219; lf_hfs_fsops_handler.h:21; lf_hfs_vfsops.c:129 |
| `UVFSScanVolsRequest` | 3 | lf_hfs_fsops_handler.c:219; lf_hfs_fsops_handler.h:21; lf_hfs_vfsops.c:128 |
| `UVFSStreamNode` | 7 | lf_hfs_fileops_handler.c:681,698,704+1; lf_hfs_fileops_handler.h:66,67,68 |
| `UVFSUnmountHint` | 2 | lf_hfs_fsops_handler.c:356; lf_hfs_fsops_handler.h:20 |
| `UVFSUnmountHintForce` | 2 | lf_hfs_raw_read_write.c:66,90 |
| `UVFSUnmountHintNone` | 1 | lf_hfs_vfsops.c:144 |
| `UVFSVolumeCredential` | 3 | lf_hfs_fsops_handler.c:284,820; lf_hfs_fsops_handler.h:19 |
| `UVFSVolumeId` | 3 | lf_hfs_fsops_handler.c:283,819; lf_hfs_fsops_handler.h:18 |
| `UVFSXattrHow` | 4 | lf_hfs_fileops_handler.c:647; lf_hfs_fileops_handler.h:63; lf_hfs_xattr.c:379; +1 Dateien |
| `UVFSXattrHowCreate` | 2 | lf_hfs_xattr.c:472,625 |
| `UVFSXattrHowRemove` | 1 | lf_hfs_fileops_handler.c:655 |
| `UVFSXattrHowReplace` | 2 | lf_hfs_xattr.c:478,620 |
| `UVFSXattrHowSet` | 0 | (vom Plugin nicht benutzt; Tester/lifs_cli) |
| `UVFS_DIRCOOKIE_EOF` | 8 | lf_hfs_attrlist.c:291,367,651; lf_hfs_catalog.c:1073,1082,1112+1; lf_hfs_dirops_handler.c:33 |
| `UVFS_DIRCOOKIE_FIRST` | 0 | (vom Plugin nicht benutzt; Tester/lifs_cli) |
| `UVFS_DIRCOOKIE_VERIFIER_INITIAL` | 0 | (vom Plugin nicht benutzt; Tester/lifs_cli) |
| `UVFS_DIRENTRYATTR_NAMEOFF` | 5 | lf_hfs_attrlist.c:62,64,228+1; lf_hfs_vnops.c:420 |
| `UVFS_DIRENTRYATTR_NAMEPTR` | 4 | lf_hfs_attrlist.c:66,67,229+1 |
| `UVFS_DIRENTRYATTR_RECLEN` | 0 | (vom Plugin nicht benutzt; Tester/lifs_cli) |
| `UVFS_DIRENTRY_RECLEN` | 10 | lf_hfs_catalog.c:36,939,1074+1; lf_hfs_dirops_handler.c:252,320; lf_hfs_vnops.c:32,33,71+1 |
| `UVFS_FA_MODE_GRP` | 3 | lf_hfs_common.h:99,146,147 |
| `UVFS_FA_MODE_OTH` | 3 | lf_hfs_common.h:99,146,147 |
| `UVFS_FA_MODE_R` | 1 | lf_hfs_common.h:147 |
| `UVFS_FA_MODE_RWX` | 2 | lf_hfs_common.h:99,146 |
| `UVFS_FA_MODE_USR` | 3 | lf_hfs_common.h:99,146,147 |
| `UVFS_FA_MODE_W` | 0 | (vom Plugin nicht benutzt; Tester/lifs_cli) |
| `UVFS_FA_MODE_X` | 1 | lf_hfs_common.h:147 |
| `UVFS_FA_TYPE_DIR` | 9 | lf_hfs_attrlist.c:32,215; lf_hfs_catalog.c:41,955,990+1; lf_hfs_vnode.c:21; +1 Dateien |
| `UVFS_FA_TYPE_FILE` | 4 | lf_hfs_catalog.c:40,42; lf_hfs_vnode.c:21; lf_hfs_vnops.c:1899 |
| `UVFS_FA_TYPE_INVALID` | 0 | (vom Plugin nicht benutzt; Tester/lifs_cli) |
| `UVFS_FA_TYPE_SYMLINK` | 3 | lf_hfs_catalog.c:42; lf_hfs_vnode.c:21; lf_hfs_vnops.c:2199 |
| `UVFS_FA_VALID_ALLOCSIZE` | 3 | lf_hfs_fileops_handler.h:21,36,46 |
| `UVFS_FA_VALID_ATIME` | 4 | lf_hfs_fileops_handler.h:24,39; lf_hfs_vnops.c:1604,1608 |
| `UVFS_FA_VALID_BACKUPTIME` | 0 | (vom Plugin nicht benutzt; Tester/lifs_cli) |
| `UVFS_FA_VALID_BIRTHTIME` | 4 | lf_hfs_fileops_handler.h:27,42; lf_hfs_vnops.c:1605,1614 |
| `UVFS_FA_VALID_BSD_FLAGS` | 3 | lf_hfs_fileops_handler.h:19,34; lf_hfs_vnops.c:1596 |
| `UVFS_FA_VALID_CTIME` | 3 | lf_hfs_fileops_handler.h:26,41,49 |
| `UVFS_FA_VALID_FILEID` | 3 | lf_hfs_fileops_handler.h:22,37,47 |
| `UVFS_FA_VALID_GID` | 4 | lf_hfs_fileops_handler.h:18,33; lf_hfs_vnops.c:1579,2007 |
| `UVFS_FA_VALID_MODE` | 6 | lf_hfs_fileops_handler.h:15,30; lf_hfs_vnops.c:1586,1937,1967+1 |
| `UVFS_FA_VALID_MTIME` | 5 | lf_hfs_attrlist.c:196; lf_hfs_fileops_handler.h:25,40; lf_hfs_vnops.c:1606,1619 |
| `UVFS_FA_VALID_NLINK` | 3 | lf_hfs_fileops_handler.h:16,31,45 |
| `UVFS_FA_VALID_PARENTID` | 3 | lf_hfs_fileops_handler.h:23,38,48 |
| `UVFS_FA_VALID_SIZE` | 4 | lf_hfs_fileops_handler.c:339; lf_hfs_fileops_handler.h:20,35; lf_hfs_vnops.c:1543 |
| `UVFS_FA_VALID_TYPE` | 4 | lf_hfs_attrlist.c:184; lf_hfs_fileops_handler.h:14,29,44 |
| `UVFS_FA_VALID_UID` | 4 | lf_hfs_fileops_handler.h:17,32; lf_hfs_vnops.c:1572,2002 |
| `UVFS_FSATTR_BLOCKSAVAIL` | 1 | lf_hfs_fsops_handler.c:558 |
| `UVFS_FSATTR_BLOCKSFREE` | 2 | lf_hfs_fsops_handler.c:546,560 |
| `UVFS_FSATTR_BLOCKSIZE` | 1 | lf_hfs_fsops_handler.c:511 |
| `UVFS_FSATTR_BLOCKSUSED` | 1 | lf_hfs_fsops_handler.c:570 |
| `UVFS_FSATTR_CAPS_FORMAT` | 1 | lf_hfs_fsops_handler.c:704 |
| `UVFS_FSATTR_CAPS_INTERFACES` | 1 | lf_hfs_fsops_handler.c:728 |
| `UVFS_FSATTR_CNAME` | 1 | lf_hfs_fsops_handler.c:582 |
| `UVFS_FSATTR_FSSUBTYPE` | 1 | lf_hfs_fsops_handler.c:619 |
| `UVFS_FSATTR_FSSUBTYPENUM` | 1 | lf_hfs_fsops_handler.c:650 |
| `UVFS_FSATTR_FSTYPENAME` | 1 | lf_hfs_fsops_handler.c:603 |
| `UVFS_FSATTR_IOSIZE` | 1 | lf_hfs_fsops_handler.c:522 |
| `UVFS_FSATTR_LAST_MTIME` | 1 | lf_hfs_fsops_handler.c:747 |
| `UVFS_FSATTR_MOUNTFLAGS` | 1 | lf_hfs_fsops_handler.c:436 |
| `UVFS_FSATTR_MOUNT_TIME` | 1 | lf_hfs_fsops_handler.c:759 |
| `UVFS_FSATTR_PC_FILESIZEBITS` | 1 | lf_hfs_fsops_handler.c:487 |
| `UVFS_FSATTR_PC_LINK_MAX` | 1 | lf_hfs_fsops_handler.c:446 |
| `UVFS_FSATTR_PC_NAME_MAX` | 1 | lf_hfs_fsops_handler.c:465 |
| `UVFS_FSATTR_PC_NO_TRUNC` | 1 | lf_hfs_fsops_handler.c:476 |
| `UVFS_FSATTR_PC_XATTR_SIZE_BITS` | 1 | lf_hfs_fsops_handler.c:499 |
| `UVFS_FSATTR_TOTALBLOCKS` | 1 | lf_hfs_fsops_handler.c:534 |
| `UVFS_FSATTR_VOLNAME` | 1 | lf_hfs_fsops_handler.c:682 |
| `UVFS_FSATTR_VOLUUID` | 1 | lf_hfs_fsops_handler.c:693 |
| `UVFS_FSOPS_VERSION_CURRENT` | 1 | lf_hfs_fsops_handler.c:826 |
| `UVFS_MOUNT_RDONLY` | 1 | lf_hfs_fsops_handler.c:325 |
| `UVFS_READDIR_BAD_COOKIE` | 1 | lf_hfs_dirops_handler.c:54 |
| `UVFS_READDIR_EOF_REACHED` | 4 | lf_hfs_dirops_handler.c:34,52,284+1 |
| `UVFS_READ_ONLY` | 1 | lf_hfs_common.h:147 |
| `UVFS_SCANVOLS_EOF_REACHED` | 1 | lf_hfs_fsops_handler.c:229 |
| `UVFS_SCANVOLS_VOLNAME_MAX` | 1 | lf_hfs_vfsops.c:807 |
| `_UVFS_DIRENTRYATTR_RECLEN` | 3 | lf_hfs_attrlist.c:62,569; lf_hfs_vnops.c:420 |
| `check_flags_t` | 3 | lf_hfs_fsops_handler.c:820; lf_hfs_vfsops.c:150; lf_hfs_vfsops.h:43 |
| `de_fileid` | 3 | lf_hfs_catalog.c:1102,1195; lf_hfs_vnops.c:73 |
| `de_filetype` | 2 | lf_hfs_catalog.c:1192; lf_hfs_vnops.c:74 |
| `de_name` | 2 | lf_hfs_catalog.c:926; lf_hfs_vnops.c:78 |
| `de_namelen` | 2 | lf_hfs_catalog.c:1193; lf_hfs_vnops.c:77 |
| `de_nextcookie` | 5 | lf_hfs_catalog.c:1068,1082,1112+1; lf_hfs_vnops.c:76 |
| `de_nextrec` | 2 | lf_hfs_catalog.c:1462,1467 |
| `de_reclen` | 6 | lf_hfs_catalog.c:1069,1076,1081+2; lf_hfs_vnops.c:75 |
| `dea_attrs` | 19 | lf_hfs_attrlist.c:20,22,23+16 |
| `dea_namelen` | 4 | lf_hfs_attrlist.c:61,67,226+1 |
| `dea_nameoff` | 2 | lf_hfs_attrlist.c:64,228 |
| `dea_nextcookie` | 4 | lf_hfs_attrlist.c:74,291,372+1 |
| `dea_nextrec` | 5 | lf_hfs_attrlist.c:62,69,373+2 |
| `dea_spare0` | 2 | lf_hfs_attrlist.c:63,227 |
| `fa_allocsize` | 6 | lf_hfs_attrlist.c:48; lf_hfs_vnode.c:169,179,223+2 |
| `fa_atime` | 4 | lf_hfs_attrlist.c:22,26; lf_hfs_vnode.c:156; lf_hfs_vnops.c:1610 |
| `fa_backuptime` | 1 | lf_hfs_vnode.c:161 |
| `fa_birthtime` | 4 | lf_hfs_attrlist.c:25,26; lf_hfs_vnode.c:159; lf_hfs_vnops.c:1616 |
| `fa_bsd_flags` | 5 | lf_hfs_attrlist.c:30,113; lf_hfs_vnode.c:165,175; lf_hfs_vnops.c:1598 |
| `fa_ctime` | 3 | lf_hfs_attrlist.c:23,26; lf_hfs_vnode.c:157 |
| `fa_fileid` | 4 | lf_hfs_attrlist.c:27; lf_hfs_dirops_handler.c:427,430; lf_hfs_vnode.c:163 |
| `fa_gid` | 4 | lf_hfs_attrlist.c:50; lf_hfs_vnode.c:149; lf_hfs_vnops.c:1583,2009 |
| `fa_mode` | 5 | lf_hfs_attrlist.c:29; lf_hfs_vnode.c:151; lf_hfs_vnops.c:1588,1969,2200 |
| `fa_mtime` | 5 | lf_hfs_attrlist.c:24,26,201; lf_hfs_vnode.c:158; lf_hfs_vnops.c:1621 |
| `fa_nlink` | 5 | lf_hfs_attrlist.c:35,40,44; lf_hfs_vnode.c:171,241 |
| `fa_parentid` | 4 | lf_hfs_attrlist.c:28; lf_hfs_dirops_handler.c:427,430; lf_hfs_vnode.c:164 |
| `fa_size` | 9 | lf_hfs_attrlist.c:42,45; lf_hfs_fileops_handler.c:339; lf_hfs_vnode.c:170,180,224+2; +1 Dateien |
| `fa_type` | 8 | lf_hfs_attrlist.c:49,187; lf_hfs_vnode.c:154; lf_hfs_vnops.c:1882,1899,1913+2 |
| `fa_uid` | 4 | lf_hfs_attrlist.c:51; lf_hfs_vnode.c:150; lf_hfs_vnops.c:1576,2004 |
| `fa_validmask` | 29 | lf_hfs_attrlist.c:20,112,181+2; lf_hfs_fileops_handler.c:339; lf_hfs_vnode.c:147; +1 Dateien |
| `fsa_bool` | 1 | lf_hfs_fsops_handler.c:483 |
| `fsa_number` | 20 | lf_hfs_fsops_handler.c:442,456,460+17 |
| `fsa_opaque` | 3 | lf_hfs_fsops_handler.c:403,404,700 |
| `fsa_string` | 6 | lf_hfs_fsops_handler.c:419,599,611+3 |
| `fsops_check` | 1 | lf_hfs_fsops_handler.c:856 |
| `fsops_create` | 1 | lf_hfs_fsops_handler.c:847 |
| `fsops_fini` | 1 | lf_hfs_fsops_handler.c:829 |
| `fsops_getattr` | 1 | lf_hfs_fsops_handler.c:840 |
| `fsops_getfsattr` | 1 | lf_hfs_fsops_handler.c:837 |
| `fsops_getxattr` | 1 | lf_hfs_fsops_handler.c:858 |
| `fsops_init` | 1 | lf_hfs_fsops_handler.c:828 |
| `fsops_link` | 1 | lf_hfs_fsops_handler.c:855 |
| `fsops_listxattr` | 1 | lf_hfs_fsops_handler.c:860 |
| `fsops_lookup` | 1 | lf_hfs_fsops_handler.c:842 |
| `fsops_mkdir` | 1 | lf_hfs_fsops_handler.c:848 |
| `fsops_mount` | 1 | lf_hfs_fsops_handler.c:833 |
| `fsops_read` | 1 | lf_hfs_fsops_handler.c:845 |
| `fsops_readdir` | 1 | lf_hfs_fsops_handler.c:853 |
| `fsops_readdirattr` | 1 | lf_hfs_fsops_handler.c:854 |
| `fsops_readlink` | 1 | lf_hfs_fsops_handler.c:844 |
| `fsops_reclaim` | 1 | lf_hfs_fsops_handler.c:843 |
| `fsops_remove` | 1 | lf_hfs_fsops_handler.c:850 |
| `fsops_rename` | 1 | lf_hfs_fsops_handler.c:852 |
| `fsops_rmdir` | 1 | lf_hfs_fsops_handler.c:851 |
| `fsops_scandir` | 1 | lf_hfs_fsops_handler.c:862 |
| `fsops_scanids` | 1 | lf_hfs_fsops_handler.c:863 |
| `fsops_scanvols` | 1 | lf_hfs_fsops_handler.c:832 |
| `fsops_setattr` | 1 | lf_hfs_fsops_handler.c:841 |
| `fsops_setfsattr` | 1 | lf_hfs_fsops_handler.c:838 |
| `fsops_setxattr` | 1 | lf_hfs_fsops_handler.c:859 |
| `fsops_stream_lookup` | 1 | lf_hfs_fsops_handler.c:865 |
| `fsops_stream_read` | 1 | lf_hfs_fsops_handler.c:867 |
| `fsops_stream_reclaim` | 1 | lf_hfs_fsops_handler.c:866 |
| `fsops_symlink` | 1 | lf_hfs_fsops_handler.c:849 |
| `fsops_sync` | 1 | lf_hfs_fsops_handler.c:834 |
| `fsops_taste` | 1 | lf_hfs_fsops_handler.c:831 |
| `fsops_unmount` | 1 | lf_hfs_fsops_handler.c:835 |
| `fsops_version` | 1 | lf_hfs_fsops_handler.c:826 |
| `fsops_write` | 1 | lf_hfs_fsops_handler.c:846 |
| `scandir_matching_reply_t` | 3 | lf_hfs_attrlist.h:23; lf_hfs_dirops_handler.c:366; lf_hfs_dirops_handler.h:23 |
| `scandir_matching_request_t` | 3 | lf_hfs_attrlist.h:22; lf_hfs_dirops_handler.c:366; lf_hfs_dirops_handler.h:23 |
| `smr_attribute_filter` | 7 | lf_hfs_attrlist.c:112,113,181+4 |
| `smr_entry` | 5 | lf_hfs_attrlist.c:95,223,291+2 |
| `smr_filename_contains` | 4 | lf_hfs_attrlist.c:135,137,139+1 |
| `smr_filename_ends_with` | 2 | lf_hfs_attrlist.c:158,162 |
| `smr_result_type` | 3 | lf_hfs_attrlist.c:210,217; lf_hfs_dirops_handler.c:386 |
| `smr_start_cookie` | 2 | lf_hfs_attrlist.c:242; lf_hfs_dirops_handler.c:380 |
| `smr_verifier` | 2 | lf_hfs_dirops_handler.c:380,387 |
| `sr_volac` | 1 | lf_hfs_fsops_handler.c:234 |
| `sr_volid` | 2 | lf_hfs_fsops_handler.c:227,233 |
| `sr_volname` | 1 | lf_hfs_fsops_handler.c:236 |

## Link-Ebene

Keine ungeloesten Symbole ausser libc/System: `HFS_fsOps`-Referenz zieht alle Handler, Link gegen `liblivefiles_hfs.a` ohne Stubs (Beleg in der Commit-Nachricht).
Statt Stubs werden `pwrite` und `ioctl` per `-D` auf `lifs_dev_pwrite`/`lifs_dev_ioctl` umgeleitet (`livefiles_shim/lifs_devio.c`).

## Was rekonstruiert, nicht abgeschrieben ist

Struktur-Layout, Zahlenwerte der Flags und FS-Attribut-Namen (`UVFS_FSATTR_*` als Strings) sind eigene Festlegungen, nur zwischen Plugin und lifs_cli konsistent. Nachweisbar festgelegt durch den Quelltext sind: UVFS_FA_TYPE_FILE/DIR/SYMLINK = 1/2/3 (Index in `uvfsToVtype_tab`), Modus-Bits = POSIX (`mode & ALLPERMS` in hfs_makenode), `de_reclen`/`de_nextrec` = dasselbe Feld (Endemarke 0 in cat_getdirentries und Tester), UVFS_DIRCOOKIE_EOF = ~0. Fuer FSKit-Anbindung (Phase 2) ist das Layout irrelevant, solange der Adapter denselben Header einbindet.
