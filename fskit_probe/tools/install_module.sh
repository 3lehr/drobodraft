#!/bin/bash
# Baut das Modul (Dev-Signing wie Phase 0a, DerivedData /Volumes/daten/xcode/drobo), installiert es IN PLACE nach /Applications
# und stellt die Freischaltung sicher. Warum in place: wird der Eintrag kurz aus der LaunchServices-Datenbank entfernt (rm/ditto/lsregister -u),
# streicht fskit_agent die Bundle-ID aus enabledModules.plist (Befund 2026-10-14) und das Modul ist wieder "disabled".
set -euo pipefail
cd "$(dirname "$0")/.."
DD=${DD:-/Volumes/daten/xcode/drobo}
make -C .. -s
xcodegen generate >/dev/null
xcodebuild -project DroboFSProbe.xcodeproj -scheme DroboFSProbe -configuration Debug -derivedDataPath "$DD" -allowProvisioningUpdates build > "$DD/build_install.log" 2>&1 \
  || { tail -20 "$DD/build_install.log"; exit 1; }
SRC="$DD/Build/Products/Debug/DroboFSProbe.app"
mkdir -p /Applications/DroboFSProbe.app
rsync -a --delete "$SRC/" /Applications/DroboFSProbe.app/
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSR -f -R -trusted /Applications/DroboFSProbe.app
# die DerivedData-Kopie traegt dieselbe Bundle-ID: NICHT mit -u/pluginkit -r abmelden (das wuerde die Freischaltung loeschen)
sleep 3
ID=de.begod.drobofsprobe.fsmodule
PL="$HOME/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"
if ! plutil -p "$PL" | grep -q "$ID"; then
  echo "Freischaltung fehlt -> eintragen und fskit_agent neu starten lassen"
  python3 -I - "$PL" "$ID" <<'PY'
import plistlib,sys
p,i=sys.argv[1:3]; a=plistlib.load(open(p,'rb'))
a.insert(0,i); plistlib.dump(a,open(p,'wb'))
PY
fi
# fskit_agent haelt Kurznamen im Speicher: nach Aenderung neu starten lassen (startet bei Bedarf selbst; Freischaltung liegt in der Datei)
kill -9 "$(pgrep -x fskit_agent)" 2>/dev/null || true
sleep 3
pluginkit -mAvv -p com.apple.fskit.fsmodule | grep -A9 "$ID" | grep -E "Path|Short Name|UUID"
