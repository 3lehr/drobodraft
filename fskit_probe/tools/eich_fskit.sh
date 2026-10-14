#!/bin/bash
# Phase 2 Eichung: HFS+ ueber das FSKit-Modul (mount -F -t hfsdrobo) an Test-Abbildern; der macOS-Kernel richtet danach (fsck_hfs -fn, ro-Mount, md5).
# Beruehrt NUR Abbilddateien unter $W. Es werden nur selbst angehaengte Geraete benutzt.  Aufruf: bash eich_fskit.sh [normal|absturz|alles]
set -u
cd "$(dirname "$0")" || exit 2
M=$(cd ../.. && pwd)                         # macos/
W=${W:-/Volumes/daten/xcode/drobo/eichfs}; mkdir -p "$W"
SHORT=hfsdrobo
LOG=$W/eich_fskit.log; : > "$LOG"
NPASS=0; NFAIL=0
say()  { echo "$*" | tee -a "$LOG"; }
pass() { NPASS=$((NPASS+1)); say "PASS $*"; }
fail() { NFAIL=$((NFAIL+1)); say "FAIL $*"; }
chk()  { local name=$1; shift; if "$@" >>"$LOG" 2>&1; then pass "$name"; else fail "$name"; fi; }
rmw()  { local x; for x in "$@"; do rm -rf -- "${W:?}/${x:?}"; done; }
now()  { python3 -c 'import time;print(time.time())'; }
mbps() { python3 -c "print('%.1f' % ($1/1048576.0/max($2,1e-9)))"; }   # MiB, Sekunden
mdlist() { ( cd "$1" && find . \( -name .fseventsd -o -name .Spotlight-V100 -o -name .Trashes -o -name '.HFS+ Private Directory Data*' -o -name .DS_Store -o -name .metadata_never_index -o -name .TemporaryItems \) -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 md5 -r ); }
dlist()  { ( cd "$1" && find . \( -name .fseventsd -o -name .Spotlight-V100 -o -name .Trashes -o -name '.HFS+ Private Directory Data*' -o -name .TemporaryItems \) -prune -o -type d -print | LC_ALL=C sort ); }

mkimg() { # name journaled [groesse=4g] -> $W/name.img (Marker, vom Kernel formatiert)
  local f=$W/$1.img; rmw "$1.img"; truncate -s "${3:-4g}" "$f"
  local dev; dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$f" | awk 'NR==1{print $1}')
  newfs_hfs $([ "$2" = 1 ] && echo -J) -v "EICHFS_$1" "${dev/disk/rdisk}" >>"$LOG" 2>&1
  hdiutil detach "$dev" >>"$LOG" 2>&1
  printf 'DROBOFSPROBE' | dd of="$f" bs=1 count=12 conv=notrunc 2>/dev/null           # Marker in den unbenutzten Boot-Bytes
}
attach() { # img -> DEV (nur Abbild, Sicherheitsgurte wie run_probe.sh)
  DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$1" | awk 'NR==1{print $1}')
  local info; info=$(diskutil info "$DEV")
  { echo "$info" | grep -Eq '^ *Virtual: *Yes' && echo "$info" | grep -Eq '^ *Protocol: *Disk Image'; } || { echo "ABBRUCH: $DEV kein Disk-Image-Geraet"; hdiutil detach "$DEV"; exit 1; }
}
fmount() { # DEV MNT : mount -F, einmal wiederholen (erster Start des Modulprozesses kann den Probe-Helfer verpassen)
  mkdir -p "$2"; mount -F -t $SHORT "$1" "$2" >>"$LOG" 2>&1 || { sleep 3; mount -F -t $SHORT "$1" "$2" >>"$LOG" 2>&1; }
}
fsck_ok() { local dev; dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$1" | awk 'NR==1{print $1}')
  fsck_hfs -fn "${dev/disk/rdisk}" > "$W/fsck.out" 2>&1; local rc=$?; hdiutil detach "$dev" >>"$LOG" 2>&1
  { echo "--- fsck_hfs -fn $1 rc=$rc"; cat "$W/fsck.out"; } >>"$LOG"; [ $rc = 0 ] && grep -q 'appears to be OK' "$W/fsck.out"; }
stats_line() { /usr/bin/log show --last "${1:-3}m" --info --style compact --predicate 'subsystem == "de.begod.drobofsprobe"' 2>/dev/null | grep "STATS unmount" | tail -1 | sed 's/.*STATS/STATS/'; }
fld() { echo "$1" | sed -n "s/.*[ ]$2=\([0-9]*\).*/\1/p"; }

mksrc() { # einmalig: Quellen
  [ -f "$W/big1g.bin" ] || head -c 1073741824 /dev/urandom > "$W/big1g.bin"
  if [ ! -d "$W/src" ]; then mkdir -p "$W/src/small" "$W/src/deep/a/b/c" "$W/src/uni"
    for i in $(seq 1 1000); do head -c $(( (i * 7919) % 20000 )) /dev/urandom > "$W/src/small/f$i.bin"; done
    : > "$W/src/empty"; echo hallo > "$W/src/deep/a/b/c/leaf.txt"; echo uni > "$W/src/uni/Ümläut-日本語.txt"; fi
}

t_normal() {
  local J n img MNT t0 t1 st dw nb
  for J in 1 0; do
    n=fs$J; img=$W/$n.img; MNT=$W/mnt_$n
    say "=== FSKIT normal journaled=$J"
    mkimg "$n" $J; attach "$img"; fmount "$DEV" "$MNT" || { fail "$n mount -F"; hdiutil detach "$DEV" >/dev/null; continue; }
    pass "$n mount -F -t $SHORT"
    # Finder-uebliche Operationen per Shell
    t0=$(now); cp "$W/big1g.bin" "$MNT/big.bin"; sync; t1=$(now); say "   Kopieren 1 GiB -> Mount: $(mbps 1073741824 $(python3 -c "print($t1-$t0)")) MB/s"
    t0=$(now); mkdir "$MNT/small"; ditto "$W/src/small" "$MNT/small"; t1=$(now); say "   ditto 1000 Kleine: $(python3 -c "print('%.1f s' % ($t1-$t0))")"
    mkdir -p "$MNT/deep" "$MNT/uni" "$MNT/xx"; ditto "$W/src/deep" "$MNT/deep"; ditto "$W/src/uni" "$MNT/uni"
    mv "$MNT/small/f1.bin" "$MNT/deep/f1moved.bin"; mv "$MNT/deep" "$MNT/deep2"; rm "$MNT/small/f2.bin" "$MNT/small/f3.bin"
    mkdir "$MNT/leer"; rmdir "$MNT/leer"; : > "$MNT/empty"; cp "$W/src/deep/a/b/c/leaf.txt" "$MNT/xx/x.txt"; xattr -w user.lifs "fskit-xattr" "$MNT/xx/x.txt"
    ln -s xx/x.txt "$MNT/sym"; ln "$MNT/xx/x.txt" "$MNT/xx/hard.txt"
    t0=$(now); md5 -q "$MNT/big.bin" > "$W/$n.bigmd5"; t1=$(now); say "   Lesen 1 GiB (md5 inkl.): $(mbps 1073741824 $(python3 -c "print($t1-$t0)")) MB/s"
    chk "$n 1-GiB-Datei ueber den Mount md5-gleich" test "$(cat "$W/$n.bigmd5")" = "$(md5 -q "$W/big1g.bin")"
    chk "$n xattr ueber den Mount" test "$(xattr -p user.lifs "$MNT/xx/x.txt")" = "fskit-xattr"
    chk "$n Symlink ueber den Mount" test "$(readlink "$MNT/sym")" = "xx/x.txt"
    # Referenzbaum
    rmw ref_$n; mkdir -p "$W/ref_$n/small" "$W/ref_$n/deep2" "$W/ref_$n/uni" "$W/ref_$n/xx"
    cp "$W/big1g.bin" "$W/ref_$n/big.bin"; cp -R "$W/src/small/." "$W/ref_$n/small/"; cp -R "$W/src/deep/." "$W/ref_$n/deep2/"; cp -R "$W/src/uni/." "$W/ref_$n/uni/"
    mv "$W/ref_$n/small/f1.bin" "$W/ref_$n/deep2/f1moved.bin"; rm "$W/ref_$n/small/f2.bin" "$W/ref_$n/small/f3.bin"
    : > "$W/ref_$n/empty"; cp "$W/src/deep/a/b/c/leaf.txt" "$W/ref_$n/xx/x.txt"; cp "$W/src/deep/a/b/c/leaf.txt" "$W/ref_$n/xx/hard.txt"
    mdlist "$MNT" > "$W/$n.mnt.md5"; dlist "$MNT" > "$W/$n.mnt.dirs"; mdlist "$W/ref_$n" > "$W/$n.ref.md5"; dlist "$W/ref_$n" > "$W/$n.ref.dirs"
    chk "$n Mount-Inhalt = Referenz (md5, $(wc -l < "$W/$n.ref.md5") Dateien)" diff "$W/$n.ref.md5" "$W/$n.mnt.md5"
    chk "$n Mount-Verzeichnisse = Referenz" diff "$W/$n.ref.dirs" "$W/$n.mnt.dirs"
    t0=$(now); umount "$MNT"; t1=$(now); say "   umount (Journal schliessen): $(python3 -c "print('%.2f s' % ($t1-$t0))")"; sleep 1
    st=$(stats_line 2); say "   $st"
    dw=$(fld "$st" dev_bytes); nb=$(fld "$st" nutz_geschrieben)
    [ -n "$nb" ] && [ "$nb" -gt 0 ] && say "   Geraeteverkehr/Nutzdaten = $(python3 -c "print('%.2f' % ($dw/$nb))") (dev_bytes=$dw nutz=$nb)"
    chk "$n max Geraete-Schreibbefehl $(fld "$st" max_cmd) <= 524288" test "$(fld "$st" max_cmd)" -le 524288 -a "$(fld "$st" max_cmd)" -gt 0
    chk "$n Swift-seitig max dev.write $(fld "$st" swift_max) <= 524288" test "$(fld "$st" swift_max)" -le 524288
    hdiutil detach "$DEV" >>"$LOG" 2>&1
    # Kernel als Richter: erst ro-Mount (Journal muss leer sein), fsck, md5
    python3 -I "$M/jstate.py" "$img" | tee -a "$LOG"
    chk "$n fsck_hfs -fn nach Unmount appears to be OK" fsck_ok "$img"
    mkdir -p "$W/kro_$n"; local kd; kd=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -noverify -readonly -mountpoint "$W/kro_$n" "$img" | awk 'NR==1{print $1}')
    if [ -n "$kd" ]; then pass "$n Kernel-ro-Mount direkt nach FSKit-Unmount moeglich"
      mdlist "$W/kro_$n" > "$W/$n.k.md5"; dlist "$W/kro_$n" > "$W/$n.k.dirs"; hdiutil detach "$kd" >>"$LOG" 2>&1
      chk "$n Kernel-ro-Mount md5 = Referenz" diff "$W/$n.ref.md5" "$W/$n.k.md5"
      chk "$n Kernel-ro-Mount Verzeichnisse = Referenz" diff "$W/$n.ref.dirs" "$W/$n.k.dirs"
    else fail "$n Kernel-ro-Mount verweigert"; fi
    rmw "$n.img" "ref_$n" "kro_$n" "mnt_$n"
  done
}

# Absturz: kill -9 des Modulprozesses mitten im Kopieren. Danach Kernel: fsck as-is, rw-Mount (Replay), fsck.
t_absturz() {
  local J T n img MNT pid cp_pid pids before
  for J in 1 0; do for T in 0.3 1.2 3.0 5.2 6.0 7.0 8.0; do
    n=cr${J}_$T; img=$W/$n.img; MNT=$W/mnt_$n
    say "=== FSKIT Absturz journaled=$J kill -9 Modul nach ${T}s im Kopieren"
    mkimg "$n" $J; attach "$img"; before=$(pgrep -x DroboFSProbeModule | tr '\n' ' ')
    fmount "$DEV" "$MNT" || { fail "$n mount"; hdiutil detach "$DEV" >/dev/null; continue; }
    mkdir "$MNT/d"; ( ditto "$W/src/small" "$MNT/d" ; cp "$W/big1g.bin" "$MNT/d/big.bin" ) >/dev/null 2>&1 & cp_pid=$!
    sleep "$T"
    pids=""; for p in $(pgrep -x DroboFSProbeModule); do case " $before " in *" $p "*) ;; *) pids="$pids $p";; esac; done   # nur der fuer DIESEN Mount neu gestartete Prozess
    if [ "$(echo $pids | wc -w | tr -d " ")" = 1 ]; then kill -9 $pids; say "   Modulprozess $pids per kill -9 beendet (Kopie lief: $(kill -0 $cp_pid 2>/dev/null && echo ja || echo nein))"; else fail "$n: kein eindeutiger neuer Modulprozess ('$pids') -> kein Kill, Probe ungueltig"; fi
    sleep 1; kill $cp_pid 2>/dev/null; wait $cp_pid 2>/dev/null
    umount -f "$MNT" >>"$LOG" 2>&1; sleep 1; hdiutil detach -force "$DEV" >>"$LOG" 2>&1
    python3 -I "$M/jstate.py" "$img" | tee -a "$LOG"
    fsck_ok "$img"; local rc0=$?; say "   [roh nach Kill] fsck rc=$rc0 $(grep -E 'appears to be OK|corrupt|needs|nvalid' "$W/fsck.out" | tr '\n' '|' | cut -c1-200)"
    mkdir -p "$W/kro_$n"; local kd; kd=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -noverify -mountpoint "$W/kro_$n" "$img" | awk 'NR==1{print $1}'); [ -n "$kd" ] && hdiutil detach "$kd" >>"$LOG" 2>&1   # rw: Kernel spielt das Journal ein
    if [ $J = 1 ]; then fsck_ok "$img" && pass "ABSTURZ $n nach Kernel-Replay fsck OK (roh=$rc0)" || fail "ABSTURZ $n nach Kernel-Replay fsck NICHT OK"
    else [ $rc0 = 0 ] && NJ_OK=$((NJ_OK+1)) || NJ_BAD=$((NJ_BAD+1)); say "   NJ: roh nach Kill fsck rc=$rc0 (Kernel-Mount repariert selbst per Auto-fsck)"; fi
    rmw "$n.img" "kro_$n" "mnt_$n"
  done; done
  say "   nicht journaled nach Modul-Kill: fsck OK=$NJ_OK, schlaegt an=$NJ_BAD"
}
# Probe-Sperre: ohne Marker und ueber 8 GiB darf das Modul NICHTS einhaengen (Drobo = 64 TiB ohne Marker; CF-Karte/T7/Backup tragen keinen Marker).
t_sperre() {
  local n img MNT sz mk
  for c in "keinmarker:4g:0" "markergross:25g:1"; do
    n=sp_${c%%:*}; sz=$(echo "$c" | cut -d: -f2); mk=$(echo "$c" | cut -d: -f3); img=$W/$n.img; MNT=$W/mnt_$n
    say "=== SPERRE $n (Groesse $sz, Marker=$mk)"
    rmw "$n.img"; truncate -s "$sz" "$img"
    local d; d=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$img" | awk 'NR==1{print $1}')
    newfs_hfs -J -v "$n" "${d/disk/rdisk}" >>"$LOG" 2>&1; hdiutil detach "$d" >>"$LOG" 2>&1
    [ "$mk" = 1 ] && printf 'DROBOFSPROBE' | dd of="$img" bs=1 count=12 conv=notrunc 2>/dev/null
    attach "$img"; mkdir -p "$MNT"; local T0; T0=$(date "+%Y-%m-%d %H:%M:%S")
    if mount -F -t $SHORT "$DEV" "$MNT" >>"$LOG" 2>&1; then fail "SPERRE $n: Modul hat das Abbild eingehaengt"; umount "$MNT" >/dev/null 2>&1
    else pass "SPERRE $n: mount -F abgelehnt"; fi
    /usr/bin/log show --start "$T0" --info --style compact --predicate 'subsystem == "de.begod.drobofsprobe"' 2>/dev/null | grep -E "probe|load" | sed 's/.*\] /   /' | tail -2 | tee -a "$LOG"
    hdiutil detach "$DEV" >>"$LOG" 2>&1; rmw "$n.img" "mnt_$n"
  done
}

NJ_OK=0; NJ_BAD=0

main() {
  mksrc
  case "${1:-alles}" in normal) t_normal;; absturz) t_absturz;; sperre) t_sperre;; alles) t_sperre; t_normal; t_absturz;; esac
  say "=== ERGEBNIS PASS=$NPASS FAIL=$NFAIL (Log: $LOG)"; [ "$NFAIL" = 0 ]
}
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
