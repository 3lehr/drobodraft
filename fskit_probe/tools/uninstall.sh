#!/bin/bash
# Entfernt DroboDraft: beendet die App, meldet den Hilfsdienst ab, loescht /Applications/DroboFSProbe.app.
# Systemeinstellungen (Modul, Hilfsdienst, Festplattenvollzugriff) werden NICHT angefasst, nur genannt.
# Optional: --daten loescht auch Einstellungen, Protokoll und die Freigabeliste des Moduls (Sicherungen der Verwaltungsdaten bleiben immer liegen).
set -uo pipefail
. "$(dirname "$0")/identity.sh"
APP=/Applications/DroboFSProbe.app
if [ -d "$APP" ]; then
  osascript -e "tell application id \"$DROBO_APP_ID\" to quit" 2>/dev/null; sleep 2
  "$APP/Contents/MacOS/DroboFSProbe" --helfer-abmelden || true
  rm -rf "$APP" && echo "entfernt: $APP"
else echo "$APP ist nicht installiert."; fi
if [ "${1:-}" = "--daten" ]; then
  rm -rf "$HOME/Library/Application Support/Drobo" "$HOME/Library/Containers/$DROBO_MODULE_ID" && echo "Einstellungen, Protokoll und Freigabeliste geloescht."
fi
cat <<TXT
Noch von Hand (Systemeinstellungen):
  1. Allgemein > Anmeldeobjekte & Erweiterungen: Hilfsdienst und Dateisystem-Erweiterung (Modul) ausschalten bzw. entfernen.
  2. Datenschutz & Sicherheit > Festplattenvollzugriff: Eintrag "drobohelper" entfernen.
  3. Die Sicherungen der Verwaltungsdaten liegen an dem von dir gewaehlten Sicherungsort; loesche sie, wenn du sie nicht mehr brauchst.
TXT
