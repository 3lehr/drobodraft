#!/bin/bash
# Baut App und Modul und installiert sie IN PLACE nach /Applications (Bauordner: $DD, Vorgabe <Repo>/build/xcode).
# Warum in place: verschwindet der Eintrag auch nur kurz aus der LaunchServices-Datenbank (rm/ditto/lsregister -u), streicht fskit_agent die
# Bundle-ID aus enabledModules.plist und das Modul ist "disabled".
# REGEL: dieses Skript fasst enabledModules.plist und Systemdienste (fskit_agent) NICHT an. Die Freischaltung macht der Nutzer in den Systemeinstellungen.
#   - Erstinstallation (Modul noch nicht freigeschaltet): installiert, meldet "jetzt freischalten", Exit 0.
#   - Update (Modul war freigeschaltet, ist es danach nicht mehr): Exit 3 mit Hinweis.
# Praefix/Team: Identity.xcconfig bzw. Identity.local.xcconfig (siehe README).
set -euo pipefail
cd "$(dirname "$0")/.."
. tools/identity.sh
DD=${DD:-$DROBO_BUILD/xcode}
mkdir -p "$DD"
PL="$HOME/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"
freigeschaltet() { [ -f "$PL" ] && plutil -p "$PL" 2>/dev/null | grep -q "$DROBO_MODULE_ID"; }
WAR=0; freigeschaltet && WAR=1
make -C .. -s
xcodegen generate >/dev/null
xcodebuild -project DroboFSProbe.xcodeproj -scheme DroboFSProbe -configuration Debug -derivedDataPath "$DD" -allowProvisioningUpdates ${XC_EXTRA:-} build > "$DD/build_install.log" 2>&1 \
  || { tail -20 "$DD/build_install.log"; exit 1; }
SRC="$DD/Build/Products/Debug/DroboFSProbe.app"
mkdir -p /Applications/DroboFSProbe.app
rsync -a --delete "$SRC/" /Applications/DroboFSProbe.app/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted /Applications/DroboFSProbe.app
# die Bauordner-Kopie traegt dieselbe Bundle-ID: NICHT mit -u/pluginkit -r abmelden
sleep 3
pluginkit -mAvv -p com.apple.fskit.fsmodule | grep -A9 "$DROBO_MODULE_ID" | grep -E "Path|Short Name|UUID" || true
if freigeschaltet; then echo "OK: installiert, Modul ist freigeschaltet."; exit 0; fi
if [ "$WAR" = 1 ]; then echo "STOP: Freischaltung nach dem Update verloren -> in den Systemeinstellungen (Allgemein, Anmeldeobjekte & Erweiterungen, Dateisystem-Erweiterungen) das Modul erneut einschalten."; exit 3; fi
echo "INSTALLIERT. Jetzt in den Systemeinstellungen freischalten: Allgemein > Anmeldeobjekte & Erweiterungen > Dateisystem-Erweiterungen > DroboDraft-Modul einschalten"
echo "(sowie Hilfsdienst und Festplattenvollzugriff, siehe README). Danach erneut dieses Skript fuer Updates verwenden."
exit 0
