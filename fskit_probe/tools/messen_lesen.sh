#!/bin/bash
# Phase 5 Schritt 1: Lesedurchsatz MESSEN (kein Umbau). Kernel-ro-Mount vs. Modul (mount -F -t hfsdrobo -o rdonly) vs. roh (dd rdisk), 3 Laeufe je Zelle.
# Ziele: CF-Karte "old" (disk6: Partition CFNJ = HFS+ ohne Journal, CFJ = HFS+ mit Journal) und lokales Abbild (Gegenprobe). Drobo (disk7) wird nie angefasst.
# Aufruf:  bash messen_lesen.sh prep      Abbild bauen, Freigabeliste ergaenzen (Sicherung), Testdateien pruefen
#          bash messen_lesen.sh messen    alle Messungen; Ergebnis: $W/ergebnis.txt, Rohlog: $W/messen.log
#          bash messen_lesen.sh abbau     Freigabeeintraege der Messung entfernen (Original wiederherstellen), Abbild abhaengen
# Erwartet: Testdateien $W/src/f1..f4.bin (je 1 GiB Zufall), beide CF-Partitionen tragen sie bereits.
set -u
W=${W:-/Volumes/daten/xcode/drobo/p5messung}; SRC=$W/src; IMG=$W/p5.img
LOG=$W/messen.log; RES=$W/ergebnis.txt
FREIGABE="$HOME/Library/Containers/de.begod.drobofsprobe.fsmodule/Data/freigabe.json"
RUNS=${RUNS:-3}
stop() { echo "STOP: $*" | tee -a "$LOG"; exit 1; }
say() { echo "$*" | tee -a "$RES"; }
cfdev() { # name -> /dev/diskNsM (nur disk6, Beleg ueber Medienname)
  case $1 in CFNJ) echo /dev/disk6s2;; CFJ) echo /dev/disk6s3;; esac; }
guard_cf() { diskutil info disk6 | grep -q "Device / Media Name: *CFX Card Reader" || stop "disk6 ist nicht CFX Card Reader"; }
vuuid() { diskutil info "$1" | sed -n 's/.*Volume UUID: *//p'; }
vsize() { diskutil info -plist "$1" | python3 -I -c 'import plistlib,sys;print(plistlib.loads(sys.stdin.buffer.read()).get("TotalSize",0))'; }
umnt() { diskutil unmount "$1" >>"$LOG" 2>&1 || diskutil unmount force "$1" >>"$LOG" 2>&1; }
attach_img() { hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" | awk 'NR==1{print $1}'; }

prep() {
  guard_cf
  if [ ! -f "$IMG" ]; then
    truncate -s 6g "$IMG"; local d; d=$(attach_img); diskutil info "$d" | grep -Eq '^ *Protocol: *Disk Image' || stop "$d kein Abbild"
    newfs_hfs -v P5IMG "${d/disk/rdisk}" >>"$LOG" 2>&1; hdiutil detach "$d" >>"$LOG" 2>&1
    mkdir -p "$W/mnt_img_rw"; d=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -mountpoint "$W/mnt_img_rw" "$IMG" | awk 'NR==1{print $1}')
    cp "$SRC"/f?.bin "$W/mnt_img_rw/" && sync; hdiutil detach "$d" >>"$LOG" 2>&1
  fi
  local d; d=$(attach_img); local ui; ui=$(vuuid "$d"); local szi; szi=$(vsize "$d"); hdiutil detach "$d" >>"$LOG" 2>&1
  [ -f "$W/freigabe.orig.json" ] || cp "$FREIGABE" "$W/freigabe.orig.json"
  python3 -I - "$FREIGABE" "$W/freigabe.orig.json" "$(vuuid /dev/disk6s2)" "$(vsize /dev/disk6s2)" "$(vuuid /dev/disk6s3)" "$(vsize /dev/disk6s3)" "$ui" "$szi" <<'PY'
import json, sys
p, orig, *a = sys.argv[1:]
lst = json.load(open(orig)); lst = lst if isinstance(lst, list) else lst.get("eintraege", [])
for u, sz in zip(a[0::2], a[1::2]):
    lst.append({"volume_uuid": u.upper(), "modus": "nurlesen", "max_bytes": int(sz) + (1 << 30), "notiz": "Phase5-Messung, nach Messung entfernen"})
json.dump(lst, open(p, "w"), indent=1); print("Freigabe:", [(e["volume_uuid"], e["max_bytes"]) for e in lst])
PY
}

abbau() { cp "$W/freigabe.orig.json" "$FREIGABE" && echo "Freigabe wiederhergestellt:" && cat "$FREIGABE"; }

# Ein Messlauf: dd bs=1m ueber f1 -> "bytes/sec"
ddrate() { dd if="$1" of=/dev/null bs=1m 2>&1 | tail -1 | sed -n 's/.*(\([0-9]*\) bytes\/sec).*/\1/p'; }
mbs() { python3 -c "print('%.1f' % ($1/1e6))"; }
stats() { sleep 2; /usr/bin/log show --last 2m --info --style compact --predicate 'subsystem == "de.begod.drobofsprobe"' 2>/dev/null | grep "STATS" | tail -2 | sed 's/.*STATS/STATS/'; }

kmount() { # dev -> mountpoint (frisch, read-only, Kernel)
  diskutil mount readOnly "$1" >>"$LOG" 2>&1 || return 1
  diskutil info "$1" | sed -n 's/^ *Mount Point: *//p'; }
fmount() { # dev mnt
  mkdir -p "$2"; mount -F -t hfsdrobo -o rdonly "$1" "$2" >>"$LOG" 2>&1 || { sleep 3; mount -F -t hfsdrobo -o rdonly "$1" "$2" >>"$LOG" 2>&1; }; }

zelle() { # name dev
  local n=$1 dev=$2 i mp r mb
  umnt "$dev" >/dev/null 2>&1
  for i in $(seq 1 $RUNS); do
    mp=$(kmount "$dev") || { say "FEHLER kernel-mount $n $dev"; continue; }
    r=$(ddrate "$mp/f1.bin"); mb=$(mbs "${r:-0}")
    say "kernel  $n lauf$i f1.bin bs=1m  ${mb} MB/s  (${r} bytes/sec)"
    if [ "$i" = 1 ]; then for f in f2 f3 f4; do h=$(shasum -a 256 "$mp/$f.bin" | cut -d' ' -f1); [ "$h" = "$(grep "$f.bin" $W/src.sha256 | cut -d' ' -f1)" ] && say "   sha kernel $n $f OK" || say "   sha kernel $n $f FALSCH"; done; fi
    umnt "$dev" >>"$LOG" 2>&1
  done
  local M=$W/mnt_$n; mkdir -p "$M"
  for i in $(seq 1 $RUNS); do
    fmount "$dev" "$M" || { say "FEHLER modul-mount $n $dev (siehe $LOG)"; continue; }
    r=$(ddrate "$M/f1.bin"); mb=$(mbs "${r:-0}")
    say "modul   $n lauf$i f1.bin bs=1m  ${mb} MB/s  (${r} bytes/sec)"
    if [ "$i" = 1 ]; then for f in f2 f3 f4; do h=$(shasum -a 256 "$M/$f.bin" | cut -d' ' -f1); [ "$h" = "$(grep "$f.bin" $W/src.sha256 | cut -d' ' -f1)" ] && say "   sha modul $n $f OK" || say "   sha modul $n $f FALSCH"; done; fi
    umount "$M" >>"$LOG" 2>&1; stats | sed 's/^/   /' | tee -a "$RES"
  done
  for bs in 1m 128k 512k; do
    local cnt; case $bs in 1m) cnt=1024;; 128k) cnt=8192;; 512k) cnt=2048;; esac
    for i in $(seq 1 $RUNS); do
      r=$(dd if=/dev/r${dev#/dev/} of=/dev/null bs=$bs count=$cnt 2>&1 | tail -1 | sed -n 's/.*(\([0-9]*\) bytes\/sec).*/\1/p')
      say "roh     $n lauf$i rdisk bs=$bs count=$cnt  $(mbs "${r:-0}") MB/s  (${r} bytes/sec)"
    done
  done
}

messen() {
  guard_cf; : > "$RES"
  say "== Messung $(date +%Y-%m-%dT%H:%M:%S%z)  host=$(sw_vers -productVersion) =="
  zelle CFNJ "$(cfdev CFNJ)"
  zelle CFJ "$(cfdev CFJ)"
  local d; d=$(attach_img); diskutil info "$d" | grep -Eq '^ *Protocol: *Disk Image' || stop "$d kein Abbild"
  zelle IMG "$d"; hdiutil detach "$d" >>"$LOG" 2>&1
  say "== Ende =="
}

case "${1:-}" in prep) prep;; messen) messen;; abbau) abbau;; *) sed -n 2,8p "$0";; esac
