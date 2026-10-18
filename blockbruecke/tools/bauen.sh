#!/bin/bash
# Baut BlockbrueckeHost.app (mit eingebettetem Dext), signiert mit Automatic Signing (Team JR9H9Q532P).
# bauen.sh [gruen|rot] [--id2] — v0.4 erzwingt die eigene Bundle-ID ...blockbruecke2.
# rot = Dext OHNE family.scsicontroller (Rotprobe, Aktivierung muss scheitern).
# Laedt/aktiviert/installiert NICHTS. Ausgabe: Pfad der App + Entitlements des Dext.
set -euo pipefail
art=${1:-gruen}
case "$art" in gruen|rot) ;; *) echo "FAIL unbekannte Bauart: $art"; exit 1;; esac
if [ "$#" -gt 2 ] || { [ "$#" -ge 2 ] && [ "$2" != --id2 ]; }; then
  echo "FAIL v0.4 erlaubt nur die eigene Identitaet --id2"; exit 1
fi
id=de.begod.drobo.blockbruecke2
if [ -n "${BB_ID:-}" ] && [ "$BB_ID" != "$id" ]; then
  echo "FAIL v0.4 verweigert fremde/alte BB_ID"; exit 1
fi
cd "$(dirname "$0")/.."
python3 tools/check_matching_test.py
python3 tools/check_matching.py
ent=Dext/Dext.entitlements; [ "$art" = rot ] && ent=Dext/Dext.rot.entitlements
dd="$PWD/build/${id##*.}-$art"
mkdir -p "$dd"
export BB_ID="$id"; xcodegen generate -q   # project.yml liest ${BB_ID} beim Erzeugen (Einbettungspfad des Dext haengt am Namen)
xcodebuild -project Blockbruecke.xcodeproj -scheme BlockbrueckeHost -configuration Debug -derivedDataPath "$dd" \
  -allowProvisioningUpdates BB_DEXT_ENT="$ent" build > "$dd.log" 2>&1 || { grep -E "error:" "$dd.log" | sort -u; echo "FAIL build ($dd.log)"; exit 1; }
echo "** BUILD SUCCEEDED **"
app="$dd/Build/Products/Debug/BlockbrueckeHost.app"
dext="$app/Contents/Library/SystemExtensions/$id.dext.dext"
codesign -dv "$dext" 2>&1 | grep "^Identifier="
codesign --verify --strict --deep "$app"
echo "APP $app"
codesign -d --entitlements - --xml "$dext" 2>/dev/null | plutil -p - | grep -E "driverkit"
if [ "$art" = rot ] && codesign -d --entitlements - --xml "$dext" 2>/dev/null | grep -q scsicontroller; then echo "FAIL rot enthaelt scsicontroller"; exit 1; fi
if [ "$art" = gruen ] && ! codesign -d --entitlements - --xml "$dext" 2>/dev/null | grep -q scsicontroller; then echo "FAIL gruen ohne scsicontroller"; exit 1; fi
echo "PASS $art"
