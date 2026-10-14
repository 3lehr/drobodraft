#!/bin/bash
# I/O-Invariante des Moduls: EINE Schreibstelle (Backend.swift) mit Kappung 524288; Apples Code erreicht das Geraet nur ueber lifs_dev_pwrite; kein Spawn.
set -u
cd "$(dirname "$0")/.."
bad=0
n=$(grep -c "\.write(from\|metadataWrite\|delayedMetadataWrite\|metadataClear" Module/*.swift | awk -F: '{s+=$2} END{print s}')
echo "Swift-Schreibaufrufe: $n (erwartet 1, in Backend.swift)"; grep -n "\.write(from" Module/*.swift; [ "$n" = 1 ] || bad=1
grep -q "let c = min(span - done, 524288)" Module/Backend.swift && echo "Kappung vorhanden: let c = min(span - done, 524288)" || { echo "Kappung fehlt"; bad=1; }
make -C .. -s check-io | tail -1 | sed 's/^/Lib: /'
D=${1:-/Applications/DroboFSProbe.app/Contents/PlugIns/DroboFSProbeModule.appex/Contents/MacOS/DroboFSProbeModule.debug.dylib}
if [ -f "$D" ]; then
  s=$(nm -u "$D" | grep -E "^_(posix_spawn|posix_spawnp|execve|execv|system|popen|fork|vfork|write|writev|pwritev|aio_write)$"); [ -z "$s" ] && echo "Binary: keine Spawn-/Schreib-Symbole (nur pwrite/ioctl/pread aus lifs_devio.o)" || { echo "Binary: UNERWARTET $s"; bad=1; }
fi
[ $bad = 0 ] && echo "check_io: OK" || { echo "check_io: FEHLER"; exit 1; }
