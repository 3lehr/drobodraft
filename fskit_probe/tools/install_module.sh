#!/bin/bash
# Baut das Modul (Dev-Signing wie Phase 0a, DerivedData /Volumes/daten/xcode/drobo) und installiert es IN PLACE nach /Applications.
# Warum in place: verschwindet der Eintrag auch nur kurz aus der LaunchServices-Datenbank (rm/ditto/lsregister -u), streicht fskit_agent die
# Bundle-ID aus enabledModules.plist und das Modul ist "disabled" (Befund 2026-10-14).
# REGEL (Betreiber, 2026-10-14): dieses Skript fasst enabledModules.plist und Systemdienste (fskit_agent) NICHT an. Fehlt die Freischaltung,
# meldet es das und endet mit Exit 3; die Freischaltung macht der Betreiber.
set -euo pipefail
cd "$(dirname "$0")/.."
DD=${DD:-/Volumes/daten/xcode/drobo}
ID=de.begod.drobofsprobe.fsmodule
PL="$HOME/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"
plutil -p "$PL" | grep -q "$ID" || { echo "STOP: $ID steht nicht in enabledModules.plist -> Betreiber muss das Modul freischalten (nichts installiert)"; exit 3; }
make -C .. -s
xcodegen generate >/dev/null
xcodebuild -project DroboFSProbe.xcodeproj -scheme DroboFSProbe -configuration Debug -derivedDataPath "$DD" -allowProvisioningUpdates ${XC_EXTRA:-} build > "$DD/build_install.log" 2>&1 \
  || { tail -20 "$DD/build_install.log"; exit 1; }
SRC="$DD/Build/Products/Debug/DroboFSProbe.app"
mkdir -p /Applications/DroboFSProbe.app
rsync -a --delete "$SRC/" /Applications/DroboFSProbe.app/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted /Applications/DroboFSProbe.app
# die DerivedData-Kopie traegt dieselbe Bundle-ID: NICHT mit -u/pluginkit -r abmelden
sleep 3
plutil -p "$PL" | grep -q "$ID" || { echo "STOP: Freischaltung nach dem Update verloren -> Betreiber muss das Modul erneut freischalten"; exit 3; }
pluginkit -mAvv -p com.apple.fskit.fsmodule | grep -A9 "$ID" | grep -E "Path|Short Name|UUID"
