#!/bin/bash
# Baut die CLI `drobo` und signiert sie mit Kennung <Praefix>.drobo und dem Team aus Identity.xcconfig: nur so nimmt der Hilfsdienst ihre XPC-Aufrufe an.
# Signaturidentitaet in DROBO_SIGNATUR setzen (z. B. "Apple Development: Name (ABCDE12345)"). Bauordner: $B, Vorgabe <Repo>/build/drobo_kern.
set -euo pipefail
cd "$(dirname "$0")/../../drobo_kern"
. ../fskit_probe/tools/identity.sh
B=${B:-$DROBO_BUILD/drobo_kern}
/usr/bin/swift build -c release --scratch-path "$B" >/dev/null
BIN="$B/release/drobo"
codesign -f -s "${DROBO_SIGNATUR:?Signaturidentitaet in DROBO_SIGNATUR setzen}" -i "$DROBO_BUNDLE_PREFIX.drobo" -o runtime "$BIN"
codesign -dv "$BIN" 2>&1 | grep -E "Identifier|TeamIdentifier"; echo "$BIN"
