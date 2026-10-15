#!/bin/bash
# Phase 6: erster Schreibtest auf der Drobo ueber das FSKit-Modul hfsdrobo (Betreiber-Freigabe 2026-10-15: "schreiben ist erlaubt,
# aber bitte ohne unnoetiges risiko!"). Schreibt NUR in einen eigenen Testordner und loescht ihn wieder. Kein Journal-Eingriff.
# Ablauf (jeder Schritt mit STOP bei Abweichung):
#   1 Torpruefung (drobo_lesen.sh --trocken)  2 Metadaten-Sicherung (hfs_attr_diagnose --sichern)  3 hfs_mark_clean --nur-pruefen + VH-Zaehler
#   4 Freigabe auf "schreiben" (Original wird gesichert und bei jedem Ausgang zurueckgestellt)  5 rw-Mount, Testordner schreiben, aushaengen
#   6 ro-Mount, Testdaten zuruecklesen + sha256  7 rw-Mount, Testordner loeschen, aushaengen  8 Freigabe zurueck
#   9 --nur-pruefen + VH-Zaehler gleich Ausgangsstand (Dateien, Ordner, freie Bloecke), Schreibbefehle <= 524288
# Aufruf: bash drobo_schreibtest.sh   (Geraete muessen dem Nutzer gehoeren: sudo chown $USER /dev/diskNsM /dev/rdiskNsM)
set -u
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
TOOLS=$(cd ../../../tools && pwd); UUID=${DROBO_UUID:-C2E343A1-0D4C-3B35-B5DC-0325C1E1E1B1}
MNT=/private/tmp/drobo_schreib_mnt; SICH=${SICH:-/Volumes/daten/drobo_sicherung_nutzer/vor_fskit_schreibtest_$(date +%Y%m%d_%H%M%S)}
SRC=${SRC:-/Volumes/daten/xcode/drobo/schreibtest_quelle}; TEST=_fskit_schreibtest
FG="$HOME/Library/Containers/de.begod.drobofsprobe.fsmodule/Data/freigabe.json"; FGORIG="$FG.vor_schreibtest"
stop() { echo "STOP: $*"; exit 2; }
log_stats() { /usr/bin/log show --last 5m --info --style compact --predicate 'subsystem == "de.begod.drobofsprobe"' 2>/dev/null | grep "STATS unmount" | tail -1 | sed 's/.*STATS/STATS/'; }
aushaengen() { mount | grep -q " $MNT " || return 0; umount "$MNT" 2>/dev/null || diskutil unmount "$MNT" >/dev/null || { sleep 5; diskutil unmount "$MNT" >/dev/null; }; sleep 2; ! mount | grep -q " $MNT "; }
fg_zurueck() { [ -f "$FGORIG" ] && mv -f "$FGORIG" "$FG" && echo "Freigabe zurueckgestellt (nurlesen)"; }
aufraeumen() { aushaengen || echo "WARNUNG: $MNT noch eingehaengt"; fg_zurueck; }
trap aufraeumen EXIT; trap 'exit 130' INT TERM

# ---- 1. Torpruefung ----
DROBO_UUID=$UUID DECMPFS=aus bash drobo_lesen.sh --trocken > /tmp/.dst_tor.$$ 2>&1; R=$?; tail -3 /tmp/.dst_tor.$$; rm -f /tmp/.dst_tor.$$; [ $R = 0 ] || stop "Torpruefung (rc=$R)"
for d in $(diskutil list | awk '/Apple_HFS/{print $NF}'); do diskutil info "$d" | grep -qi "Volume UUID:.*$UUID" && DEV=/dev/$d; done
RDEV=/dev/r${DEV#/dev/}; SIZE=$(diskutil info -plist "$DEV" | plutil -extract IOKitSize raw -)
[ "$(stat -f %Su "$RDEV")" = "$USER" ] || stop "$RDEV gehoert nicht $USER (sudo chown \$USER $DEV $RDEV)"
mount | grep -q "^$DEV " && stop "$DEV ist eingehaengt"

vh() { python3 -I - "$RDEV" <<'PY'
import os, struct, sys
v = os.pread(os.open(sys.argv[1], os.O_RDONLY), 4096, 0)[1024:1536]
a, = struct.unpack_from(">I", v, 4); f, d = struct.unpack_from(">II", v, 32); fb, = struct.unpack_from(">I", v, 48)
print(f"attr=0x{a:08x} dateien={f} ordner={d} frei={fb}")
PY
}
# ---- 2. Sicherung ----
mkdir -p "$(dirname "$SICH")" || stop "Sicherungsordner"
python3 -I "$TOOLS/hfs_attr_diagnose.py" "$RDEV" --sichern "$SICH" --ende "$SIZE" > "$SICH.log" 2>&1 || stop "Sicherung fehlgeschlagen ($SICH.log)"
(cd "$SICH" && shasum -a 256 -c SHA256SUMS >/dev/null) || stop "Sicherung: SHA256SUMS stimmt nicht"
echo "Sicherung: $SICH ($(du -sh "$SICH" | cut -f1))"
# ---- 3. Vorher pruefen ----
python3 -I "$TOOLS/hfs_mark_clean.py" "$RDEV" --ende "$SIZE" --nur-pruefen > "$SICH.pruefen_vorher.txt" 2>&1 || stop "--nur-pruefen vorher ($SICH.pruefen_vorher.txt)"
VORHER=$(vh); echo "VH vorher:  $VORHER"
case "$VORHER" in attr=0x*) ;; *) stop "VH unlesbar";; esac
A=$(echo "$VORHER" | sed -E 's/attr=(0x[0-9a-f]+).*/\1/')
(( A & 0x100 )) || stop "VH: Unmounted-Bit fehlt"; (( A & 0x4800 )) && stop "VH: Inconsistent/BootInconsistent gesetzt"; (( A & 0x2000 )) && stop "VH: Journal an (dieser Test ist fuer ohne Journal)"

# ---- Testquelle ----
mkdir -p "$SRC"; [ -f "$SRC/gross.bin" ] || head -c $((1 << 30)) /dev/urandom > "$SRC/gross.bin"
for i in $(seq 1 20); do [ -f "$SRC/klein_$i.bin" ] || head -c $((i * 37000 + 1)) /dev/urandom > "$SRC/klein_$i.bin"; done
(cd "$SRC" && shasum -a 256 *.bin > ../schreibtest_quelle.sha256) || stop "Quell-Pruefsummen"

# ---- 4. Freigabe schreiben ----
cp -p "$FG" "$FGORIG" || stop "Freigabe sichern"
python3 -I - "$FG" "$UUID" <<'PY' || stop "Freigabe setzen"
import json, sys
p, u = sys.argv[1:3]; l = json.load(open(p)); e = [x for x in l if x.get("volume_uuid") == u]
assert len(e) == 1; e[0]["modus"] = "schreiben"; json.dump(l, open(p, "w"), indent=1)
PY
mkdir -p "$MNT"
# ---- 5. Schreiben ----
mount -F -t hfsdrobo "$DEV" "$MNT" || stop "rw-Mount"
mount | grep " $MNT " | grep -q read-only && stop "Mount ist read-only, Freigabe schreiben nicht wirksam"
[ -e "$MNT/$TEST" ] && stop "$MNT/$TEST existiert schon - nichts angefasst"
mkdir "$MNT/$TEST" && cp "$SRC"/*.bin "$MNT/$TEST/" && sync || { echo "FEHLER beim Schreiben"; }
aushaengen || stop "Aushaengen nach Schreiben"; S1=$(log_stats); echo "$S1"
# ---- 6. Zuruecklesen (ro) ----
mount -F -t hfsdrobo -o rdonly "$DEV" "$MNT" || stop "ro-Mount"
(cd "$MNT/$TEST" && shasum -a 256 -c "$SRC/../schreibtest_quelle.sha256") > "$SICH.zuruecklesen.txt" 2>&1; RL=$?
grep -c ": OK$" "$SICH.zuruecklesen.txt" | sed 's/^/Zuruecklesen OK: /'; aushaengen || stop "Aushaengen nach Lesen"
# ---- 7. Loeschen ----
mount -F -t hfsdrobo "$DEV" "$MNT" || stop "rw-Mount zum Loeschen"
[ -d "$MNT/$TEST" ] && rm -rf "$MNT/$TEST"; sync; [ -e "$MNT/$TEST" ] && echo "FEHLER: Testordner noch da"
aushaengen || stop "Aushaengen nach Loeschen"; S2=$(log_stats); echo "$S2"
# ---- 8. Freigabe zurueck ----
fg_zurueck
# ---- 9. Nachher pruefen ----
python3 -I "$TOOLS/hfs_mark_clean.py" "$RDEV" --ende "$SIZE" --nur-pruefen > "$SICH.pruefen_nachher.txt" 2>&1; NP=$?
NACHHER=$(vh); echo "VH nachher: $NACHHER"
RES=0
[ $RL = 0 ] || { echo "FEHLER: Zuruecklesen ($SICH.zuruecklesen.txt)"; RES=3; }
[ $NP = 0 ] || { echo "FEHLER: --nur-pruefen nachher ($SICH.pruefen_nachher.txt)"; RES=4; }
[ "${VORHER#attr=* }" = "${NACHHER#attr=* }" ] && echo "Dateien/Ordner/freie Bloecke gleich Ausgangsstand: OK" || { echo "FEHLER: Zaehler weichen ab"; RES=5; }
for S in "$S1" "$S2"; do M=$(echo "$S" | grep -oE "max_cmd=[0-9]+" | cut -d= -f2); [ -n "$M" ] && [ "$M" -le 524288 ] || { echo "FEHLER: max_cmd=$M (> 524288 oder fehlt)"; RES=6; }; done
[ $RES = 0 ] && echo "ERGEBNIS: OK" || echo "ERGEBNIS: FEHLER (Code $RES) - Rueckweg: python3 $TOOLS/hfs_meta_restore.py $RDEV $SICH --ende $SIZE (Trockenlauf zuerst)"
exit $RES
