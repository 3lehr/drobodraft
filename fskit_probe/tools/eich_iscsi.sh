#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]:-$0}")/identity.sh"; mkdir -p "$DROBO_BUILD/work"
# Eichung des iSCSI-Moduls (mount -F -t hfsdropro) gegen das Python-Pruefziel (drobo_kern/Tests/iscsi_ziel.py) ueber Abbilddateien.
# Beruehrt NUR Abbilddateien unter $W, einen lokalen Python-Prozess (eigene PID) und Loopback. Nie ein Drobo, nie ein fremdes Geraet.
# Ablauf: Ziel starten -> LUN 1 per `drobo iscsi-format` einrichten -> Ablehnungen -> mount, schreiben, umount, mount, vergleichen -> fsck_hfs -fn.
# Voraussetzung: Modul hfsdropro installiert UND freigeschaltet (tools/install_module.sh), CLI gebaut (cd drobo_kern && xcrun swift build).
set -u
exec </dev/null
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2
M=$(cd ../.. && pwd)
W=${W:-$DROBO_BUILD/work/eichiscsi}; mkdir -p "$W"
SHORT=hfsdropro; SUBSYS="$DROBO_APP_ID.iscsi"
CLI=${CLI:-$M/drobo_kern/.build/debug/drobo}
LOG=$W/eich_iscsi.log; : > "$LOG"
NPASS=0; NFAIL=0
say()  { echo "$*" | tee -a "$LOG"; }
pass() { NPASS=$((NPASS+1)); say "PASS $*"; }
fail() { NFAIL=$((NFAIL+1)); say "FAIL $*"; }
chk()  { local name=$1; shift; if "$@" >>"$LOG" 2>&1; then pass "$name"; else fail "$name"; fi; }
MODLOG() { /usr/bin/log show --start "$1" --info --style compact --predicate 'subsystem == "'$SUBSYS'"' 2>/dev/null; }
modul_lehnte_ab() { sleep 1; MODLOG "$1" | grep -qE "(probe|load).*abgelehnt"; }   # T0 -> 0, wenn das Modul seit T0 selbst "abgelehnt" protokollierte
nowlog() { date "+%Y-%m-%d %H:%M:%S"; }
TPID=""; MNT=$W/mnt
cleanup() { mount | grep -q " on $MNT " && umount "$MNT" >/dev/null 2>&1; [ -n "$TPID" ] && kill "$TPID" 2>/dev/null; [ -n "${DEVA:-}" ] && hdiutil detach "$DEVA" -force >/dev/null 2>&1; }
trap cleanup EXIT

[ -x "$CLI" ] || { say "ABBRUCH: CLI $CLI fehlt (cd drobo_kern && xcrun swift build)"; exit 2; }
rm -rf "$W/l0.img" "$W/l1.img" "$W/ziel.jsonl" "$W/ziel.out" "$MNT"; mkdir -p "$MNT"
truncate -s 16m "$W/l0.img"; truncate -s ${LUNMIB:-512}m "$W/l1.img"
python3 -I "$M/drobo_kern/Tests/iscsi_ziel.py" --image "$W/l0.img" --image "$W/l1.img" --log "$W/ziel.jsonl" > "$W/ziel.out" 2>&1 & TPID=$!
for i in 1 2 3 4 5 6 7 8 9 10; do grep -q '^PORT' "$W/ziel.out" && break; sleep 0.5; done
PORT=$(sed -n 's/^PORT //p' "$W/ziel.out"); [ -n "$PORT" ] || { say "ABBRUCH: Ziel startete nicht"; exit 2; }
IQN=iqn.2026-10.local.test:ziel; URL1="iscsi://127.0.0.1:$PORT/$IQN/1"
export DROBO_ISCSI_HOST=127.0.0.1 DROBO_ISCSI_PORT=$PORT DROBO_TESTDIR=$W
say "=== Ziel auf Port $PORT, LUN 1 = ${LUNMIB:-512} MiB"
chk "iscsi-format Trockenlauf schreibt nichts" bash -c '"$0" iscsi-format --lun 1 --name EICHPRO | grep -q "dry run" && ! grep -q "\"ereignis\": \"write\"" "$1"' "$CLI" "$W/ziel.jsonl"
chk "iscsi-format --execute (LUN 1)" "$CLI" iscsi-format --lun 1 --name EICHPRO --execute
chk "iscsi-format lehnt LUN 0 ab" bash -c '! "$0" iscsi-format --lun 0 --name X --execute' "$CLI"

mfmount() { mount -F -t $SHORT "$1" "$MNT" >>"$LOG" 2>&1 || { sleep 3; mount -F -t $SHORT "$1" "$MNT" >>"$LOG" 2>&1; }; }
say "=== Ablehnungen (nur PASS mit Modul-Log 'abgelehnt')"
T0=$(nowlog); mfmount "$URL1" && { fail "ohne Marker/Freigabe eingehaengt"; umount "$MNT"; } || { modul_lehnte_ab "$T0" && pass "ohne Marker/Freigabe abgelehnt (Modul-Log)" || fail "ohne Marker/Freigabe: mount scheitert, aber ohne 'abgelehnt' im Modul-Log (Modul nicht freigeschaltet?)"; }
T0=$(nowlog); mfmount "iscsi://127.0.0.1:$PORT/$IQN/0" && { fail "LUN 0 (ohne GPT) eingehaengt"; umount "$MNT"; } || { modul_lehnte_ab "$T0" && pass "LUN ohne GPT abgelehnt (Modul-Log)" || fail "LUN ohne GPT: kein 'abgelehnt' im Modul-Log"; }
T0=$(nowlog); mfmount "iscsi://127.0.0.1:1/$IQN/1" && { fail "unerreichbarer Port eingehaengt"; umount "$MNT"; } || { modul_lehnte_ab "$T0" && pass "unerreichbares Ziel abgelehnt (Modul-Log)" || fail "unerreichbares Ziel: kein 'abgelehnt' im Modul-Log"; }

say "=== Marker setzen, einhaengen, schreiben"
printf 'DROBOFSPROBE' | dd of="$W/l1.img" bs=1 seek=$((2048*512)) conv=notrunc 2>/dev/null
mfmount "$URL1" && pass "mount -F -t $SHORT $URL1" || { fail "mount -F -t $SHORT"; say "Modul-Log:"; MODLOG "$(date -v-2M '+%Y-%m-%d %H:%M:%S')" | tail -15 | tee -a "$LOG"; say "PASS=$NPASS FAIL=$NFAIL"; exit 1; }
mkdir -p "$W/src/d"; head -c 40000000 /dev/urandom > "$W/src/big.bin"; for i in $(seq 1 60); do head -c $(( (i * 7919) % 30000 )) /dev/urandom > "$W/src/d/f$i.bin"; done; echo hallo > "$W/src/leaf.txt"
cp "$W/src/big.bin" "$MNT/big.bin"; ditto "$W/src/d" "$MNT/d"; cp "$W/src/leaf.txt" "$MNT/leaf.txt"; mv "$MNT/d/f1.bin" "$MNT/f1moved.bin"; rm "$MNT/d/f2.bin"; sync
chk "Grossdatei md5 ueber den Mount" test "$(md5 -q "$MNT/big.bin")" = "$(md5 -q "$W/src/big.bin")"
umount "$MNT" && pass "umount" || fail "umount"; sleep 1
say "=== erneut einhaengen (Dateien muessen vom Ziel kommen)"
mfmount "$URL1" && pass "zweiter mount" || fail "zweiter mount"
chk "Grossdatei md5 nach Aus-/Einhaengen" test "$(md5 -q "$MNT/big.bin")" = "$(md5 -q "$W/src/big.bin")"
chk "f1moved.bin md5" test "$(md5 -q "$MNT/f1moved.bin")" = "$(md5 -q "$W/src/d/f1.bin")"
chk "geloeschte Datei fehlt" test ! -e "$MNT/d/f2.bin"
chk "d/f3.bin md5" test "$(md5 -q "$MNT/d/f3.bin")" = "$(md5 -q "$W/src/d/f3.bin")"
umount "$MNT" && pass "umount 2" || fail "umount 2"; sleep 1
say "=== Zielprotokoll"
MAXW=$(python3 -I -c 'import json,sys;print(max([e["bytes"] for e in map(json.loads,open(sys.argv[1])) if e.get("ereignis")=="write"] or [0]))' "$W/ziel.jsonl")
NW=$(grep -c '"ereignis": "write"' "$W/ziel.jsonl"); say "   WRITE-Befehle am Ziel: $NW, groesster: $MAXW B"
[ "$NW" -gt 0 ] && [ "$MAXW" -le 524288 ] && pass "max WRITE am Ziel <= 524288 ($MAXW, $NW Befehle)" || fail "max WRITE am Ziel ($MAXW, $NW Befehle)"
chk "kein Schreibbefehl auf LUN 0" bash -c '! python3 -I -c "import json,sys;sys.exit(0 if any(e.get(\"ereignis\")==\"befehl\" and e[\"op\"]==138 and e[\"lun\"]==0 for e in map(json.loads,open(sys.argv[1]))) else 1)" "$0"' "$W/ziel.jsonl"
chk "kein verbotener Befehl am Ziel (unbekannt)" bash -c '! grep -q "\"ereignis\": \"unbekannt\"" "$0"' "$W/ziel.jsonl"
say "=== fsck_hfs -fn auf der Partition der LUN-Abbilddatei (Kernel richtet)"
OUT=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$W/l1.img"); DEVA=$(echo "$OUT" | awk 'NR==1{print $1}')
PART=$(echo "$OUT" | awk -v d="$DEVA" 'index($1, d "s")==1{print $1; exit}')
fsck_hfs -fn "${PART/disk/rdisk}" > "$W/fsck.out" 2>&1; RC=$?; { echo "--- fsck rc=$RC"; cat "$W/fsck.out"; } >>"$LOG"
[ $RC = 0 ] && grep -q 'appears to be OK' "$W/fsck.out" && pass "fsck_hfs -fn Partition ($PART)" || fail "fsck_hfs -fn Partition ($PART) rc=$RC"
hdiutil detach "$DEVA" >/dev/null 2>&1; DEVA=""
say "ERGEBNIS PASS=$NPASS FAIL=$NFAIL (Log $LOG)"
[ $NFAIL = 0 ]
