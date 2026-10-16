#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]:-$0}")/identity.sh"; mkdir -p "$DROBO_BUILD/work"
# Phase 2 Eichung: HFS+ ueber das FSKit-Modul (mount -F -t hfsdrobo) an Test-Abbildern; der macOS-Kernel richtet danach (fsck_hfs -fn, ro-Mount, md5).
# Beruehrt NUR Abbilddateien unter $W. Es werden nur selbst angehaengte Geraete benutzt.  Aufruf: bash eich_fskit.sh [normal|absturz|alles]
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2
M=$(cd ../.. && pwd)                         # macos/
W=${W:-$DROBO_BUILD/work/eichfs}; mkdir -p "$W"
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
stats_line() { /usr/bin/log show --last "${1:-3}m" --info --style compact --predicate 'subsystem == "'$DROBO_APP_ID'"' 2>/dev/null | grep "STATS unmount" | tail -1 | sed 's/.*STATS/STATS/'; }
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
    mkdir -p "$W/kro_$n" "$W/dc_ref_$n"; local kd; kd=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -noverify -readonly -mountpoint "$W/kro_$n" "$img" | awk 'NR==1{print $1}')
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
    mkdir -p "$W/kro_$n" "$W/dc_ref_$n"; local kd; kd=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -noverify -mountpoint "$W/kro_$n" "$img" | awk 'NR==1{print $1}'); [ -n "$kd" ] && hdiutil detach "$kd" >>"$LOG" 2>&1   # rw: Kernel spielt das Journal ein
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
    /usr/bin/log show --start "$T0" --info --style compact --predicate 'subsystem == "'$DROBO_APP_ID'"' 2>/dev/null | grep -E "probe|load" | sed 's/.*\] /   /' | tail -2 | tee -a "$LOG"
    hdiutil detach "$DEV" >>"$LOG" 2>&1; rmw "$n.img" "mnt_$n"
  done
}

# Freigabeliste (Phase 4 Vorbereitung): Geraet OHNE Marker nur ueber freigabe.json im Container des Moduls; Modus nurlesen = nichts darf schreiben.
FREIGABE="$HOME/Library/Containers/$DROBO_MODULE_ID/Data/freigabe.json"
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
mkplain() { # name journaled MiB -> Abbild OHNE Marker, vom Kernel gefuellt; setzt VUUID, $W/name.ref.md5
  local n=$1 f=$W/$1.img d; rmw "$n.img"; truncate -s "${3}m" "$f"
  d=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$f" | awk 'NR==1{print $1}'); newfs_hfs $([ "$2" = 1 ] && echo -J) -v "FG_$n" "${d/disk/rdisk}" >>"$LOG" 2>&1; hdiutil detach "$d" >>"$LOG" 2>&1
  mkdir -p "$W/mnt_$n"; d=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -mountpoint "$W/mnt_$n" "$f" | awk 'NR==1{print $1}')
  VUUID=$(diskutil info "$d" | awk '/Volume UUID/{print $3}')
  head -c 20000000 /dev/urandom > "$W/mnt_$n/a.bin"; mkdir "$W/mnt_$n/d"; for i in 1 2 3; do echo $i > "$W/mnt_$n/d/f$i"; done; xattr -w user.fg v "$W/mnt_$n/d/f1"; sync
  mdlist "$W/mnt_$n" > "$W/$n.ref.md5"; hdiutil detach "$d" >>"$LOG" 2>&1
}
fg_set() { printf '%s' "$1" > "$FREIGABE"; }
# Betreiber-Freigabeliste (z. B. Drobo-Eintrag) vor der Eichung sichern und danach zurueckstellen, nie loeschen.
# Die RETURN-Falle feuert in bash 5.3 zweimal (Ende der Funktion und danach noch einmal): FG_FERTIG macht fg_zurueck idempotent, sonst loescht der
# zweite Aufruf (ohne Sicherung) die gerade zurueckgestellte Liste (Befund 2026-10-14, P5 Schritt 2).
fg_sichern() {
  FG_FERTIG=0
  if [ -f "$FREIGABE.eich_sicherung" ] && [ -f "$FREIGABE" ]; then   # veraltete Sicherung UND aktuelle Liste: eine von beiden gehoert dem Betreiber - nichts ueberschreiben
    echo "ABBRUCH: $FREIGABE.eich_sicherung (aelterer, abgebrochener Eichlauf) UND $FREIGABE existieren. Betreiber entscheidet, welche gilt; nichts veraendert." >&2; exit 3
  fi
  [ -f "$FREIGABE.eich_sicherung" ] || { [ -f "$FREIGABE" ] && cp -p "$FREIGABE" "$FREIGABE.eich_sicherung"; }; rm -f "$FREIGABE"; }
fg_zurueck() { trap - RETURN; [ "${FG_FERTIG:-0}" = 1 ] && return 0; FG_FERTIG=1; if [ -f "$FREIGABE.eich_sicherung" ]; then mv -f "$FREIGABE.eich_sicherung" "$FREIGABE"; else rm -f "$FREIGABE"; fi; }
fg_mount() { # img [extra-mount-opts] -> rc ; setzt DEV MNT
  attach "$1"; MNT=$W/mnt_fg; mkdir -p "$MNT"
  mount -F -t $SHORT $2 "$DEV" "$MNT" >>"$LOG" 2>&1 || { sleep 3; mount -F -t $SHORT $2 "$DEV" "$MNT" >>"$LOG" 2>&1; }
}
t_freigabe() {
  local n img sha0 sha1 st rc mp
  [ -f "$W/m3.bin" ] || head -c 21000123 /dev/urandom > "$W/m3.bin"
  trap fg_zurueck RETURN; fg_sichern
  for J in 1 0; do
    n=fg$J; img=$W/$n.img; say "=== FREIGABE nurlesen journaled=$J (Abbild ohne Marker)"
    mkplain "$n" $J 512; say "   Volume-UUID (diskutil) $VUUID"
    chk "$n Abbild traegt keinen Marker" test "$(head -c 12 "$img" | tr -d "\\0")" != "DROBOFSPROBE"
    sha0=$(sha "$img")
    # (a) nicht gelistet -> abgelehnt
    attach "$img"; MNT=$W/mnt_fg; mkdir -p "$MNT"; mount -F -t $SHORT "$DEV" "$MNT" >>"$LOG" 2>&1 && { fail "$n ohne Freigabe eingehaengt"; umount "$MNT"; } || pass "$n ohne Eintrag abgelehnt"; hdiutil detach "$DEV" >>"$LOG" 2>&1
    fg_set '[{"volume_uuid":"00000000-1111-3333-8888-000000000000","modus":"nurlesen","max_bytes":1073741824}]'
    attach "$img"; mount -F -t $SHORT "$DEV" "$MNT" >>"$LOG" 2>&1 && { fail "$n fremde UUID eingehaengt"; umount "$MNT"; } || pass "$n fremde UUID in der Liste: abgelehnt"; hdiutil detach "$DEV" >>"$LOG" 2>&1
    fg_set "[{\"volume_uuid\":\"$VUUID\",\"modus\":\"nurlesen\",\"max_bytes\":1048576}]"
    attach "$img"; mount -F -t $SHORT "$DEV" "$MNT" >>"$LOG" 2>&1 && { fail "$n Geraet groesser als max_bytes eingehaengt"; umount "$MNT"; } || pass "$n Geraet > max_bytes: abgelehnt"; hdiutil detach "$DEV" >>"$LOG" 2>&1
    fg_set '{kaputt'
    attach "$img"; mount -F -t $SHORT "$DEV" "$MNT" >>"$LOG" 2>&1 && { fail "$n kaputte Liste eingehaengt"; umount "$MNT"; } || pass "$n ungueltige Liste: abgelehnt"; hdiutil detach "$DEV" >>"$LOG" 2>&1
    # (b) freigegeben nurlesen: einmal mit -o rdonly, einmal ohne
    for opt in "-o rdonly" ""; do
      fg_set "[{\"volume_uuid\":\"$VUUID\",\"modus\":\"nurlesen\",\"max_bytes\":1073741824}]"
      fg_mount "$img" "$opt" && pass "$n mount -F ${opt:-(ohne rdonly)} freigegeben" || { fail "$n mount freigegeben ($opt)"; hdiutil detach "$DEV" >/dev/null; continue; }
      mp=$(mount | grep -iF " $MNT " | head -1); echo "$mp" | grep -q "read-only" && pass "$n als read-only gemeldet: $(echo "$mp" | sed 's/.*(\(.*\))/\1/')" || fail "$n nicht read-only gemeldet: $mp"
      mdlist "$MNT" > "$W/$n.fg.md5"; chk "$n Lesen md5 gleich Referenz (${opt:-ohne rdonly})" diff "$W/$n.ref.md5" "$W/$n.fg.md5"
      for t in "cp /etc/hosts $MNT/neu" "touch $MNT/t" "mkdir $MNT/nd" "rm $MNT/a.bin" "xattr -w user.x y $MNT/d/f1" "mv $MNT/a.bin $MNT/b.bin" "ln -s a.bin $MNT/sl" "truncate -s 5 $MNT/a.bin"; do
        $t >>"$LOG" 2>&1 && fail "$n Schreibversuch gelang: $t" || pass "$n Schreibversuch scheitert: ${t%% *}"
      done
      umount "$MNT"; sleep 1; hdiutil detach "$DEV" >>"$LOG" 2>&1
      st=$(stats_line 2); say "   $st"
      chk "$n Schreibzaehler 0 (dev_writes=$(fld "$st" dev_writes), dev_schreibversuche=$(fld "$st" dev_schreibversuche))" test "$(fld "$st" dev_writes)" = 0 -a "$(fld "$st" dev_schreibversuche)" = 0
      chk "$n Modul meldet ro=1" test "$(fld "$st" ro)" = 1
      sha1=$(sha "$img"); chk "$n Abbild-SHA256 vorher == nachher" test "$sha0" = "$sha1"
    done
    chk "$n fsck_hfs -fn danach OK" fsck_ok "$img"; rmw "$n.img" "mnt_$n"
  done
  # (c) Journal nicht leer + nurlesen -> abgelehnt (Kontrolle: nach Kernel-Replay angenommen)
  n=fgj; img=$W/$n.img; say "=== FREIGABE: Journal nicht leer"
  mkplain "$n" 1 512
  "$M/build/lifs_cli" "$img" mkdir /x >/dev/null 2>&1; LIFS_DIE_AFTER_WRITES=90 "$M/build/lifs_cli" "$img" put "$W/m3.bin" /x/m3 >/dev/null 2>&1
  python3 -I "$M/jstate.py" "$img" | tee -a "$LOG" | grep -q NICHT-LEER && pass "$n Ausgang: Journal NICHT leer" || fail "$n Ausgang: Journal ist leer (Test ungueltig)"
  fg_set "[{\"volume_uuid\":\"$VUUID\",\"modus\":\"nurlesen\",\"max_bytes\":1073741824}]"
  sha0=$(sha "$img"); attach "$img"; MNT=$W/mnt_fg; mkdir -p "$MNT"
  mount -F -t $SHORT -o rdonly "$DEV" "$MNT" >>"$LOG" 2>&1 && { fail "$n nurlesen mit nicht leerem Journal eingehaengt"; umount "$MNT"; } || pass "$n nurlesen + Journal nicht leer: abgelehnt"
  hdiutil detach "$DEV" >>"$LOG" 2>&1
  /usr/bin/log show --last 2m --info --style compact --predicate 'subsystem == "'$DROBO_APP_ID'"' 2>/dev/null | grep -E "Journal nicht leer" | tail -1 | sed 's/.*\] /   /' | tee -a "$LOG"
  chk "$n Abbild-SHA256 vorher == nachher (abgelehnt, nichts geschrieben)" test "$sha0" = "$(sha "$img")"
  local kd; mkdir -p "$W/mnt_fgk"; kd=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -mountpoint "$W/mnt_fgk" "$img" | awk 'NR==1{print $1}'); hdiutil detach "$kd" >>"$LOG" 2>&1   # Kernel spielt das Journal ein
  fg_mount "$img" "-o rdonly" && pass "$n Kontrolle: nach Kernel-Replay wird nurlesen angenommen" || fail "$n Kontrolle: nach Replay immer noch abgelehnt"
  umount "$MNT" 2>/dev/null; hdiutil detach "$DEV" >>"$LOG" 2>&1; rmw "$n.img" mnt_fg mnt_fgk
}

# Nur mit Pruefbau (XC_EXTRA='SWIFT_ACTIVE_COMPILATION_CONDITIONS=TEST_MOUNT_RW' tools/install_module.sh): das Modul meldet dem Kernel NICHT read-only,
# Schreibzugriffe erreichen also seine eigenen EROFS-Sperren (ro_blockiert) und, nie, den Backend-Zaehler. Danach normalen Bau wieder installieren.
t_freigabe_modul() {
  local n=fgm img sha0 st
  trap fg_zurueck RETURN; fg_sichern
  mkplain "$n" 1 512; img=$W/$n.img; sha0=$(sha "$img")
  fg_set "[{\"volume_uuid\":\"$VUUID\",\"modus\":\"nurlesen\",\"max_bytes\":1073741824}]"
  fg_mount "$img" "" || { fail "$n mount"; return; }
  mount | grep -iF " $MNT " | grep -q "read-only" && fail "$n Pruefbau meldet trotzdem read-only (Test ungueltig)" || pass "$n Pruefbau: Kernel-Mount ist schreibbar gemeldet (Modul-Sperren werden erreicht)"
  for t in "cp /etc/hosts $MNT/neu" "touch $MNT/t" "mkdir $MNT/nd" "rm $MNT/a.bin" "xattr -w user.x y $MNT/d/f1" "mv $MNT/a.bin $MNT/b.bin" "ln -s a.bin $MNT/sl" "truncate -s 5 $MNT/a.bin" "ln $MNT/a.bin $MNT/hl"; do
    $t >>"$LOG" 2>&1 && fail "$n Schreibversuch gelang: $t" || pass "$n Modul antwortet EROFS/Fehler: ${t%% *}"
  done
  chk "$n Lesen weiter moeglich" test "$(md5 -q "$MNT/a.bin")" = "$(grep ' ./a.bin' "$W/$n.ref.md5" | awk '{print $1}')"
  umount "$MNT"; sleep 1; hdiutil detach "$DEV" >>"$LOG" 2>&1; st=$(stats_line 2); say "   $st"
  chk "$n ro_blockiert=$(fld "$st" ro_blockiert) > 0 (Modul-Sperre griff)" test "$(fld "$st" ro_blockiert)" -gt 0
  chk "$n dev_schreibversuche=0, dev_writes=0" test "$(fld "$st" dev_schreibversuche)" = 0 -a "$(fld "$st" dev_writes)" = 0
  chk "$n Abbild-SHA256 vorher == nachher" test "$sha0" = "$(sha "$img")"
  rmw "$n.img" mnt_fgm
}

# Phase 5a: HFS-komprimierte Dateien (decmpfs Typ 7/8, LZVN). Kernel = Orakel (md5 der Kernel-Entpackung == md5 der Quelle, Modul muss gleich liefern);
# Negativproben (unbekannter Typ, kaputte Offsettabelle, abgeschnittener/ungueltiger Block): EIO und KEINE Bytes. Fixtures: decmpfs_fixtures.py
DCFIX="$PWD/decmpfs_fixtures.py"; PREADV="$PWD/pread_vergleich.py"
dc_make() { # name journaled -> $W/name.img (ohne Marker), setzt VUUID; Manifest $W/name.tsv
  local n=$1 f=$W/$1.img d; rmw "$n.img"; truncate -s 160m "$f"
  d=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$f" | awk 'NR==1{print $1}'); newfs_hfs $([ "$2" = 1 ] && echo -J) -v "DC_$n" "${d/disk/rdisk}" >>"$LOG" 2>&1; hdiutil detach "$d" >>"$LOG" 2>&1
  mkdir -p "$W/mnt_$n"; d=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -mountpoint "$W/mnt_$n" "$f" | awk 'NR==1{print $1}')
  VUUID=$(diskutil info "$d" | awk '/Volume UUID/{print $3}')
  python3 -I "$DCFIX" "$W/mnt_$n" "$W/$n.tsv" "$W/$n.good" >>"$LOG" 2>&1; local rc=$?; sync; hdiutil detach "$d" >>"$LOG" 2>&1; return $rc
}
dc_pruefe() { # label mnt manifest : Modul-Mount gegen Manifest
  local lab=$1 mnt=$2 tsv=$3 good=${3%.tsv}.good kind name size md5s typ desc got out err
  while IFS=$'\t' read -r kind name size md5s typ desc; do
    [ "$(stat -f %z "$mnt/$name" 2>/dev/null)" = "$size" ] && pass "$lab $name: Groesse $size" || fail "$lab $name: Groesse $(stat -f %z "$mnt/$name" 2>&1) != $size"
    if [ "$kind" = P ]; then
      got=$(md5 -q "$mnt/$name" 2>/dev/null); [ "$got" = "$md5s" ] && pass "$lab $name (Typ $typ): md5 gleich Kernel/Quelle" || fail "$lab $name (Typ $typ): md5 $got != $md5s"
    else
      cat "$mnt/$name" >"$W/dc_out.bin" 2>"$W/dc_err.txt"; err=$(cat "$W/dc_err.txt"); out=$(wc -c < "$W/dc_out.bin" | tr -d ' ')
      # erlaubt: EIO, davor hoechstens ein byte-genauer Praefix der gueltigen Bloecke (spaetere Lesungen scheitern), nie falsche Bytes
      { echo "$err" | grep -q "Input/output error" && [ "$out" -le "$(wc -c < "$good/$name" | tr -d ' ')" ] && { [ "$out" = 0 ] || [ "$(head -c "$out" "$good/$name" | md5 -q)" = "$(md5 -q "$W/dc_out.bin")" ]; }; } \
        && pass "$lab $name ($desc): EIO nach $out Bytes (korrekter Praefix)" || fail "$lab $name ($desc): $out Bytes, Fehler '$err'"
    fi
  done < "$tsv"
}
t_decmpfs() {
  local J n img sha0 st
  trap fg_zurueck RETURN; fg_sichern
  for J in 0 1; do
    n=dc$J; img=$W/$n.img; say "=== DECMPFS journaled=$J"
    dc_make "$n" $J && pass "$n Fixtures erzeugt (Kernel-Orakel hat jede positive Datei gegen die Quelle geprueft)" || { fail "$n Fixtures"; continue; }
    sha0=$(sha "$img")
    # Kernel-ro-Mount: eigene md5 je positive Datei muss der Quelle entsprechen (zweite Orakel-Lesung, anderer Mount)
    mkdir -p "$W/kro_$n" "$W/dc_ref_$n"; local kd; kd=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -readonly -mountpoint "$W/kro_$n" "$img" | awk 'NR==1{print $1}')
    if [ -n "$kd" ]; then local bad=0 k nm sz m; while IFS=$'\t' read -r k nm sz m _; do [ "$k" = P ] && { [ "$(md5 -q "$W/kro_$n/$nm")" != "$m" ] && bad=1; cp "$W/kro_$n/$nm" "$W/dc_ref_$n/$nm"; }; done < "$W/$n.tsv"; [ $bad = 0 ] && pass "$n Kernel-ro md5 == Quelle (alle positiven)" || fail "$n Kernel-ro md5 weicht ab"; hdiutil detach "$kd" >>"$LOG" 2>&1; else fail "$n Kernel-ro-Mount"; fi
    # (a) Modul nurlesen (Freigabe)
    fg_set "[{\"volume_uuid\":\"$VUUID\",\"modus\":\"nurlesen\",\"max_bytes\":1073741824}]"
    fg_mount "$img" "-o rdonly" && pass "$n mount -F -o rdonly (nurlesen)" || { fail "$n mount nurlesen"; hdiutil detach "$DEV" >/dev/null; continue; }
    dc_pruefe "$n nurlesen" "$MNT" "$W/$n.tsv"
    chk "$n nurlesen: Lesungen mitten im Block/Extent gleich Kernel" python3 -I "$PREADV" "$W/dc_ref_$n" "$MNT" "$W/$n.tsv"
    umount "$MNT"; sleep 1; hdiutil detach "$DEV" >>"$LOG" 2>&1; st=$(stats_line 2); say "   $st"
    chk "$n nurlesen: Schreibzaehler 0" test "$(fld "$st" dev_writes)" = 0 -a "$(fld "$st" dev_schreibversuche)" = 0
    chk "$n nurlesen: Abbild-SHA256 vorher == nachher" test "$sha0" = "$(sha "$img")"
    # (b) Modul beschreibbar (Marker-Kopie)
    local im=$W/${n}_m.img; cp "$img" "$im"; printf 'DROBOFSPROBE' | dd of="$im" bs=1 count=12 conv=notrunc 2>/dev/null
    attach "$im"; MNT=$W/mnt_dcm; fmount "$DEV" "$MNT" && pass "$n mount -F (Marker, rw)" || { fail "$n mount rw"; hdiutil detach "$DEV" >/dev/null; continue; }
    dc_pruefe "$n rw" "$MNT" "$W/$n.tsv"
    chk "$n rw: Lesungen mitten im Block/Extent gleich Kernel" python3 -I "$PREADV" "$W/dc_ref_$n" "$MNT" "$W/$n.tsv"
    umount "$MNT"; sleep 1; hdiutil detach "$DEV" >>"$LOG" 2>&1
    chk "$n fsck_hfs -fn nach rw-Mount OK" fsck_ok "$im"
    rmw "$n.img" "${n}_m.img" "mnt_$n" "kro_$n" "mnt_dcm" "dc_ref_$n"
  done
}

# Phase 5c: Fehlerpfade beim Lesen. NUR mit Pruefbau (XC_EXTRA='SWIFT_ACTIVE_COMPILATION_CONDITIONS=TEST_FEHLER' tools/install_module.sh), danach Normalbau wieder installieren.
# fehler.txt im Modulcontainer: "3 wirf" / "3 kurz" = die 3. grosse Geraetelesung scheitert bzw. kommt halb. Erwartet: EIO, davor nur ein byte-genauer Praefix.
t_fehler() {
  local n=fe img=$W/fe.img CD="$HOME/Library/Containers/$DROBO_MODULE_ID/Data" pfad modus kd sl out err
  trap fg_zurueck RETURN; fg_sichern
  mkplain fe 0 64
  mkdir -p "$W/kro_fe"; kd=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -readonly -mountpoint "$W/kro_fe" "$img" | awk 'NR==1{print $1}'); cp "$W/kro_fe/a.bin" "$W/fe_ref.bin"; hdiutil detach "$kd" >>"$LOG" 2>&1
  for pfad in direkt fallback rw; do for modus in kontrolle wirf kurz; do
    rm -f "$CD/fehler.txt" "$CD/direktweg_aus"; [ $modus != kontrolle ] && echo "3 $modus" > "$CD/fehler.txt"
    case $pfad in
      direkt)   fg_set "[{\"volume_uuid\":\"$VUUID\",\"modus\":\"nurlesen\",\"max_bytes\":1073741824}]"; fg_mount "$img" "-o rdonly" || { fail "fe $pfad mount"; continue; };;
      fallback) touch "$CD/direktweg_aus"; fg_set "[{\"volume_uuid\":\"$VUUID\",\"modus\":\"nurlesen\",\"max_bytes\":1073741824}]"; fg_mount "$img" "-o rdonly" || { fail "fe $pfad mount"; continue; };;
      rw)       cp "$img" "$W/fe_m.img"; printf 'DROBOFSPROBE' | dd of="$W/fe_m.img" bs=1 count=12 conv=notrunc 2>/dev/null; attach "$W/fe_m.img"; MNT=$W/mnt_fe; fmount "$DEV" "$MNT" || { fail "fe rw mount"; continue; };;
    esac
    cat "$MNT/a.bin" > "$W/fe_out.bin" 2> "$W/fe_err.txt"; err=$(cat "$W/fe_err.txt"); out=$(wc -c < "$W/fe_out.bin" | tr -d ' ')
    umount "$MNT"; sleep 2; hdiutil detach "$DEV" >>"$LOG" 2>&1
    sl=$(/usr/bin/log show --last 2m --info --style compact --predicate 'subsystem == "'$DROBO_APP_ID'"' 2>/dev/null | grep "STATS-LESEN" | tail -1 | sed 's/.*STATS-LESEN/STATS-LESEN/')
    [ "$(fld "$sl" fehler_bau)" = 1 ] || { say "SKIP fehler: Modul ist kein Pruefbau TEST_FEHLER (fehler_bau=$(fld "$sl" fehler_bau))"; rm -f "$CD/fehler.txt" "$CD/direktweg_aus"; return; }
    say "   $pfad $modus: $out Bytes, '$err'  [$(echo "$sl" | sed 's/.*direkt_reads/direkt_reads/;s/ max_dev.*//')]"
    if [ $modus = kontrolle ]; then chk "fe $pfad ohne Fehler: md5 gleich" cmp -s "$W/fe_out.bin" "$W/fe_ref.bin"
    else
      # Treffer im Modul-Log belegen; dann entweder EIO mit byte-genauem Praefix ODER (Kernel wiederholt eine gescheiterte Vorauslesung) die komplette Datei byte-gleich
      local hits; hits=$(/usr/bin/log show --last 2m --info --style compact --predicate 'subsystem == "'$DROBO_APP_ID'"' 2>/dev/null | grep -c "Treffer bei grosser Lesung")
      if [ "$hits" -gt 0 ] && echo "$err" | grep -q "Input/output error" && [ "$out" -lt 20000000 ] && { [ "$out" = 0 ] || [ "$(head -c "$out" "$W/fe_ref.bin" | md5 -q)" = "$(md5 -q "$W/fe_out.bin")" ]; }; then pass "fe $pfad $modus: Treffer, EIO nach $out Bytes, Praefix byte-genau"
      elif [ "$hits" -gt 0 ] && [ -z "$err" ] && cmp -s "$W/fe_out.bin" "$W/fe_ref.bin"; then pass "fe $pfad $modus: Treffer, Fehler vom Kernel wiederholt, Datei byte-gleich (kein falsches Byte)"
      else fail "fe $pfad $modus: Treffer=$hits, $out Bytes, '$err', cmp: $(cmp "$W/fe_out.bin" "$W/fe_ref.bin" 2>&1 | head -1)"; fi
    fi
  done; done
  rm -f "$CD/fehler.txt" "$CD/direktweg_aus"
}

# Physischer Fuellstand + harte Platzsperre (Platz.swift). NUR Pruefbau (XC_EXTRA='SWIFT_ACTIVE_COMPILATION_CONDITIONS=TEST_PHYSISCH' tools/install_module.sh):
# physisch.plist im Modulcontainer ersetzt die Registry-Property DroboStatus (gleicher Decoder). Danach Normalbau wieder installieren.
MIB=1048576
ph_set() { # frei_bytes geschuetzt_bytes alter_s -> physisch.plist (p3A_02 wie vom Dext)
  python3 -I - "$CD/physisch.plist" "$1" "$2" "$3" <<'PY2'
import plistlib, struct, sys, time
f, frei, g, alt = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
b = bytes([0x7A, 0x02, 0x00, 0x38]) + struct.pack(">QQQQ", frei, max(g - frei, 0), g, g)
plistlib.dump({"zeit": time.time() - alt, "ok": True, "p3A_02": b}, open(f, "wb"))
PY2
}
ph_schreib() { # datei MiB -> "geschrieben errno" (1 MiB je write, fsync am Ende, Fehler werden gemeldet statt verschluckt)
  python3 -I - "$1" "$2" <<'PY2'
import os, sys
n, fd, e = 0, None, 0
try:
    fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT, 0o644); blk = os.urandom(1 << 20)
    for _ in range(int(sys.argv[2])): n += os.write(fd, blk)
    os.fsync(fd)
except OSError as x: e = x.errno
finally:
    if fd is not None:
        try: os.close(fd)
        except OSError as x: e = e or x.errno
print(n, e)
PY2
}
ph_mount() { attach "$W/ph.img"; MNT=$W/mnt_ph; fmount "$DEV" "$MNT"; }
ph_ende() { umount "$MNT"; sleep 1; hdiutil detach "$DEV" >>"$LOG" 2>&1; ST=$(stats_line 2); say "   $ST"; }
avail() { df -k "$MNT" | awk 'NR==2{print $4*1024}'; }
t_physisch() {
  local CD="$HOME/Library/Containers/$DROBO_MODULE_ID/Data" a r e w1 w2 r1 r2 sum
  trap 'fg_zurueck; rm -f "$CD/physisch.plist"' RETURN; fg_sichern; rm -f "$CD/physisch.plist"
  say "=== PHYSISCH (Platzsperre)"; mkimg ph 1 1g
  # (1) ohne Statusdaten: HFS-Werte, keine Sperre
  ph_mount || { fail "ph mount"; return; }; a=$(avail)
  r=$(ph_schreib "$MNT/frei.bin" 50); umount "$MNT"; sleep 1; hdiutil detach "$DEV" >>"$LOG" 2>&1; ST=$(stats_line 2); say "   $ST"
  [ "$(fld "$ST" physisch_bau)" = 1 ] || { say "SKIP physisch: Modul ist kein Pruefbau TEST_PHYSISCH"; return; }
  echo "$ST" | grep -q "physisch=unbekannt" && pass "ph ohne Daten: STATS physisch=unbekannt" || fail "ph ohne Daten: $ST"
  chk "ph ohne Daten: df verfuegbar $a > 900 MiB (HFS-Wert)" test "$a" -gt $((900*MIB))
  chk "ph ohne Daten: 50 MiB schreiben ($r)" test "$r" = "$((50*MIB)) 0"
  # (2) frei 200 MiB, Reserve 100 MiB: statfs = min, Schreiben ueber die Reserve -> ENOSPC, Bestand bleibt bearbeitbar
  fg_set '{"reserve_bytes": 104857600, "eintraege": []}'; ph_set $((200*MIB)) $((10*1024*MIB)) 0
  ph_mount || { fail "ph mount 2"; return; }; a=$(avail)
  chk "ph min: df verfuegbar $a zwischen 190 und 200 MiB (statt HFS ~1 GiB)" test "$a" -le $((200*MIB)) -a "$a" -ge $((190*MIB))
  r=$(ph_schreib "$MNT/w1.bin" 60); chk "ph 60 MiB unter der Reserve: ok ($r)" test "$r" = "$((60*MIB)) 0"
  a=$(avail); chk "ph nach 60 MiB: df verfuegbar $a zwischen 120 und 140 MiB (Geraetebytes abgezogen)" test "$a" -le $((140*MIB)) -a "$a" -ge $((120*MIB))
  r=$(ph_schreib "$MNT/w2.bin" 80); set -- $r
  chk "ph ueber die Reserve: ENOSPC (errno $2), geschrieben $1 <= 44 MiB" test "$2" = 28 -a "$1" -le $((44*MIB))
  chk "ph Ueberschreiben im Bestand erlaubt" dd if=/dev/urandom of="$MNT/w1.bin" bs=1m count=5 conv=notrunc
  ! truncate -s 120m "$MNT/w1.bin" >>"$LOG" 2>&1 && pass "ph Verlaengern gesperrt" || fail "ph Verlaengern gelang"
  chk "ph Kuerzen erlaubt" truncate -s 10m "$MNT/w1.bin"
  ! touch "$MNT/neu" >>"$LOG" 2>&1 && pass "ph Anlegen gesperrt" || fail "ph Anlegen gelang"
  chk "ph Loeschen erlaubt" rm "$MNT/w1.bin" "$MNT/w2.bin"
  ph_ende; chk "ph platz_gesperrt=$(fld "$ST" platz_gesperrt) > 0" test "$(fld "$ST" platz_gesperrt)" -gt 0
  /usr/bin/log show --last 2m --info --style compact --predicate 'subsystem == "'$DROBO_APP_ID'"' 2>/dev/null | grep -m1 "PLATZ-SPERRE" | sed 's/.*PLATZ/   PLATZ/' | tee -a "$LOG"
  # (3) veraltete Messung (1000 s): letzter Wert minus Geschriebenes, keine Rueckkehr zu HFS
  ph_set $((200*MIB)) $((10*1024*MIB)) 1000; ph_mount || { fail "ph mount 3"; return; }; a=$(avail)
  chk "ph veraltet: df verfuegbar $a <= 200 MiB" test "$a" -le $((200*MIB)); ph_ende
  # (4) Vorgabe-Reserve max(2 %, 500 GB) ohne reserve_bytes
  rm -f "$FREIGABE"; ph_set 400000000000 1000000000000 0; ph_mount || { fail "ph mount 4"; return; }
  ! touch "$MNT/v1" >>"$LOG" 2>&1 && pass "ph Vorgabe-Reserve: 400 GB frei < 500 GB -> Anlegen gesperrt" || fail "ph Vorgabe-Reserve griff nicht"; ph_ende
  ph_set 600000000000 1000000000000 0; ph_mount || { fail "ph mount 5"; return; }
  chk "ph Vorgabe-Reserve: 600 GB frei -> Anlegen erlaubt" touch "$MNT/v1"; ph_ende
  # (5) zwei parallele Schreiber, frei = Reserve + 150 MiB, je 100 MiB: nie beide fertig, Ueberholen hoechstens um laufende Befehle (Toleranz 8 MiB)
  fg_set '{"reserve_bytes": 104857600, "eintraege": []}'; ph_set $((250*MIB)) $((10*1024*MIB)) 0; ph_mount || { fail "ph mount 6"; return; }
  ph_schreib "$MNT/p1.bin" 100 > "$W/p1.out" & ph_schreib "$MNT/p2.bin" 100 > "$W/p2.out" & wait
  r1=$(cat "$W/p1.out"); r2=$(cat "$W/p2.out"); sum=$(( ${r1% *} + ${r2% *} )); say "   parallel: p1=($r1) p2=($r2) Summe=$sum"
  chk "ph parallel: nicht beide fertig" test "${r1#* }" != 0 -o "${r2#* }" != 0
  chk "ph parallel: Summe $sum <= 150 MiB + 8 MiB" test "$sum" -le $((158*MIB))
  ph_ende; rmw ph.img mnt_ph
}

NJ_OK=0; NJ_BAD=0

main() {
  trap 'fg_zurueck; exit 130' INT TERM       # Abbruch (Ctrl-C/kill) stellt die Betreiber-Freigabeliste zurueck
  mksrc
  case "${1:-alles}" in normal) t_normal;; absturz) t_absturz;; sperre) t_sperre;; freigabe) t_freigabe;; freigabe-modul) t_freigabe_modul;; decmpfs) t_decmpfs;; fehler) t_fehler;; physisch) t_physisch;; alles) t_sperre; t_freigabe; t_decmpfs; t_normal; t_absturz;; esac
  say "=== ERGEBNIS PASS=$NPASS FAIL=$NFAIL (Log: $LOG)"; [ "$NFAIL" = 0 ]
}
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
