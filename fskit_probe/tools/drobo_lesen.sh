#!/bin/bash
# Betreiberwerkzeug Phase 4: Drobo-Volume NUR LESEND ueber das FSKit-Modul hfsdrobo einhaengen, Leseliste pruefen, aushaengen, Wirt-Pruefsummen vergleichen.
# Schreibt nie auf die Drobo: Modul-Modus "nurlesen" (Freigabeliste), mount -o rdonly, Schreibzaehler muss 0 bleiben.
# Aufruf:  bash drobo_lesen.sh --trocken            nur finden und pruefen (kein Mount)
#          bash drobo_lesen.sh --freigabe-anlegen   Eintrag {uuid, nurlesen, max_bytes} in die Freigabeliste des Moduls schreiben
#          bash drobo_lesen.sh                      Lesetest (mount -F -t hfsdrobo -o rdonly, Leseliste, umount, Wirt-Vergleich)
# Umgebung (fuer Tests am Abbild): DROBO_UUID, DEV (z. B. /dev/disk7s2; Pflicht: diskutil zeigt dort DROBO_UUID), MNT, LISTE.
set -u
UUID=${DROBO_UUID:-C2E343A1-0D4C-3B35-B5DC-0325C1E1E1B1}
LISTE=${LISTE:-$HOME/Desktop/drobo_leseliste.json}
MNT=${MNT:-$HOME/drobo_lesen_mnt}
FREIGABE="$HOME/Library/Containers/de.begod.drobofsprobe.fsmodule/Data/freigabe.json"
MODE=lesen; case "${1:-}" in --trocken) MODE=trocken;; --freigabe-anlegen) MODE=anlegen;; "") ;; *) sed -n 2,9p "$0"; exit 2;; esac
stop() { echo "STOP: $*"; exit "${CODE:-1}"; }
now() { python3 -c 'import time;print(time.time())'; }

# ---- 1. Geraet finden (per Volume-UUID) ----
if [ -z "${DEV:-}" ]; then
  for d in $(diskutil list | grep -oE 'disk[0-9]+(s[0-9]+)?' | sort -u); do
    diskutil info "$d" 2>/dev/null | grep -qi "Volume UUID:.*$UUID" && { DEV=/dev/$d; break; }
  done
fi
[ -n "${DEV:-}" ] || stop "kein Geraet mit Volume-UUID $UUID gefunden (diskutil list pruefen; Drobo am Mac angeschlossen? Kernel erkennt das Volume nicht?)"
diskutil info "$DEV" | grep -qi "Volume UUID:.*$UUID" || stop "$DEV traegt nicht die UUID $UUID"
RDEV=/dev/r${DEV#/dev/}
echo "Geraet: $DEV  (UUID $UUID)"
diskutil info "$DEV" | grep -E "Device / Media Name|Volume Name|File System Personality|Disk Size|Mounted|Protocol|Virtual" | sed 's/^ */  /'

# ---- 2. Vorpruefungen ----
diskutil info "$DEV" | grep -qE "Mounted: *Yes" && stop "$DEV ist am Mac eingehaengt (zuerst: diskutil unmount $DEV)"
mount | grep -q "^$DEV " && stop "$DEV steht in mount"
if pgrep -fl qemu >/dev/null 2>&1; then
  echo "Hinweis: QEMU laeuft:"; pgrep -fl qemu | cut -c1-140 | sed 's/^/  /'
  lsof "$DEV" "$RDEV" 2>/dev/null | grep -qi qemu && stop "QEMU hat $DEV oder $RDEV offen (VM zuerst beenden)"
fi
lsof "$DEV" "$RDEV" 2>/dev/null | grep -v "^COMMAND" | head -3 | sed 's/^/  offen: /'

python3 -I - "$RDEV" "$DEV" <<'PY' || exit $?
import os, struct, sys
rdev, dev = sys.argv[1:3]
try: fd = os.open(rdev, os.O_RDONLY)
except PermissionError:
    print("STOP: keine Leseberechtigung auf %s. Betreiber fuehrt aus:\n   sudo chown $USER %s %s" % (rdev, dev, rdev)); sys.exit(4)
head = os.pread(fd, 4096, 0)
vh = head[1024:1536]
sig = vh[:2]
if sig not in (b'H+', b'HX'): print("STOP: kein HFS+/HFSX-Volume-Header (Signatur %r)" % sig); sys.exit(5)
attr = struct.unpack('>I', vh[4:8])[0]; bs = struct.unpack('>I', vh[40:44])[0]
print("VH: attr=%#x lastMountedVersion=%s journaled=%s blocksize=%d files=%d" % (attr, vh[8:12], bool(attr & 0x2000), bs, struct.unpack('>I', vh[32:36])[0]))
bad = []
if not attr & 0x100: bad.append("0x100 (sauber ausgehaengt) NICHT gesetzt")
if attr & 0x800: bad.append("0x800 (inkonsistent) gesetzt")
if attr & 0x4000: bad.append("0x4000 gesetzt")
if attr & 0x2000:
    jib = os.pread(fd, 4096, struct.unpack('>I', vh[12:16])[0] * bs)[:512]
    if struct.unpack('>I', jib[:4])[0] & 4: print("Journal: nie benutzt (needs init) -> leer")
    else:
        off = struct.unpack('>Q', jib[36:44])[0]
        jh = os.pread(fd, 4096, off)[:512]
        start, end = struct.unpack('<QQ', jh[8:24])
        print("Journal: start=%d end=%d -> %s" % (start, end, "leer" if start == end else "NICHT LEER"))
        if start != end: bad.append("Journal nicht leer (Replay wuerde schreiben)")
if bad: print("STOP: " + "; ".join(bad)); sys.exit(6)
print("Vorpruefung OK")
PY

# ---- 3. Freigabeliste ----
if [ "$MODE" = anlegen ] || ! grep -qi "$UUID" "$FREIGABE" 2>/dev/null; then
  SZ=$(diskutil info -plist "$DEV" | python3 -I -c 'import plistlib,sys;print(plistlib.loads(sys.stdin.buffer.read()).get("TotalSize",0))')
  if [ "$MODE" = anlegen ]; then
    python3 -I - "$FREIGABE" "$UUID" "$SZ" <<'PY'
import json, os, sys
p, u, sz = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.makedirs(os.path.dirname(p), exist_ok=True)
try: a = json.load(open(p))
except Exception: a = []
a = [e for e in (a if isinstance(a, list) else a.get("eintraege", [])) if e.get("volume_uuid", "").upper() != u.upper()]
a.append({"volume_uuid": u.upper(), "modus": "nurlesen", "max_bytes": sz + (1 << 30)})
json.dump(a, open(p, "w"), indent=1); print("Freigabe geschrieben:", p)
PY
    exit 0
  fi
  echo "Freigabeliste hat keinen Eintrag fuer $UUID. Betreiber fuehrt aus:"; echo "   bash $0 --freigabe-anlegen"; echo "(legt $FREIGABE mit modus nurlesen und max_bytes=$((SZ + 1073741824)) an)"
  [ "$MODE" = trocken ] || exit 3
fi
[ "$MODE" = trocken ] && { echo "trocken: bis hierher OK, nichts gemountet"; exit 0; }

# ---- 4. Wirt-Pruefsummen VOR dem Mount ----
HOSTSUM() { python3 -I - "$RDEV" "$DEV" <<'PY'
import hashlib, os, plistlib, subprocess, sys
rdev, dev = sys.argv[1:3]
size = plistlib.loads(subprocess.check_output(["diskutil", "info", "-plist", dev]))["TotalSize"]
fd = os.open(rdev, os.O_RDONLY); M = 1 << 20
vh = os.pread(fd, 4096, 0)[1024:1536]
print("VH", hashlib.sha256(vh).hexdigest()[:32], "erstes_MiB", hashlib.sha256(os.pread(fd, M, 0)).hexdigest()[:32], "letztes_MiB", hashlib.sha256(os.pread(fd, M, size - M)).hexdigest()[:32])
PY
}
PRE=$(HOSTSUM) || stop "Wirt-Pruefsumme vorher fehlgeschlagen"; echo "Wirt vorher:  $PRE"

# ---- 5. Mount, nur lesend ----
mkdir -p "$MNT"
MOUT=$(mount -F -t hfsdrobo -o rdonly "$DEV" "$MNT" 2>&1); RC=$?
if [ $RC != 0 ]; then
  echo "mount: $MOUT"
  case "$MOUT" in *"ermission"*|*EACCES*|*"Operation not permitted"*) echo "Zugriffsrecht fehlt. Betreiber fuehrt aus:   sudo chown \$USER $DEV $RDEV   (dann Skript erneut)";; esac
  echo "Modul-Log:"; /usr/bin/log show --last 2m --info --style compact --predicate 'subsystem == "de.begod.drobofsprobe"' 2>/dev/null | sed 's/.*\] /  /' | tail -8
  stop "Mount fehlgeschlagen (nichts geschrieben; Wirt-Vergleich unten)"
fi
mount | grep -iF " $MNT " | grep -q read-only || { umount "$MNT"; stop "Mount ist NICHT read-only gemeldet -> ausgehaengt"; }
echo "eingehaengt (read-only): $MNT"

# ---- 6. Lesetest gegen die Leseliste ----
RES=0
if [ -f "$LISTE" ]; then
python3 -I - "$MNT" "$LISTE" <<'PY' || RES=$?
import hashlib, json, os, sys, time
mnt, liste = sys.argv[1:3]
j = json.load(open(liste)); a = j if isinstance(j, list) else (j.get("dateien") or j.get("eintraege") or [])
CAP = 256 << 20; ok = bad = 0; tot = 0; t_all = time.time()
print("%-60s %12s %9s  %s" % ("Datei", "Bytes", "MB/s", "Ergebnis"))
for e in a:
    rel = e.get("pfad") or e.get("path") or e.get("datei"); want = (e.get("sha256") or e.get("sha256_256mib") or e.get("sha") or "").lower()
    p = os.path.join(mnt, rel.lstrip("/"))
    try:
        t0 = time.time(); h = hashlib.sha256(); n = 0
        with open(p, "rb") as f:
            while n < CAP:
                b = f.read(min(8 << 20, CAP - n))
                if not b: break
                h.update(b); n += len(b)
        dt = max(time.time() - t0, 1e-9); got = h.hexdigest()
        r = "OK" if got == want else "ABWEICHUNG (%s...)" % got[:12]
        ok += got == want; bad += got != want; tot += n
        print("%-60s %12d %9.1f  %s" % (rel[-60:], n, n / 1e6 / dt, r))
    except Exception as ex:
        bad += 1; print("%-60s %12s %9s  FEHLER %s" % (rel[-60:], "-", "-", ex))
dt = max(time.time() - t_all, 1e-9)
print("Leseliste: %d OK, %d Abweichung/Fehler, %.1f MiB in %.1f s = %.1f MB/s gesamt" % (ok, bad, tot / 1048576, dt, tot / 1e6 / dt))
sys.exit(0 if bad == 0 and ok > 0 else 7)
PY
else echo "Leseliste $LISTE fehlt -> nur Verzeichnisliste:"; ls -la "$MNT" | head -20; RES=8; fi

# ---- 7. Aushaengen, Wirt-Vergleich, Modul-Zaehler ----
umount "$MNT" || { sleep 2; umount "$MNT"; }; sleep 2
POST=$(HOSTSUM); echo "Wirt nachher: $POST"
[ "$PRE" = "$POST" ] && echo "Wirt-Pruefsummen vorher == nachher: OK" || { echo "WARNUNG: Wirt-Pruefsummen ABWEICHEND"; RES=9; }
ST=$(/usr/bin/log show --last 15m --info --style compact --predicate 'subsystem == "de.begod.drobofsprobe"' 2>/dev/null | grep "STATS unmount" | tail -1 | sed 's/.*STATS/STATS/')
echo "$ST"
echo "$ST" | grep -q " dev_writes=0 " && echo "$ST" | grep -q "dev_schreibversuche=0" && echo "Schreibzaehler 0: OK" || { echo "WARNUNG: Schreibzaehler nicht 0 oder nicht auffindbar"; RES=10; }
[ $RES = 0 ] && echo "ERGEBNIS: OK" || echo "ERGEBNIS: FEHLER (Code $RES)"
exit $RES
