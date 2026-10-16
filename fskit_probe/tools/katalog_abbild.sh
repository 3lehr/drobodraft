#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]:-$0}")/identity.sh"; mkdir -p "$DROBO_BUILD/work"
# Phase 5e: Testabbild mit GROSSEM Katalog (Drobo: 2,6 Mio Dateien, 2,7 GB Katalogdatei) und grossen Testdateien d1..d4.bin.
# HFS+ ohne Journal, 64-KiB-Block; Dateien zuerst (zusammenhaengend), dann NDIR*NFILE leere Dateien mit langen Namen (kleiner Faecher je Indexknoten -> tiefer Baum).
# Aufruf: W=... bash katalog_abbild.sh [NDIR=300] [NFILE=1000] [NAME=dkat]   Ausgabe: $W/NAME.img, $W/NAME.sha256, Baumtiefe
set -eu
W=${W:-$DROBO_BUILD/work/p5e}; ND=${1:-300}; NF=${2:-1000}; NAME=${3:-dkat}
mkdir -p "$W"; IMG=$W/$NAME.img; rm -f "$IMG"; truncate -s "$(( 1024 + ND * NF * 400 / 1048576 + 600 ))m" "$IMG"
d=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" | awk 'NR==1{print $1}'); newfs_hfs -b 65536 -v "$NAME" "${d/disk/rdisk}" >/dev/null; hdiutil detach "$d" >/dev/null
mkdir -p "$W/mnt_$NAME"; d=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -mountpoint "$W/mnt_$NAME" "$IMG" | awk 'NR==1{print $1}')
python3 -I - "$W/mnt_$NAME" "$W/$NAME.sha256" "$ND" "$NF" <<'PY'
import hashlib, os, sys
mnt, shaf, nd, nf = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
out = []
for i in range(4):
    h = hashlib.sha256()
    with open("%s/d%d.bin" % (mnt, i + 1), "wb") as f:
        for _ in range(256):
            b = os.urandom(1 << 20); f.write(b); h.update(b)
    out.append("%s  d%d.bin\n" % (h.hexdigest(), i + 1))
open(shaf, "w").write("".join(out))
for d in range(nd):
    p = "%s/verzeichnis_%05d_mit_langem_namen_fuer_tiefen_katalogbaum" % (mnt, d); os.mkdir(p)
    for k in range(nf): os.close(os.open("%s/datei_%05d_%06d_mit_ziemlich_langem_namen_wie_auf_der_drobo.txt" % (p, d, k), os.O_CREAT | os.O_WRONLY))
PY
sync; hdiutil detach "$d" >/dev/null
python3 -I - "$IMG" <<'PY'
import struct, sys
f = open(sys.argv[1], "rb"); f.seek(1024); vh = f.read(512); bs = struct.unpack_from(">I", vh, 40)[0]
size = struct.unpack_from(">Q", vh, 272)[0]; st, cnt = struct.unpack_from(">II", vh, 272 + 16)
f.seek(st * bs); h = f.read(64)
depth, root, leafrecs, first, last, nsize = struct.unpack_from(">HIIIIH", h, 14)
print("Katalog: %d MiB, Baumtiefe %d, Blattsaetze %d, Knotengroesse %d" % (size >> 20, depth, leafrecs, nsize))
PY
