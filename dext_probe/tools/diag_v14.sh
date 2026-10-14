#!/bin/bash
# Auswertung Dext v1.4 (Diagnose): Log + ioreg + ioctl, ordnet Hypothese A / B / Hilfsverzeichnis / ok zu.
# Aufruf: tools/diag_v14.sh [Minuten=10]     (nur lesen, kein sudo)
# A: Dext sieht den Testwert am eigenen Objekt, spaeter steht am Knoten der Protokollwert -> Kernel ueberschreibt.
# B: SetProperties kehrt mit 0 zurueck, aber CopyProperties zeigt den Testwert nie -> Kernel nimmt an, setzt nichts.
# H: Werte nur unter "IOUserServiceProperties", nicht oben -> Hilfsverzeichnis-Fall.
# OK: Knoten und ioctl zeigen den Testwert.
set -uo pipefail
MIN="${1:-10}"
WANT=65536
HERE="$(cd "$(dirname "$0")" && pwd)"
MW=/tmp/maxwrite
[ -x "$MW" ] || cc -o "$MW" "$HERE/maxwrite.c"

if [ -z "${DIAG_RUN_FILE:-}" ]; then
echo "== systemextensionsctl"; systemextensionsctl list | grep -i dextprobe || { echo "Dext nicht registriert"; exit 1; }
fi

echo "== Log (letzte ${MIN} min, nur Lauf nach dem letzten 'DIAG Start super')"
LOG=$(/usr/bin/log show --last "${MIN}m" --info --debug --style compact --predicate 'eventMessage CONTAINS "MaxWriteProbe:"' 2>/dev/null | grep "MaxWriteProbe:" | sed 's/^[0-9-]* //')
RUN=$(printf '%s\n' "$LOG" | awk '/DIAG Start super/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}')
[ -n "${DIAG_RUN_FILE:-}" ] && RUN=$(cat "$DIAG_RUN_FILE")   # Testmodus (Eichung mit Beispielzeilen)
printf '%s' "$RUN" | cut -c1-230
[ -n "$RUN" ] || { echo "KEIN Log: Dext 1.4 nicht aktiv oder Leser nicht neu gesteckt"; exit 1; }

echo "== ioreg Knoten (IOUserSCSIPeripheralDeviceType00, Leser ABT)"
NODE=$(ioreg -r -c IOUserSCSIPeripheralDeviceType00 -l -w0 | grep -E '^  \|   "IOMaximum(Byte|Block)Count(Read|Write)"')
echo "$NODE" | sed 's/^ *| *//'
NODE_BYTES=$(echo "$NODE" | sed -n 's/.*"IOMaximumByteCountWrite" = \([0-9]*\).*/\1/p' | head -1)

NODE_BYTES="${DIAG_NODE_BYTES:-$NODE_BYTES}"
echo "== ioctl am Rohgeraet der Karte"
DISK=""
for d in $(diskutil list external physical | grep -o '^/dev/disk[0-9]*'); do
  [ "$(diskutil info "$d" | sed -n 's/^ *Device \/ Media Name: *//p')" = "CFX Card Reader" ] && DISK="$d"
done
IOCTL_BYTES=""
if [ -n "$DISK" ]; then OUT=$("$MW" "/dev/r${DISK#/dev/}" 2>&1); echo "$OUT"; IOCTL_BYTES=$(echo "$OUT" | sed -n 's/.*maxbytecountwrite=\([0-9]*\).*/\1/p'); else echo "Karte (CFX Card Reader) nicht gefunden"; fi

IOCTL_BYTES="${DIAG_IOCTL_BYTES:-$IOCTL_BYTES}"
# DIAG-Zeilen zerlegen: bytes=<da>:<wert>, IOUserServiceProperties=<da>(...bytes=<da>)
val()  { sed -n "s/.*DIAG $1 .*bytes=[01]:\([0-9]*\) .*/\1/p" | tail -1; }
usp()  { sed -n "s/.*DIAG $1 .*IOUserServiceProperties=\([01]\)(count=[0-9]* bytes=\([01]\).*/\1\2/p" | tail -1; }
SET_VAL=$(printf '%s' "$RUN" | val "nach SetProperties"); SET_USP=$(printf '%s' "$RUN" | usp "nach SetProperties")
T10_VAL=$(printf '%s' "$RUN" | val "Timer+1[0-9][0-9][0-9][0-9]ms"); T2_VAL=$(printf '%s' "$RUN" | val "Timer+2[0-9][0-9][0-9]ms")
SET_RET=$(printf '%s' "$RUN" | sed -n 's/.*UserDetermineDeviceCharacteristics .*ret=\(0x[0-9a-f]*\).*/\1/p' | tail -1)
echo "== Werte: SetProperties ret=${SET_RET:-?}; Copy nach Set=${SET_VAL:-?}; Timer2s=${T2_VAL:-?}; Timer10s=${T10_VAL:-?}; Knoten=${NODE_BYTES:-?}; ioctl=${IOCTL_BYTES:-?}; USP(vorhanden,bytes)=${SET_USP:-?}"

echo "== Zuordnung"
if [ "${NODE_BYTES:-0}" = "$WANT" ] && [ "${IOCTL_BYTES:-0}" = "$WANT" ]; then
  echo "OK: Knoten und ioctl zeigen $WANT -> Verkleinern per Dext wirkt (min oder Uebernahme)."
elif [ "${SET_USP:-}" = "11" ] && [ "${SET_VAL:-}" != "$WANT" ]; then
  echo "H (Hilfsverzeichnis): Werte nur unter IOUserServiceProperties, oberste Ebene unveraendert -> Kernel nimmt es in Unterdict; Block-Treiber liest oben."
elif [ "${SET_VAL:-}" = "$WANT" ] && [ "${NODE_BYTES:-}" != "$WANT" ]; then
  echo "A: Dext sieht $WANT direkt nach SetProperties (Timer: ${T2_VAL:-?}/${T10_VAL:-?}), Knoten ${NODE_BYTES:-?} -> Kernel ueberschreibt nach dem Aufruf (oder CopyProperties zeigt Dext-Sicht, Knoten ist Kernel-Sicht)."
elif [ "${SET_RET:-}" = "0x0" ] && [ "${SET_VAL:-}" != "$WANT" ]; then
  echo "B: SetProperties ret=0x0, aber CopyProperties zeigt $WANT nie (Copy=${SET_VAL:-leer}) -> Kernel-setProperties nimmt an, setzt nichts."
else
  echo "UNKLAR: Werte oben ansehen (ret=${SET_RET:-?}); ggf. Leser neu stecken und erneut laufen lassen."
fi
