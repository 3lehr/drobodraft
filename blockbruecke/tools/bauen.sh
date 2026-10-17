#!/bin/bash
# Baut BlockbrueckeHost.app (mit eingebettetem Dext), signiert mit Automatic Signing (Team JR9H9Q532P).
# bauen.sh [gruen|rot] [--id2]   --id2 = Bundle-ID de.begod.drobo.blockbruecke2 (Fallback, wenn alte Instanzen haengen).
# bauen.sh [gruen|rot]   rot = Dext OHNE family.scsicontroller (Rotprobe, Aktivierung muss scheitern).
# Laedt/aktiviert/installiert NICHTS. Ausgabe: Pfad der App + Entitlements des Dext.
set -euo pipefail
art=${1:-gruen}; id=de.begod.drobo.blockbruecke; [ "${2:-}" = --id2 ] && id=de.begod.drobo.blockbruecke2
cd "$(dirname "$0")/.."
ent=Dext/Dext.entitlements; [ "$art" = rot ] && ent=Dext/Dext.rot.entitlements
dd=${TMPDIR:-/private/tmp}/${id##*.}-$art
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
