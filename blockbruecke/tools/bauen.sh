#!/bin/bash
# Baut BlockbrueckeHost.app (mit eingebettetem Dext), signiert mit Automatic Signing (Team JR9H9Q532P).
# bauen.sh [gruen|rot]   rot = Dext OHNE family.scsicontroller (Rotprobe, Aktivierung muss scheitern).
# Laedt/aktiviert/installiert NICHTS. Ausgabe: Pfad der App + Entitlements des Dext.
set -euo pipefail
art=${1:-gruen}; cd "$(dirname "$0")/.."
ent=Dext/Dext.entitlements; [ "$art" = rot ] && ent=Dext/Dext.rot.entitlements
dd=${TMPDIR:-/private/tmp}/blockbruecke-$art
xcodegen generate -q
xcodebuild -project Blockbruecke.xcodeproj -scheme BlockbrueckeHost -configuration Debug -derivedDataPath "$dd" \
  -allowProvisioningUpdates BB_DEXT_ENT="$ent" build | grep -E "error:|\*\* BUILD" || true
app="$dd/Build/Products/Debug/BlockbrueckeHost.app"
dext="$app/Contents/Library/SystemExtensions/de.begod.drobo.blockbruecke.dext.dext"
codesign --verify --strict --deep "$app"
echo "APP $app"
codesign -d --entitlements - --xml "$dext" 2>/dev/null | plutil -p - | grep -E "driverkit"
if [ "$art" = rot ] && codesign -d --entitlements - --xml "$dext" 2>/dev/null | grep -q scsicontroller; then echo "FAIL rot enthaelt scsicontroller"; exit 1; fi
if [ "$art" = gruen ] && ! codesign -d --entitlements - --xml "$dext" 2>/dev/null | grep -q scsicontroller; then echo "FAIL gruen ohne scsicontroller"; exit 1; fi
echo "PASS $art"
