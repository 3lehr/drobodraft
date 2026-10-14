#!/bin/bash
# Phase 0a: 4-GiB-Rohabbild anlegen, mit Marker versehen, per FSKit-Modul einhaengen, messung.txt zeigen.
# Beruehrt NUR das hdiutil-Abbild. Bricht ab, wenn das Geraet nicht zu diesem Abbild gehoert.
set -euo pipefail
IMG=${IMG:-/Volumes/daten/xcode/drobo/probe.img}
MNT=${MNT:-/Volumes/daten/xcode/drobo/mnt}
[ -f "$IMG" ] || { mkdir -p "$(dirname "$IMG")"; truncate -s 4g "$IMG"; }
OUT=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG")
DEV=$(echo "$OUT" | awk 'NR==1{print $1}')
echo "attach: $OUT"
# Sicherheitsgurt: das Geraet muss das Abbild sein, 4 GiB gross, nie physisch
hdiutil info | grep -A30 "^image-path *: *$IMG" | grep -q "$DEV" || { echo "ABBRUCH: $DEV gehoert nicht zu $IMG"; exit 1; }
diskutil info "$DEV" | grep -E "Virtual|Disk Image|Protocol" || true
printf 'DROBOFSPROBE' | dd of="${DEV/disk/rdisk}" bs=512 count=1 conv=sync 2>&1 | tail -1
mkdir -p "$MNT"
echo "--- mount -F"
# WAIT=<Sekunden>: solange wiederholen, wie das Modul noch nicht vom Betreiber aktiviert ist ("is disabled!")
DEADLINE=$((SECONDS + ${WAIT:-0}))
while :; do
  if MOUT=$(mount -F -t drobofsprobe "$DEV" "$MNT" 2>&1); then
    ls -la "$MNT"; echo "--- messung.txt"; cat "$MNT/messung.txt"; umount "$MNT"; break
  fi
  echo "mount-Fehler: $MOUT"
  case "$MOUT" in *"is disabled"*) [ $SECONDS -lt $DEADLINE ] && { sleep 15; continue; };; esac
  break
done
echo "--- Log"
/usr/bin/log show --last 5m --predicate 'subsystem == "de.begod.drobofsprobe"' --info --style compact | tail -30
hdiutil detach "$DEV"
