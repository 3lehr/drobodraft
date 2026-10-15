#!/bin/bash
# Baut die CLI `drobo` und signiert sie mit Kennung de.begod.drobo (Team JR9H9Q532P): nur so nimmt der Hilfsdienst ihre XPC-Aufrufe an (helferAnforderung).
set -euo pipefail
cd "$(dirname "$0")/../../drobo_kern"
/usr/bin/swift build -c release --scratch-path "${B:-/Volumes/daten/xcode/drobo/kernbuild}" >/dev/null
BIN="${B:-/Volumes/daten/xcode/drobo/kernbuild}/release/drobo"
codesign -f -s "${DROBO_SIGNATUR:?Signaturidentitaet in DROBO_SIGNATUR setzen}" -i de.begod.drobo -o runtime "$BIN"
codesign -dv "$BIN" 2>&1 | grep -E "Identifier|TeamIdentifier"; echo "$BIN"
