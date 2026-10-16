# Gemeinsame Kennung fuer die Werkzeug-Skripte (mit `. identity.sh` einlesen): Praefix und Team aus Identity.xcconfig,
# Identity.local.xcconfig hat Vorrang, Umgebung DROBO_BUNDLE_PREFIX / DROBO_TEAM noch davor.
_ident_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
_ident_lies() { for f in "$_ident_dir/Identity.local.xcconfig" "$_ident_dir/Identity.xcconfig"; do [ -f "$f" ] && sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$f" | head -1 | tr -d ' ' && return; done; }
DROBO_BUNDLE_PREFIX=${DROBO_BUNDLE_PREFIX:-$(_ident_lies DROBO_BUNDLE_PREFIX)}
DROBO_TEAM=${DROBO_TEAM:-$(_ident_lies DROBO_TEAM)}
DROBO_APP_ID="$DROBO_BUNDLE_PREFIX.drobofsprobe"
DROBO_MODULE_ID="$DROBO_APP_ID.fsmodule"
# Arbeitsordner fuer Bauprodukte: Vorgabe im Repo (build/ ist ignoriert), nicht auf dem Rechner des Autors.
DROBO_BUILD=${DROBO_BUILD:-$(cd "$_ident_dir/.." && pwd)/build}
