#!/bin/bash
# Testlauf Dext-Probe an der CF-Karte "old" im Leser ABT / "CFX Card Reader" (Plan Phase 0b).
# Zerstoert Inhalt der Karte (Betreiber-Freigabe). Nie Samsung T7, Backup 1, Drobo.
# Aufruf:  tools/test_cf.sh show            # nur lesen: Leser finden, IOMaximumByteCountWrite zeigen
#          sudo tools/test_cf.sh dd         # 2 GiB roh schreiben+lesen, bs=1m und bs=4m, Hash, MB/s
#          sudo tools/test_cf.sh fs exfat   # (oder hfs) Formatieren, 1 GiB Datei schreiben/lesen
# Vor und nach Aktivierung je einmal "show" und "dd" laufen lassen und die Zahlen vergleichen.
set -euo pipefail

WANT_MEDIA="CFX Card Reader"
WANT_VENDOR="ABT"
TESTDIR="${TESTDIR:-/Volumes/daten/xcode/drobo/cf_test}"
OFFSET_MIB=1024   # Rohtest ab 1 GiB Offset
SIZE_MIB=2048

die() { echo "ABBRUCH: $*" >&2; exit 1; }

# genau eine externe physische Platte mit Media Name == WANT_MEDIA; Nummern wechseln
find_disk() {
  local d n found=() size
  for d in $(diskutil list external physical | grep -o '^/dev/disk[0-9]*'); do
    n=$(diskutil info "$d" | sed -n 's/^ *Device \/ Media Name: *//p')
    [ "$n" = "$WANT_MEDIA" ] && found+=("$d")
  done
  [ "${#found[@]}" -eq 1 ] || die "erwarte genau 1 Platte mit Media Name '$WANT_MEDIA', gefunden: ${#found[@]}"
  DISK="${found[0]}"
  size=$(diskutil info "$DISK" | sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes).*/\1/p')
  [ "$size" -ge 400000000000 ] && [ "$size" -le 600000000000 ] || die "$DISK hat $size Byte, erwartet ~512 GB"
  # INQUIRY gegenpruefen: der Nub, der GENAU diese Platte ($DISK) traegt, muss Vendor ABT + Produkt haben
  [ -n "$(nub_block)" ] || die "$DISK haengt an keinem Nub mit Vendor $WANT_VENDOR / Produkt $WANT_MEDIA"
  case "$(diskutil info "$DISK")" in *Drobo*|*Samsung*|*"PSSD T7"*) die "$DISK sieht nach Drobo/Samsung aus";; esac
}

# ioreg-Block (Nub samt Unterbaum) von $DISK: Block beginnt bei "+-o"; Treffer nur, wenn Vendor+Produkt stimmen UND der Unterbaum
# den IOMedia "BSD Name" = "<DISK>" (ganze Platte, Anfuehrungszeichen verhindern diskNsM) enthaelt. Ohne die Bindung an $DISK
# genuegte ein zweiter Leser gleicher Bauart (oder ein beliebiger ABT-Nub) fuer die Pruefung.
nub_block() {
  ioreg -r -c IOSCSIPeripheralDeviceNub -l -w0 | awk -v v="$WANT_VENDOR" -v p="$WANT_MEDIA" -v b="${DISK#/dev/}" '
    function ok(x) { return x ~ ("\"Vendor Identification\" = \"" v "\"") && x ~ ("\"Product Identification\" = \"" p "\"") && x ~ ("\"BSD Name\" = \"" b "\"") }
    /^\+-o /{ if (ok(blk)) printf "%s", blk; blk="" }
    { blk = blk $0 "\n" }
    END { if (ok(blk)) printf "%s", blk }'
}

# Vor JEDEM schreibenden Schritt (unmountDisk, dd of=, eraseDisk): Identitaet neu pruefen (Media Name, Groesse, Nub an $DISK, nicht
# Drobo/Samsung) und dass die Platte noch dieselbe Nummer hat -- ein Neustecken kann /dev/diskN an ein anderes Geraet vergeben.
recheck() {
  local prev="$DISK"
  find_disk
  [ "$DISK" = "$prev" ] || die "Platte wechselte waehrend des Laufs: $prev -> $DISK (vor: $1)"
}

# Referenzdatei $1 ($2 MiB): Groesse + SHA-256 (Sidecar $1.sha256) pruefen, sonst neu erzeugen; setzt REF_SHA.
# Ein Rest eines abgebrochenen dd oder eine fremd ueberschriebene Datei darf nicht still als Referenz dienen.
ref_datei() {
  local f="$1" mib="$2" h
  if [ -f "$f" ] && [ -f "$f.sha256" ] && [ "$(stat -f %z "$f")" -eq $((mib * 1048576)) ]; then
    h=$(shasum -a 256 "$f" | cut -d' ' -f1)
    if [ "$h" = "$(cat "$f.sha256")" ]; then REF_SHA="$h"; return 0; fi
  fi
  echo "erzeuge Referenzdatei $f"
  rm -f "$f" "$f.sha256"
  dd if=/dev/urandom of="$f" bs=1m count="$mib" 2>/dev/null
  [ "$(stat -f %z "$f")" -eq $((mib * 1048576)) ] || die "Referenzdatei $f hat nicht $mib MiB"
  REF_SHA=$(shasum -a 256 "$f" | cut -d' ' -f1)
  echo "$REF_SHA" > "$f.sha256"
}

show_max() {
  echo "--- $(date +%H:%M:%S) $1: $DISK ($WANT_VENDOR / $WANT_MEDIA)"
  nub_block | grep -E '"IOMaximum(Byte|Block)Count(Read|Write)"|Vendor Identification|Product Identification' | sed 's/^[ |]*/  /'
  echo "  Dext-Zustand:"; systemextensionsctl list | grep -i dextprobe | sed 's/^/    /' || echo "    (nicht registriert)"
}

# dd-Ausgabe "... bytes transferred in S secs (B bytes/sec)" -> MB/s
mbs() { awk '/bytes transferred/ { gsub(/[()]/,""); printf "%.1f MB/s\n", $(NF-1)/1e6 }'; }

raw_test() {
  local rdisk="/dev/r${DISK#/dev/}" bs seek count ref got f="$TESTDIR/ref_${SIZE_MIB}m.bin"
  mkdir -p "$TESTDIR"
  ref_datei "$f" "$SIZE_MIB"; ref="$REF_SHA"
  recheck "unmountDisk"
  diskutil unmountDisk force "$DISK" >/dev/null
  for bs in 1 4; do
    seek=$((OFFSET_MIB / bs)); count=$((SIZE_MIB / bs))
    recheck "dd Schreiben bs=${bs}m"
    echo "== Schreiben bs=${bs}m ab ${OFFSET_MIB} MiB"
    dd if="$f" of="$rdisk" bs=${bs}m seek=$seek count=$count 2>&1 | tee /dev/stderr | mbs
    echo "== Lesen bs=${bs}m"
    got=$(dd if="$rdisk" bs=${bs}m skip=$seek count=$count 2>"$TESTDIR/rd.log" | shasum -a 256 | cut -d' ' -f1)
    mbs < "$TESTDIR/rd.log"
    [ "$got" = "$ref" ] && echo "  Hash OK bs=${bs}m" || echo "  Hash FEHLER bs=${bs}m (ref $ref, gelesen $got)"
  done
}

fs_test() {
  local kind="${1:-exfat}" vol="CFTEST" mp f="$TESTDIR/ref_1024m.bin" ref got
  mkdir -p "$TESTDIR"
  ref_datei "$f" 1024; ref="$REF_SHA"
  recheck "eraseDisk"
  case "$kind" in
    exfat) diskutil eraseDisk ExFAT "$vol" MBR "$DISK" ;;
    hfs)   diskutil eraseDisk JHFS+ "$vol" GPT "$DISK" ;;
    *) die "fs exfat|hfs" ;;
  esac
  mp="/Volumes/$vol"
  # der Name CFTEST koennte auch ein fremdes Volume tragen: der Einhaengepunkt muss zu $DISK gehoeren
  [ "$(diskutil info "$mp" | sed -n 's/^ *Part of Whole: *//p')" = "${DISK#/dev/}" ] || die "$mp gehoert nicht zu $DISK"
  recheck "dd in $mp"
  echo "== Datei schreiben ($kind)"; dd if="$f" of="$mp/t.bin" bs=1m 2>&1 | mbs
  sync; diskutil unmount "$mp" >/dev/null; diskutil mount "$vol" >/dev/null
  echo "== Datei lesen"; got=$(dd if="$mp/t.bin" bs=1m 2>"$TESTDIR/rd.log" | shasum -a 256 | cut -d' ' -f1); mbs < "$TESTDIR/rd.log"
  [ "$got" = "$ref" ] && echo "  Hash OK" || echo "  Hash FEHLER"
  [ "$kind" = hfs ] && fsck_hfs -fn "/dev/r${DISK#/dev/}s2" || true
}

main() {
  find_disk
  case "${1:-}" in
    show) show_max "Zustand" ;;
    dd)   [ "$(id -u)" -eq 0 ] || die "mit sudo starten"; show_max "vor dd"; raw_test; show_max "nach dd" ;;
    fs)   [ "$(id -u)" -eq 0 ] || die "mit sudo starten"; show_max "vor fs"; fs_test "${2:-exfat}"; show_max "nach fs" ;;
    *)    die "Aufruf: show | dd | fs exfat|hfs" ;;
  esac
}
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@" || true
