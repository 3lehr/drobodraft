#!/bin/bash
# Eichung lifs_cli/livefiles_hfs gegen den macOS-Kernel als Richter. NUR Abbilddateien unter build/eich,
# nie ein fremdes Geraet: es werden ausschliesslich Geraete angefasst, die dieses Skript selbst angehaengt hat.
# Plan: docs/PLAN_FSKIT_HFS_2026-10-14.md, Phase 1.   Aufruf: bash eich.sh [lesen|schreiben|kappung|absturz|alles]
set -u
cd "$(dirname "$0")" || exit 2
M=$PWD; L=$M/build/lifs_cli; W=$M/build/eich; mkdir -p "$W"
LOG=$W/eich.log; : > "$LOG"
NPASS=0; NFAIL=0; NJ_OK=0; NJ_BAD=0; KILLED=0
say()  { echo "$*" | tee -a "$LOG"; }
pass() { NPASS=$((NPASS+1)); say "PASS $*"; }
fail() { NFAIL=$((NFAIL+1)); say "FAIL $*"; }
chk()  { local name=$1; shift; if "$@" >>"$LOG" 2>&1; then pass "$name"; else fail "$name"; fi; }
rmw()  { local x; for x in "$@"; do rm -rf -- "${W:?}/${x:?}"; done; }   # nur unterhalb $W

mkimg() { # name MiB journaled(1|0)  -> $W/name.raw, vom Kernel formatiert
  local f=$W/$1.raw; rmw "$1.raw"; truncate -s "${2}m" "$f"
  local dev; dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$f" | awk 'NR==1{print $1}')
  [ -n "$dev" ] || { fail "mkimg attach $1"; return 1; }
  newfs_hfs $([ "$3" = 1 ] && echo -J) -v "EICH_$1" "${dev/disk/rdisk}" >>"$LOG" 2>&1
  hdiutil detach "$dev" >>"$LOG" 2>&1
}
kmount() { # img mountpoint [ro]  -> setzt KDEV (das selbst angehaengte Geraet)
  mkdir -p "$2"
  KDEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -noverify -mountpoint "$2" $([ "${3:-}" = ro ] && echo -readonly) "$1" | awk 'NR==1{print $1}')
  [ -n "$KDEV" ]
}
kumount() { hdiutil detach "$KDEV" >>"$LOG" 2>&1; }
kfsck() { # img -> fsck_hfs -fn am Rohgeraet des (nicht gemounteten) Abbilds; Ausgabe roh ins Log + $W/fsck.out
  local dev; dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$1" | awk 'NR==1{print $1}')
  fsck_hfs -fn "${dev/disk/rdisk}" > "$W/fsck.out" 2>&1; local rc=$?
  hdiutil detach "$dev" >>"$LOG" 2>&1
  { echo "--- fsck_hfs -fn $1 rc=$rc"; cat "$W/fsck.out"; } >>"$LOG"
  return $rc
}
fsck_ok() { kfsck "$1" && grep -q 'appears to be OK' "$W/fsck.out"; }
mdlist() { # dir -> "md5 pfad" sortiert, ohne Systemverzeichnisse des Kernels
  ( cd "$1" && find . \( -name .fseventsd -o -name .Spotlight-V100 -o -name .Trashes -o -name '.HFS+ Private Directory Data*' -o -name .DS_Store -o -name .metadata_never_index \) -prune -o -type f -print0 \
    | LC_ALL=C sort -z | xargs -0 md5 -r )
}
dlist() { ( cd "$1" && find . \( -name .fseventsd -o -name .Spotlight-V100 -o -name .Trashes -o -name '.HFS+ Private Directory Data*' \) -prune -o -type d -print | LC_ALL=C sort ); }
maxfield() { sed -n "s/.*$1=\([0-9]*\).*/\1/p" | sort -n | tail -1; }   # aus STATS-Zeilen (stdin)

mksrc() { # dir: deterministisch benannter Quellbaum, Inhalt zufaellig
  local d=$1; mkdir -p "$d/small" "$d/mid" "$d/deep/a/b/c" "$d/uni"
  for i in $(seq 1 1000); do head -c $(( (i * 7919) % 20000 )) /dev/urandom > "$d/small/f$i.bin"; done
  for i in 1 2 3; do head -c $(( i * 7000000 + 123 )) /dev/urandom > "$d/mid/m$i.bin"; done
  : > "$d/empty"; echo hallo > "$d/deep/a/b/c/leaf.txt"; echo uni > "$d/uni/Ümläut-日本語.txt"
}

# ================= 1. Lesen: Kernel schreibt, lifs_cli liest =================
t_lesen() {
  local J n img
  for J in 1 0; do
    n=lesen$J; img=$W/$n.raw
    say "=== LESEN journaled=$J"
    mkimg "$n" 1536 $J || continue
    kmount "$img" "$W/mnt_$n" || { fail "$n kmount"; continue; }
    cp -R "$W/src/." "$W/mnt_$n/"
    mkdir -p "$W/mnt_$n/gross"; dd if=/dev/urandom of="$W/mnt_$n/gross/gross.bin" bs=1m count=300 2>/dev/null
    echo "wert" > "$W/mnt_$n/xa.txt"; xattr -w user.eich "kernel-xattr" "$W/mnt_$n/xa.txt"
    ln -s xa.txt "$W/mnt_$n/link.sym"; ln "$W/mnt_$n/xa.txt" "$W/mnt_$n/hard.txt"
    sync; mdlist "$W/mnt_$n" > "$W/$n.kmd5"; dlist "$W/mnt_$n" > "$W/$n.kdirs"
    kumount
    chk "lesen J=$J kernel-Abbild fsck vorher" fsck_ok "$img"
    rmw "exp_$n"; mkdir -p "$W/exp_$n"
    $L -r -s "$img" export "$W/exp_$n" 2>&1 | tee -a "$LOG" | grep -E '^STATS|^ERR'
    mdlist "$W/exp_$n" > "$W/$n.lmd5"; dlist "$W/exp_$n" > "$W/$n.ldirs"
    say "   Dateien kernel=$(wc -l < "$W/$n.kmd5") lifs=$(wc -l < "$W/$n.lmd5")"
    chk "lesen J=$J alle Dateien md5-gleich" diff "$W/$n.kmd5" "$W/$n.lmd5"
    chk "lesen J=$J Verzeichnisse gleich" diff "$W/$n.kdirs" "$W/$n.ldirs"
    chk "lesen J=$J xattr gleich" test "$($L -r "$img" xget /xa.txt user.eich)" = "kernel-xattr"
    chk "lesen J=$J Symlink erkannt" bash -c "$L -r '$img' tree | grep -q '^l .* /link.sym'"
    # Rot-Kontrolle: ein Byte im Export kippen -> der Vergleich MUSS anschlagen
    local victim; victim=$(ls "$W/exp_$n/small" | head -1)
    printf '\x55\x55' | dd of="$W/exp_$n/small/$victim" bs=1 seek=0 conv=notrunc 2>/dev/null
    mdlist "$W/exp_$n" > "$W/$n.lmd5bad"
    if diff -q "$W/$n.kmd5" "$W/$n.lmd5bad" >/dev/null; then fail "KONTROLLE lesen J=$J: Bytekipper unentdeckt"; else pass "KONTROLLE lesen J=$J: Bytekipper entdeckt (Vergleich ist scharf)"; fi
    rmw "exp_$n"
    $L -r -s "$img" get /gross/gross.bin "$W/gross.out" 2>&1 | grep '^STATS' | tee -a "$LOG"
    rmw gross.out
  done
}

# ================= 2. Schreiben: lifs_cli schreibt, Kernel richtet =================
t_schreiben() {
  local J n img
  [ -f "$W/big1g.bin" ] || head -c 1073741824 /dev/urandom > "$W/big1g.bin"
  for J in 1 0; do
    n=schr$J; img=$W/$n.raw
    say "=== SCHREIBEN journaled=$J"
    mkimg "$n" 4096 $J || continue
    rmw "ref_$n"; mkdir -p "$W/ref_$n"
    ( $L -s "$img" put "$W/big1g.bin" /big.bin
      $L -s "$img" mkdir /small; $L -s "$img" import "$W/src/small" /small
      $L -s "$img" mkdir /rest; $L -s "$img" import "$W/src/mid" /rest
      $L -s "$img" mkdir /deep; $L -s "$img" import "$W/src/deep" /deep
      $L -s "$img" mkdir /uni; $L -s "$img" import "$W/src/uni" /uni
      $L -s "$img" mv /small/f1.bin /deep/f1moved.bin
      $L -s "$img" mv /rest /rest2
      $L -s "$img" rm /small/f2.bin
      $L -s "$img" rm /small/f3.bin
      $L -s "$img" mkdir /leer; $L -s "$img" rmdir /leer
      $L -s "$img" put "$W/src/empty" /empty
      $L -s "$img" mkdir /xx; $L -s "$img" put "$W/src/deep/a/b/c/leaf.txt" /xx/x.txt; $L -s "$img" xset /xx/x.txt user.lifs "lifs-xattr"
    ) > "$W/$n.cmdlog" 2>&1
    grep -E '^STATS cmd=(put|import)' "$W/$n.cmdlog" | tee -a "$LOG"
    # Referenzbaum lokal nachgebaut (dieselben Operationen)
    mkdir -p "$W/ref_$n/small" "$W/ref_$n/rest2" "$W/ref_$n/deep" "$W/ref_$n/uni" "$W/ref_$n/xx"
    cp "$W/big1g.bin" "$W/ref_$n/big.bin"; cp -R "$W/src/small/." "$W/ref_$n/small/"; cp -R "$W/src/mid/." "$W/ref_$n/rest2/"
    cp -R "$W/src/deep/." "$W/ref_$n/deep/"; cp -R "$W/src/uni/." "$W/ref_$n/uni/"
    mv "$W/ref_$n/small/f1.bin" "$W/ref_$n/deep/f1moved.bin"; rm "$W/ref_$n/small/f2.bin" "$W/ref_$n/small/f3.bin"
    : > "$W/ref_$n/empty"; cp "$W/src/deep/a/b/c/leaf.txt" "$W/ref_$n/xx/x.txt"
    mdlist "$W/ref_$n" > "$W/$n.rmd5"; dlist "$W/ref_$n" > "$W/$n.rdirs"
    chk "schreiben J=$J keine ERR-Zeile ($(grep -c '^ERR' "$W/$n.cmdlog"))" test "$(grep -c '^ERR' "$W/$n.cmdlog")" = 0
    chk "schreiben J=$J fsck_hfs -fn (Zustand unmittelbar nach lifs_cli) appears to be OK" fsck_ok "$img"
    python3 -I "$M/jstate.py" "$img" | tee -a "$LOG"
    if kmount "$img" "$W/mnt_$n" ro; then pass "schreiben J=$J ro-Kernel-Mount direkt nach lifs_cli moeglich (Journal geschlossen)"; kumount
    else fail "schreiben J=$J ro-Kernel-Mount direkt nach lifs_cli verweigert (Journal nicht leer)"; fi
    chk "schreiben J=$J Journal leer (start==end) nach lifs_cli" bash -c "python3 -I '$M/jstate.py' '$img' | grep -q 'LEER\\|attr=0x80000100'"
    kmount "$img" "$W/mnt_$n" || { fail "$n kmount rw"; continue; }          # rw: der Kernel spielt unser Journal ein
    mdlist "$W/mnt_$n" > "$W/$n.kmd5"; dlist "$W/mnt_$n" > "$W/$n.kdirs"
    local kx; kx=$(xattr -p user.lifs "$W/mnt_$n/xx/x.txt" 2>&1); kumount
    python3 -I "$M/jstate.py" "$img" | tee -a "$LOG"
    chk "schreiben J=$J fsck_hfs -fn nach Kernel-Replay appears to be OK" fsck_ok "$img"
    chk "schreiben J=$J Kernel-Mount md5-gleich (Dateien=$(wc -l < "$W/$n.kmd5"))" diff "$W/$n.rmd5" "$W/$n.kmd5"
    chk "schreiben J=$J Verzeichnisse gleich" diff "$W/$n.rdirs" "$W/$n.kdirs"
    chk "schreiben J=$J xattr vom Kernel gelesen" test "$kx" = "lifs-xattr"
    local mx mc; mx=$(grep '^STATS' "$W/$n.cmdlog" | maxfield max_cmd); mc=$(grep '^STATS' "$W/$n.cmdlog" | maxfield max_call)
    chk "schreiben J=$J max Geraete-Schreibbefehl=$mx <= 524288" test "$mx" -le 524288
    say "   Plugin wollte bis $mc B am Stueck schreiben (am Geraet gestueckelt auf <= $mx)"
    $L -r -s "$img" get /big.bin "$W/big.back" 2>&1 | grep '^STATS' | tee -a "$LOG"
    chk "schreiben J=$J 1-GiB-Datei ueber lifs_cli zurueckgelesen md5-gleich" test "$(md5 -q "$W/big.back")" = "$(md5 -q "$W/big1g.bin")"
    rmw big.back "$n.raw"
  done
}

# ================= 3. Rot-Probe der Kappung =================
t_kappung() {
  say "=== KAPPUNG Rot-Probe (Build ohne Kappung: LIFS_MAX_WRITE=1048576)"
  ( cd "$M" && make -s B=build/nocap EXTRA=-DLIFS_MAX_WRITE=1048576 >>"$LOG" 2>&1 )
  mkimg nocap 600 1
  local mx; mx=$("$M/build/nocap/lifs_cli" -s "$W/nocap.raw" put "$W/src/mid/m3.bin" /m3 2>&1 | maxfield max_cmd)
  if [ "${mx:-0}" -gt 524288 ]; then pass "KONTROLLE Kappung: ohne Kappung max_cmd=$mx > 524288 (Zaehler schlaegt an)"; else fail "KONTROLLE Kappung: auch ohne Kappung nur max_cmd=$mx"; fi
  rmw nocap.raw
}

# ================= 4. Absturzprobe =================
# judge: Zustand nach Abbruch bewerten. J: roh / nach Kernel-Replay (rw-Mount) / nach lifs-Replay (Mount durch lifs_cli).
# Bei nicht journaled wird nur roh bewertet (dort darf fsck anschlagen: Kontrolle, dass die Pruefung scharf ist).
judge() { # label img journaled
  local lab=$1 img=$2 j=$3 raw rk ru
  cp -c "$img" "$img.k"; cp -c "$img" "$img.u"
  kfsck "$img"; raw=$?
  if [ "$j" = 1 ]; then
    kmount "$img.k" "$W/mnt_j" && kumount || fail "ABSTURZ $lab: Kernel-rw-Mount (Replay) fehlgeschlagen"; kfsck "$img.k"; rk=$?
    "$L" "$img.u" info >/dev/null 2>&1; kfsck "$img.u"; ru=$?
    say "   $lab: roh=$raw kernelReplay=$rk lifsReplay=$ru"
    [ $rk = 0 ] && [ $ru = 0 ] && pass "ABSTURZ $lab" || fail "ABSTURZ $lab (roh=$raw kernel=$rk lifs=$ru) siehe Log"
  else
    say "   $lab: roh=$raw $([ $raw = 0 ] && echo 'fsck OK' || echo 'fsck schlaegt an (erwartet bei nicht journaled)')"
    [ $raw = 0 ] && NJ_OK=$((NJ_OK+1)) || NJ_BAD=$((NJ_BAD+1))
  fi
  rmw "$(basename "$img.k")" "$(basename "$img.u")"
}

t_absturz() {
  local T pat n img pid tot pts N
  [ -f "$W/big1g.bin" ] || head -c 1073741824 /dev/urandom > "$W/big1g.bin"
  mkimg crashbase_j 3072 1; mkimg crashbase_n 3072 0
  # "gewachsener" Ausgangszustand: einmal vom Kernel rw gemountet -> lastMountedVersion=HFSJ (Befund siehe t_befund_lmv)
  kmount "$W/crashbase_j.raw" "$W/mnt_j" && kumount
  # A) kill -9 von aussen zu festen Zeitpunkten (Zeiten so gewaehlt, dass der Lauf noch aktiv ist)
  for pat in big small; do
    for T in $([ $pat = big ] && echo "0.15 0.3 0.5 0.7" || echo "0.02 0.05 0.08 0.11"); do
      n=killj_${pat}_$T; img=$W/$n.raw; cp -c "$W/crashbase_j.raw" "$img"
      if [ $pat = big ]; then "$L" "$img" put "$W/big1g.bin" /big.bin >"$W/$n.out" 2>&1 &
      else ( "$L" "$img" mkdir /s && "$L" "$img" import "$W/src/small" /s ) >"$W/$n.out" 2>&1 & fi
      pid=$!; sleep "$T"
      if kill -0 $pid 2>/dev/null; then kill -9 $pid; wait $pid 2>/dev/null; say "=== kill -9 $pat nach ${T}s: Prozess war aktiv, GEKILLT"; KILLED=$((KILLED+1))
      else wait $pid; say "=== kill -9 $pat nach ${T}s: Prozess war schon fertig (kein Absturz)"; fi
      judge "kill9/$pat/${T}s" "$img" 1; rmw "$n.raw"
    done
  done
  # B) Einspritzung: SIGKILL nach dem N-ten Geraete-Schreibbefehl, N ueber die ganze Schreibfolge gestreut
  for pat in big small; do
    cp -c "$W/crashbase_j.raw" "$W/dry.raw"
    if [ $pat = big ]; then tot=$("$L" -s "$W/dry.raw" put "$W/src/mid/m3.bin" /m 2>&1 | grep '^STATS' | sed -n 's/.*writes=\([0-9]*\) .*/\1/p' | tail -1)
    else tot=$( ( "$L" -s "$W/dry.raw" mkdir /s; "$L" -s "$W/dry.raw" import "$W/src/small" /s ) 2>&1 | grep 'cmd=import' | sed -n 's/.*writes=\([0-9]*\) .*/\1/p' | tail -1); fi
    rmw dry.raw
    pts=$(python3 -I -c "import random;random.seed(7);t=int('$tot');print(' '.join(str(x) for x in sorted(set([1,2,3,t-2,t-1]+[random.randint(4,t-3) for _ in range(14)]))))")
    say "=== Einspritzung $pat: Schreibbefehle gesamt=$tot, Abbruchpunkte: $pts"
    for N in $pts; do
      for jj in 1 0; do
        img=$W/inj_${pat}_${N}_$jj.raw; cp -c "$W/crashbase_$([ $jj = 1 ] && echo j || echo n).raw" "$img"
        if [ $pat = big ]; then LIFS_DIE_AFTER_WRITES=$N "$L" "$img" put "$W/src/mid/m3.bin" /m >/dev/null 2>&1
        else LIFS_DIE_AFTER_WRITES=$N bash -c "'$L' '$img' mkdir /s; '$L' '$img' import '$W/src/small' /s" >/dev/null 2>&1; fi
        judge "inj/$pat/N=$N/J=$jj" "$img" $jj; rmw "inj_${pat}_${N}_$jj.raw"
      done
    done
  done
  say "   nicht journaled: fsck OK=$NJ_OK, fsck schlaegt an=$NJ_BAD (Kontrolle: schlaegt es nie an, ist die Pruefung stumpf)"
  [ "$NJ_BAD" -gt 0 ] && pass "KONTROLLE Absturz: nicht-journaled-Abbrueche werden von fsck erkannt ($NJ_BAD)" || fail "KONTROLLE Absturz: fsck erkennt keinen einzigen NJ-Abbruch"
  [ "$KILLED" -gt 0 ] && pass "Absturzprobe: $KILLED echte kill -9 mitten im Lauf" || fail "kein kill -9 traf einen laufenden Prozess"
  rmw crashbase_j.raw crashbase_n.raw
}

# ================= 5. lastMountedVersion: frisch formatiertes Abbild =================
# Der Kernel schreibt beim ersten rw-Mount lastMountedVersion=HFSJ SOFORT; livefiles_hfs schreibt sie journaled. Bricht ein Lauf
# nach dem Journal-Commit, vor dem Rueckschreiben ab, ignoriert jeder Replay das Journal (Version != HFSJ). lifs_prepare_volume
# setzt sie vor dem Mount. Rot-Probe: LIFS_SKIP_PREPARE=1 muss den Fehler zeigen.
t_befund_lmv() {
  local N=90 m=$W/src/mid/m3.bin st rc
  say "=== lastMountedVersion: Abbruch nach Schreibbefehl N=$N (nach Journal-Commit, vor Rueckschreiben), frisches newfs-Abbild"
  mkimg lmv0 600 1; cp -c "$W/lmv0.raw" "$W/lmv1.raw"
  LIFS_SKIP_PREPARE=1 LIFS_DIE_AFTER_WRITES=$N "$L" "$W/lmv0.raw" put "$m" /m >/dev/null 2>&1
  LIFS_DIE_AFTER_WRITES=$N "$L" "$W/lmv1.raw" put "$m" /m >/dev/null 2>&1
  for st in lmv0 lmv1; do kmount "$W/$st.raw" "$W/mnt_j" && kumount || fail "lmv: Kernel-rw-Mount (Replay) von $st fehlgeschlagen"; done
  fsck_ok "$W/lmv0.raw" && fail "ROT-PROBE lmv: ohne Fix unerwartet OK (Test ist nicht scharf)" || pass "ROT-PROBE lmv: ohne lifs_prepare_volume nach Abbruch+Replay korrupt (Fehler reproduziert)"
  fsck_ok "$W/lmv1.raw" && pass "lmv: mit lifs_prepare_volume ueberlebt frisches Abbild den Abbruch" || fail "lmv: mit Fix trotzdem korrupt"
  rmw lmv0.raw lmv1.raw
}

# ================= 6. Zero-Fill: noetig? =================
# Apples Allokation schreibt jeden neuen Extent vorab mit Nullen (raw_readwrite_zero_fill_fill, "KBZ: for now"). Messung: Geraeteverkehr je Nutzbyte
# mit/ohne, und ob eine Datei mit Luft (sparse) ohne Nullen Plattenreste zeigt.
t_zerofill() {
  local NZ=$M/build/nozf/lifs_cli st a b
  say "=== ZERO-FILL: Messvariante bauen (nur Aufrufstelle in lf_hfs_volume_allocation.c ohne Nullen)"
  ( cd "$M" && make -s B=build/nozf ZFSKIP=-Draw_readwrite_zero_fill_fill=lifs_zerofill_skip >>"$LOG" 2>&1 )
  mkimg zf 700 1; head -c 300000000 /dev/urandom > "$W/junk.bin"
  "$L" "$W/zf.raw" put "$W/junk.bin" /junk >/dev/null 2>&1; "$L" "$W/zf.raw" rm /junk >/dev/null 2>&1       # freigegebene Bloecke tragen Zufallsdaten
  cp -c "$W/zf.raw" "$W/zf2.raw"
  "$L" "$W/zf.raw" sparse /h 134217728 >/dev/null 2>&1; "$L" -r "$W/zf.raw" get /h "$W/zf.out" 2>/dev/null
  head -c 100000000 "$W/zf.out" | cmp -s - <(head -c 100000000 /dev/zero) && pass "ZEROFILL stock: Luft vor Offset 128 MiB liest Nullen" || fail "ZEROFILL stock: Luft enthaelt Plattenreste"
  "$NZ" "$W/zf2.raw" sparse /h 134217728 >/dev/null 2>&1; "$NZ" -r "$W/zf2.raw" get /h "$W/zf2.out" 2>/dev/null
  if head -c 100000000 "$W/zf2.out" | cmp -s - <(head -c 100000000 /dev/zero); then say "   Variante ohne Zero-Fill: Luft ebenfalls Nullen (hier kein Beleg fuer Notwendigkeit)"
  else pass "ZEROFILL ohne Zero-Fill zeigt die Luft Plattenreste (Zero-Fill ist fuer Luecken noetig, nicht pauschal entfernbar)"; fi
  for v in stock nozf; do
    mkimg zfp 600 1; local bin=$L; [ $v = nozf ] && bin=$NZ
    st=$("$bin" -s "$W/zfp.raw" put "$W/src/mid/m3.bin" /m 2>&1 | grep '^STATS'); a=$(echo "$st" | sed -n 's/.*[ ]bytes=\([0-9]*\) .*/\1/p'); b=$(echo "$st" | sed -n 's/.*nutz_MB=\([0-9.]*\) .*/\1/p')
    say "   Geraeteverkehr $v: dev_bytes=$a nutz_MB=$b -> Faktor $(python3 -c "print('%.2f' % ($a/($b*1048576)))")"
  done
  rmw zf.raw zf2.raw zf.out zf2.out zfp.raw junk.bin
}

main() {
  [ -x "$L" ] || { echo "erst make"; exit 2; }
  [ -d "$W/src" ] || mksrc "$W/src"
  case "${1:-alles}" in
    lesen) t_lesen;; schreiben) t_schreiben;; kappung) t_kappung;; absturz) t_absturz;; befund) t_befund_lmv;; zerofill) t_zerofill;;
    alles) t_lesen; t_schreiben; t_kappung; t_absturz; t_befund_lmv; t_zerofill;;
  esac
  say "=== ERGEBNIS PASS=$NPASS FAIL=$NFAIL (Log: $LOG)"
  [ "$NFAIL" = 0 ]
}
main "$@"
