#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]:-$0}")/identity.sh"; mkdir -p "$DROBO_BUILD/work"
# Phase 5d: Lesedurchsatz am Testabbild (frag_abbild.sh) je Variante, 3 Laeufe frisch gemountet, dd bs=1m ueber alle d*.bin nacheinander, danach sha256-Abgleich.
# Varianten (Schalterdateien im Modulcontainer): alt = direktweg_aus + knotencache_aus (alter fsops_read-Weg), B = Direktweg ohne Knotencache und Lagecache, Bcache = mit Knotencache (Phase 5f), Blage = zusaetzlich Lagecache (Phase 5g).
# CRAWLER=1: waehrend des Lesens laeuft `find MOUNT -ls` in Schleife (Fremdzugriff auf den Katalog, Phase 5e); CRAWLER=scandir: Python os.scandir + stat
# ueber alle Verzeichnisse in Schleife (grosse Verzeichnisse per readdir in Chunks, Phase 5f); Name im Ergebnis mit Suffix +crawler.
# Aufruf: bash messen_modell.sh IMG SHAFILE LABEL [VARIANTEN="alt B cache"]   Ergebnis: $W/modell_LABEL.txt
set -u
IMG=$1; SHA=$2; LAB=$3; VAR=${4:-"alt B Bcache Blage"}; W=${W:-$DROBO_BUILD/work/p5d}; RUNS=${RUNS:-3}
C="$HOME/Library/Containers/$DROBO_MODULE_ID/Data"; F=$C/freigabe.json; RES=$W/modell_$LAB.txt; : > "$RES"; M=$W/mnt_modell
say() { echo "$*" | tee -a "$RES"; }
[ -f "$W/freigabe.orig.json" ] || cp "$F" "$W/freigabe.orig.json"
d=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" | awk 'NR==1{print $1}'); u=$(diskutil info "$d" | awk '/Volume UUID/{print $3}'); hdiutil detach "$d" >/dev/null
python3 -I - "$F" "$W/freigabe.orig.json" "$u" <<'PY'
import json, sys
l = json.load(open(sys.argv[2])); l.append({"volume_uuid": sys.argv[3].upper(), "modus": "nurlesen", "max_bytes": 1 << 36}); json.dump(l, open(sys.argv[1], "w"))
PY
say "== $(date +%Y-%m-%dT%H:%M:%S%z) Abbild $LAB =="
for v in $VAR; do
  rm -f "$C/direktweg_aus" "$C/extentcache_aus" "$C/knotencache_aus" "$C/lage_aus"; case $v in alt) touch "$C/direktweg_aus" "$C/knotencache_aus" "$C/lage_aus";; B) touch "$C/knotencache_aus" "$C/lage_aus";; Bcache) touch "$C/lage_aus";; Blage) ;; esac
  for i in $(seq 1 $RUNS); do
    d=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" | awk 'NR==1{print $1}'); mkdir -p "$M"
    mount -F -t hfsdrobo -o rdonly "$d" "$M" || { sleep 3; mount -F -t hfsdrobo -o rdonly "$d" "$M"; }
    CP=""; if [ "${CRAWLER:-0}" = scandir ]; then rm -f "$W/.crawler_stop"; ( python3 -I -c '
import os, sys
m, stop = sys.argv[1:3]
ds = sorted(e.path for e in os.scandir(m) if e.is_dir())[:int(os.environ.get("CRAWLDIRS", "9999"))]   # CRAWLDIRS=1: nur ein Verzeichnis -> Katalogteil passt in den Knotencache
while not os.path.exists(stop):
    for d in ds:
        if os.path.exists(stop): break
        for e in os.scandir(d): e.stat()
' "$M" "$W/.crawler_stop" ) & CP=$!; echo $CP > "$W/.crawler_pid"
    elif [ "${CRAWLER:-0}" = walk ]; then rm -f "$W/.crawler_stop"; ( python3 -I -c '
import os, sys
m, stop = sys.argv[1:3]
while not os.path.exists(stop):
    for r, ds, fs in os.walk(m):                     # rekursiv ab Wurzel wie ein Indexer
        if os.path.exists(stop): break
        for f in fs: os.lstat(os.path.join(r, f))
' "$M" "$W/.crawler_stop" ) & CP=$!; echo $CP > "$W/.crawler_pid"
    elif [ "${CRAWLER:-0}" = 1 ]; then rm -f "$W/.crawler_stop"; ( while [ ! -f "$W/.crawler_stop" ]; do find "$M" -ls >/dev/null 2>&1 & echo $! > "$W/.crawler_pid"; wait $!; done ) & CP=$!; fi
    t0=$(python3 -c 'import time;print(time.time())'); tot=0
    for f in "$M"/${DATEIEN:-d*.bin}; do n=$(dd if="$f" bs=1m of=/dev/null 2>&1 | awk '/bytes transferred/{print $1}'); tot=$((tot+n)); done
    t1=$(python3 -c 'import time;print(time.time())')
    if [ -n "$CP" ]; then touch "$W/.crawler_stop"; kill $(cat "$W/.crawler_pid") 2>/dev/null; wait $CP 2>/dev/null; rm -f "$W/.crawler_stop" "$W/.crawler_pid"; fi
    say "$v${CRAWLER:+ +crawler} lauf$i $(python3 -c "print('%.1f MB/s (%d MiB in %.1f s)' % ($tot/1e6/($t1-$t0), $tot/1048576, $t1-$t0))")"
    if [ "$i" = 1 ] && [ -z "${DATEIEN:-}" ]; then ok=0; bad=0; while read -r h n; do g=$(shasum -a 256 "$M/$n" | cut -d' ' -f1); [ "$g" = "$h" ] && ok=$((ok+1)) || bad=$((bad+1)); done < "$SHA"; say "   sha256: $ok OK, $bad abweichend"; fi
    umount "$M"; sleep 2; hdiutil detach "$d" >/dev/null
    /usr/bin/log show --last 2m --info --style compact --predicate 'subsystem == "'$DROBO_APP_ID'"' 2>/dev/null | grep -E "STATS-(LESEN|KLEIN|LOCK)" | tail -3 | sed 's/.*STATS-/   STATS-/' | tee -a "$RES"
  done
done
rm -f "$C/direktweg_aus" "$C/extentcache_aus" "$C/knotencache_aus" "$C/lage_aus"; cp "$W/freigabe.orig.json" "$F"
