#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]:-$0}")/identity.sh"; mkdir -p "$DROBO_BUILD/work"
# Phase 5 Schritt 2: Hebel B (Direktweg) messen. Abbild $W/p5.img (aus messen_lesen.sh prep), Modul nurlesen, je Zelle 3 Laeufe frisch gemountet.
# Aufruf:  bash messen_direkt.sh freigabe          Freigabeeintrag fuers Abbild (Sicherung in $W/freigabe.orig.json, falls noch keine)
#          bash messen_direkt.sh messen NAME       Zellen alt+neu fuer den installierten Bau (STATS-LESEN zeigt drobo_bau=0/1); Ergebnis $W/direkt_NAME.txt
#          (REV=1: erst alt, dann neu)
#          bash messen_direkt.sh fallback          md5 von komprimierter und fragmentierter Datei ueber das Modul (neuer Weg), Vergleich mit $W/src2.md5
#          bash messen_direkt.sh abbau             Freigabeliste zurueckstellen, Schalter direktweg_aus entfernen
# Schalter: Datei $HOME/Library/Containers/$DROBO_MODULE_ID/Data/direktweg_aus = alter Weg (nur Messung).
set -u
W=${W:-$DROBO_BUILD/work/p5messung}; IMG=$W/p5.img; LOG=$W/direkt.log
C="$HOME/Library/Containers/$DROBO_MODULE_ID/Data"; FREIGABE=$C/freigabe.json; SCHALTER=$C/direktweg_aus
RUNS=${RUNS:-3}
say() { echo "$*" | tee -a "$RES"; }
mbs() { python3 -c "print('%.1f' % ($1/1e6))"; }
attach_img() { hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" | awk 'NR==1{print $1}'; }
stats() { sleep 2; /usr/bin/log show --last 2m --info --style compact --predicate 'subsystem == "'$DROBO_APP_ID'"' 2>/dev/null | grep "STATS" | tail -2 | sed 's/.*STATS/STATS/'; }
fmount() { mkdir -p "$2"; mount -F -t hfsdrobo -o rdonly "$1" "$2" >>"$LOG" 2>&1 || { sleep 3; mount -F -t hfsdrobo -o rdonly "$1" "$2" >>"$LOG" 2>&1; }; }
shaok() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$(grep " $2" "$W/src.sha256" | cut -d' ' -f1)" ] && echo OK || echo FALSCH; }

freigabe() {
  [ -f "$W/freigabe.orig.json" ] || cp "$FREIGABE" "$W/freigabe.orig.json"
  local d u sz; d=$(attach_img); diskutil info "$d" | grep -Eq '^ *Protocol: *Disk Image' || { echo "kein Abbild"; exit 1; }
  u=$(diskutil info "$d" | sed -n 's/.*Volume UUID: *//p'); sz=$(diskutil info -plist "$d" | python3 -I -c 'import plistlib,sys;print(plistlib.loads(sys.stdin.buffer.read()).get("TotalSize",0))'); hdiutil detach "$d" >>"$LOG"
  python3 -I - "$FREIGABE" "$W/freigabe.orig.json" "$u" "$sz" <<'PY'
import json, sys
p, orig, u, sz = sys.argv[1:]
l = json.load(open(orig)); l = l if isinstance(l, list) else l.get("eintraege", [])
l.append({"volume_uuid": u.upper(), "modus": "nurlesen", "max_bytes": int(sz) + (1 << 30), "notiz": "Phase5-Messung Abbild"})
json.dump(l, open(p, "w"), indent=1); print("Freigabe:", [e["volume_uuid"] for e in l])
PY
}

zelle() { # label : Schalter bereits gesetzt
  local lab=$1 i d M=$W/mnt_direkt r mb
  for i in $(seq 1 $RUNS); do
    d=$(attach_img); diskutil info "$d" | grep -Eq '^ *Protocol: *Disk Image' || { say "ABBRUCH $d kein Abbild"; return; }
    fmount "$d" "$M" || { say "FEHLER modul-mount $lab"; hdiutil detach "$d" >>"$LOG"; continue; }
    r=$(dd if="$M/f1.bin" of=/dev/null bs=1m 2>&1 | tail -1 | sed -n 's/.*(\([0-9]*\) bytes\/sec).*/\1/p'); mb=$(mbs "${r:-0}")
    say "$lab lauf$i f1.bin bs=1m  ${mb} MB/s  (${r} bytes/sec)"
    if [ "$i" = 1 ]; then say "   sha256 f1 $(shaok "$M/f1.bin" f1.bin) f2 $(shaok "$M/f2.bin" f2.bin) f3 $(shaok "$M/f3.bin" f3.bin) f4 $(shaok "$M/f4.bin" f4.bin)"; fi
    umount "$M" >>"$LOG" 2>&1; hdiutil detach "$d" >>"$LOG" 2>&1; stats | sed 's/^/   /' | tee -a "$RES"
  done
}

case "${1:-}" in
  freigabe) freigabe;;
  messen) RES=$W/direkt_${2:?name}.txt; : > "$RES"; say "== $(date +%Y-%m-%dT%H:%M:%S%z) Bau=$2 =="
    if [ "${REV:-0}" = 1 ]; then touch "$SCHALTER"; zelle "alt(libLock)"; rm -f "$SCHALTER"; zelle "neu(direkt)"
    else rm -f "$SCHALTER"; zelle "neu(direkt)"; touch "$SCHALTER"; zelle "alt(libLock)"; fi; rm -f "$SCHALTER"; say "== Ende ==";;
  fallback) RES=$W/direkt_fallback.txt; : > "$RES"; rm -f "$SCHALTER"
    for f in ${FILES:-frag1.bin luecke.bin komp.txt}; do
      d=$(attach_img); M=$W/mnt_direkt; fmount "$d" "$M" || { say "FEHLER mount"; exit 1; }
      say "md5 modul $f $(md5 -q "$M/$f")  erwartet $(grep " $f" "$W/src2.md5" | cut -d' ' -f1)  $(ls -lO "$M/$f" | awk '{print $5,$6}')"
      umount "$M" >>"$LOG" 2>&1; hdiutil detach "$d" >>"$LOG" 2>&1; stats | grep STATS-LESEN | sed 's/^/   /' | tee -a "$RES"
    done;;
  abbau) rm -f "$SCHALTER"; cp "$W/freigabe.orig.json" "$FREIGABE"; cat "$FREIGABE";;
  *) sed -n 2,8p "$0";;
esac
