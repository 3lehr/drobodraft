#!/bin/bash
# Phase 5d: Testabbild mit "drobo-aehnlich" fragmentierten grossen Dateien. HFS+ ohne Journal, Allokationsblock 64 KiB (wie die Drobo),
# N Dateien d1..dN.bin zu je MB MiB, abwechselnd in CHUNK-KiB-Stuecken angehaengt (fsync je Stueck) -> je Datei MB*1024/CHUNK Extents
# (> 8: Ueberlaufbaum). Ausgabe: $W/NAME.img, $W/NAME.sha256 (sha256 der Quellen). Aufruf: W=... bash frag_abbild.sh [N=4] [MB=256] [CHUNK=512] [NAME=dfrag]
set -eu
W=${W:-/Volumes/daten/xcode/drobo/p5d}; N=${1:-4}; MB=${2:-256}; CHUNK=${3:-512}; NAME=${4:-dfrag}
mkdir -p "$W"; IMG=$W/$NAME.img; rm -f "$IMG"; truncate -s "$(( (N * MB + 256) ))m" "$IMG"
d=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" | awk 'NR==1{print $1}'); newfs_hfs -b 65536 -v "$NAME" "${d/disk/rdisk}" >/dev/null; hdiutil detach "$d" >/dev/null
mkdir -p "$W/mnt_$NAME"; d=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -mountpoint "$W/mnt_$NAME" "$IMG" | awk 'NR==1{print $1}')
python3 -I - "$W/mnt_$NAME" "$W/$NAME.sha256" "$N" "$MB" "$CHUNK" <<'PY'
import hashlib, os, sys
mnt, shaf, n, mb, chunk = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]) * 1024
fs = [open("%s/d%d.bin" % (mnt, i + 1), "wb") for i in range(n)]; hs = [hashlib.sha256() for _ in fs]
for _ in range(mb * 1048576 // chunk):
    for f, h in zip(fs, hs):
        b = os.urandom(chunk); f.write(b); f.flush(); os.fsync(f.fileno()); h.update(b)
for f in fs: f.close()
open(shaf, "w").write("".join("%s  d%d.bin\n" % (h.hexdigest(), i + 1) for i, h in enumerate(hs)))
PY
sync; hdiutil detach "$d" >/dev/null; echo "fertig: $IMG"; cat "$W/$NAME.sha256"
