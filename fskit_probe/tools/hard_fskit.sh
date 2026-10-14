#!/bin/bash
# Phase 3 (A): Haertetest ueber den FSKit-Mount (hfsdrobo) an Test-Abbildern. Kernel richtet danach (fsck_hfs -fn, ro-Mount, md5).
# Aufruf: bash hard_fskit.sh [dauer|frag|gross|alles]. NUR Abbilder; Platzbedarf bis ~25 GiB (gross) -> vorher df pruefen.
W=${W:-/Volumes/daten/xcode/drobo/hartfs}
cd "$(dirname "$0")" || exit 2
source ./eich_fskit.sh
LOG=$W/hard_fskit.log; : > "$LOG"
MINFREE_GIB=${MINFREE_GIB:-30}
free_gib() { df -g /Volumes/daten | awk 'NR==2{print $4}'; }

watch_mem() { # pid file
  ( while kill -0 "$1" 2>/dev/null; do echo "$(date +%s) $(ps -o rss=,vsz= -p "$1" 2>/dev/null | tr -s ' ')" >> "$2"; sleep 3; done ) >/dev/null 2>&1 &
  WATCH=$!
}
report_mem() { # file
  python3 -I - "$1" <<'PY'
import sys
rows=[l.split() for l in open(sys.argv[1]) if len(l.split())==3]
if not rows: print("   Speicher: keine Proben"); sys.exit()
r=[int(x[1])/1024 for x in rows]; v=[int(x[2])/1048576 for x in rows]
print("   Speicher Modulprozess: %d Proben, RSS min/max/Ende = %.0f / %.0f / %.0f MiB, VSZ Ende %.1f GiB, RSS-Anstieg 1.->letztes Viertel: %+.0f MiB" % (len(rows), min(r), max(r), r[-1], v[-1], (sum(r[-len(r)//4:])/max(1,len(r[-len(r)//4:])))-(sum(r[:max(1,len(r)//4)])/max(1,len(r[:max(1,len(r)//4)])))))
PY
}
hmount() { # img name  -> DEV MNT MODPID WATCH ; Modulprozess = der fuer diesen Mount neu gestartete
  local img=$1 n=$2 before p
  attach "$img"; MNT=$W/mnt_$n; before=$(pgrep -x DroboFSProbeModule | tr '\n' ' ')
  fmount "$DEV" "$MNT" || return 1
  MODPID=""; for p in $(pgrep -x DroboFSProbeModule); do case " $before " in *" $p "*) ;; *) MODPID=$p;; esac; done
  rm -f "$W/$n.mem"; [ -n "$MODPID" ] && watch_mem "$MODPID" "$W/$n.mem"
}
hunmount() { # name
  local t0 t1; t0=$(now); umount "$MNT"; t1=$(now); say "   umount: $(python3 -c "print('%.1f s' % ($t1-$t0))")"; sleep 1
  kill "$WATCH" 2>/dev/null; report_mem "$W/$1.mem" | tee -a "$LOG"
  ST=$(stats_line 4); say "   $ST"
  chk "$1 max Geraete-Schreibbefehl $(fld "$ST" max_cmd) <= 524288" test "$(fld "$ST" max_cmd)" -le 524288 -a "$(fld "$ST" max_cmd)" -gt 0
  say "   Geraeteverkehr/Nutzdaten = $(python3 -c "n=$(fld "$ST" nutz_geschrieben);print('%.2f' % ($(fld "$ST" dev_bytes)/n) if n else 'n/a')")"
  hdiutil detach "$DEV" >>"$LOG" 2>&1
}
kjudge() { # name img [md5file-in-root relpath expected]  : fsck + ro-Mount, optional md5 einer Datei
  local n=$1 img=$2
  chk "$n fsck_hfs -fn nach Unmount appears to be OK" fsck_ok "$img"
  mkdir -p "$W/kro_$n"; local kd; kd=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -noverify -readonly -mountpoint "$W/kro_$n" "$img" | awk 'NR==1{print $1}')
  if [ -z "$kd" ]; then fail "$n Kernel-ro-Mount verweigert"; return; fi
  pass "$n Kernel-ro-Mount moeglich"
  if [ -n "${3:-}" ]; then local got; got=$(md5 -q "$W/kro_$n/$3"); chk "$n Kernel-ro-Mount md5 $3 gleich" test "$got" = "$4"; fi
  hdiutil detach "$kd" >>"$LOG" 2>&1; rmw "kro_$n"
}
big4g() { [ -f "$W/big4g.bin" ] || head -c 4294967296 /dev/urandom > "$W/big4g.bin"; [ -f "$W/big4g.md5" ] || md5 -q "$W/big4g.bin" > "$W/big4g.md5"; }

t_dauer() {
  local J cyc i n img t0 t1 sm want free0
  big4g; want=$(cat "$W/big4g.md5")
  for J in 1 0; do
    cyc=16; [ $J = 0 ] && cyc=4
    n=dauer$J; img=$W/$n.img; say "=== DAUERLAST journaled=$J: $cyc x 4 GiB schreiben, md5, loeschen ($((cyc*4)) GiB)"
    mkimg "$n" $J 6g; hmount "$img" "$n" || { fail "$n mount"; continue; }
    free0=$(df -k "$MNT" | awk 'NR==2{print $4}')
    for i in $(seq 1 $cyc); do
      t0=$(now); cp "$W/big4g.bin" "$MNT/cyc.bin"; t1=$(now); sm=$(python3 -c "print('%.0f' % (4096/($t1-$t0)))")
      local got; got=$(md5 -q "$MNT/cyc.bin"); local t2; t2=$(now)
      [ "$got" = "$want" ] && say "   Zyklus $i/$cyc: schreiben $sm MB/s, lesen+md5 $(python3 -c "print('%.0f' % (4096/($t2-$t1)))") MB/s, md5 ok, Modul-RSS $(ps -o rss= -p "$MODPID" | awk '{printf "%.0f MiB", $1/1024}')" || { fail "$n Zyklus $i md5 FALSCH ($got)"; break; }
      [ $i -lt $cyc ] && rm "$MNT/cyc.bin"
    done
    pass "$n $cyc Zyklen x 4 GiB ohne md5-Fehler (insgesamt $((cyc*4)) GiB geschrieben und gelesen)"
    chk "$n freier Platz am Ende plausibel" test "$(df -k "$MNT" | awk 'NR==2{print $4}')" -lt "$free0"
    hunmount "$n"; kjudge "$n" "$img" cyc.bin "$want"; rmw "$n.img" "mnt_$n"
  done
}

t_frag() {
  local J n img big want
  big4g; head -c 104857600 "$W/big4g.bin" | md5 -q > "$W/frag.want"; want=$(cat "$W/frag.want")
  for J in 1 0; do
    n=frag$J; img=$W/$n.img; say "=== FRAGMENTIERUNG journaled=$J: Volume mit 8-KiB-Dateien fuellen, jede zweite loeschen, 100-MiB-Datei in die Luecken"
    mkimg "$n" $J 256m; hmount "$img" "$n" || { fail "$n mount"; continue; }
    python3 -I - "$MNT" <<'PY'
import os,sys
d=sys.argv[1]; blob=b'x'*8192; last=0
for n in range(200000):
    try:
        with open('%s/s%06d'%(d,n),'wb') as f: f.write(blob)
        last=n
    except OSError: break
for i in range(0,last+1,2):
    try: os.remove('%s/s%06d'%(d,i))
    except OSError: pass
print("angelegt %d, geloescht %d" % (last+1,(last+2)//2))
PY
    sync; dd if="$W/big4g.bin" of="$MNT/frag.bin" bs=1m count=100 2>&1 | tail -1 | tee -a "$LOG"
    chk "$n 100-MiB-Datei in zerstueckeltem Freiraum md5 gleich" test "$(md5 -q "$MNT/frag.bin")" = "$want"
    hunmount "$n"
    python3 -I "$M/hfsdump.py" "$img" extents | tee -a "$LOG" | tail -1 | cut -c1-200
    local ov; ov=$(python3 -I "$M/hfsdump.py" "$img" extents | sed -n 's/.*Extents-Ueberlauf: \([0-9]*\) Saetze.*/\1/p')
    chk "$n Extents-Ueberlauf-Baum benutzt ($ov Saetze, >= 100)" test "${ov:-0}" -ge 100
    kjudge "$n" "$img" frag.bin "$want"
    # Loeschen ueber den Modulmount: Truncate einer Datei mit tausenden Extents, danach alles weg
    hmount "$img" "${n}b" || { fail "$n 2. mount"; continue; }
    rm "$MNT/frag.bin"; rm -f "$MNT"/s* ; ls "$MNT" | wc -l | xargs echo "   Dateien nach Loeschen:" | tee -a "$LOG"
    hunmount "${n}b"
    chk "$n nach Loeschen fsck OK" fsck_ok "$img"
    python3 -I "$M/hfsdump.py" "$img" extents | head -1 | tee -a "$LOG" | cut -c1-160
    rmw "$n.img" "mnt_$n" "mnt_${n}b"
  done
}

t_gross() {
  local n=gross img want f
  [ "$(free_gib)" -ge "$MINFREE_GIB" ] || { say "SKIP gross: nur $(free_gib) GiB frei (< $MINFREE_GIB)"; return; }
  big4g; want=$( (for i in 1 2 3 4; do cat "$W/big4g.bin"; done; head -c 1073741824 "$W/big4g.bin") | md5 -q )
  img=$W/$n.img; say "=== GROSSE DATEI: 17 GiB (> 16 GiB) auf 20-GiB-Abbild, journaled"
  mkimg "$n" 1 20g; hmount "$img" "$n" || { fail "$n mount"; return; }
  local t0 t1; t0=$(now)
  for i in 1 2 3 4; do cat "$W/big4g.bin" >> "$MNT/huge.bin"; done; dd if="$W/big4g.bin" bs=1m count=1024 2>/dev/null >> "$MNT/huge.bin"; sync; t1=$(now)
  say "   schreiben 17 GiB: $(python3 -c "print('%.0f MB/s' % (17408/($t1-$t0)))"), Groesse $(stat -f %z "$MNT/huge.bin") (erwartet 18253611008), Modul-RSS $(ps -o rss= -p "$MODPID" | awk '{printf "%.0f MiB", $1/1024}')"
  chk "$n Groesse 18253611008" test "$(stat -f %z "$MNT/huge.bin")" = 18253611008
  t0=$(now); chk "$n 17-GiB-Datei ueber den Mount md5 gleich" test "$(md5 -q "$MNT/huge.bin")" = "$want"; t1=$(now)
  say "   lesen+md5: $(python3 -c "print('%.0f MB/s' % (17408/($t1-$t0)))")"
  hunmount "$n"; kjudge "$n" "$img" huge.bin "$want"
  # Direktweg (Hebel B) ueber 4 GiB: dasselbe Abbild NUR LESEND ueber die Freigabeliste (Marker entfernen), md5 == Referenz, direkt_reads > 0
  trap fg_zurueck RETURN; fg_sichern
  printf '\0\0\0\0\0\0\0\0\0\0\0\0' | dd of="$img" bs=1 count=12 conv=notrunc 2>/dev/null
  attach "$img"; local vu; vu=$(diskutil info "$DEV" | awk '/Volume UUID/{print $3}'); hdiutil detach "$DEV" >>"$LOG" 2>&1
  fg_set "[{\"volume_uuid\":\"$vu\",\"modus\":\"nurlesen\",\"max_bytes\":22548578304}]"
  if fg_mount "$img" "-o rdonly"; then
    t0=$(now); chk "$n nurlesen (Direktweg): 17-GiB-Datei md5 gleich Referenz" test "$(md5 -q "$MNT/huge.bin")" = "$want"; t1=$(now)
    say "   nurlesen lesen+md5: $(python3 -c "print('%.0f MB/s' % (17408/($t1-$t0)))")"
    umount "$MNT"; sleep 2; hdiutil detach "$DEV" >>"$LOG" 2>&1
    local sl; sl=$(/usr/bin/log show --last 5m --info --style compact --predicate 'subsystem == "de.begod.drobofsprobe"' 2>/dev/null | grep "STATS-LESEN" | tail -1 | sed 's/.*STATS-LESEN/STATS-LESEN/'); say "   $sl"
    chk "$n nurlesen: direkt_reads=$(fld "$sl" direkt_reads) > 0, fallback_reads=$(fld "$sl" fallback_reads)" test "$(fld "$sl" direkt_reads)" -gt 0
  else fail "$n nurlesen mount"; hdiutil detach "$DEV" >>"$LOG" 2>&1; fi
  rmw "$n.img" "mnt_$n"
}

mainh() { case "${1:-alles}" in dauer) t_dauer;; frag) t_frag;; gross) t_gross;; alles) t_frag; t_dauer; t_gross;; esac
  say "=== ERGEBNIS PASS=$NPASS FAIL=$NFAIL (Log: $LOG)"; [ "$NFAIL" = 0 ]; }
mainh "$@"
