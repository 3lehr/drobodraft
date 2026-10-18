# AI-Handoff — 2026-10-18

## fix(driverkit): match controller through nub

BB-P01 setzt den bestehenden DriverKit-Plan v0.4 um. Die Wurzel registriert sich,
der Controller entsteht über eine zweite Matching-Personality; Create/Terminate
und manuelle Controller-Lebensdauer entfallen. Warum: Create übersprang den
Kernel-Start und verursachte beim Terminieren einen NULL-Provider-Panic.

Dateien: Wurzel-/Controller-IIG, Wurzel-C++, Dext-Plist, project.yml,
bauen.sh, Matching-Guard/Selbsttest, Makefile, Plan, ADR und Brainlehr-Bindungen.
Kein zweiter Katalog: stabile BB-IDs sind im bestehenden DriverKit-Plan.

Verifiziert:
- `python3 blockbruecke/tools/check_matching.py` vor Fix: Exit 1 am echten v0.3.
- `make check-blockbruecke`: grün, 15 unsichere Varianten abgelehnt.
- `bash -n blockbruecke/tools/bauen.sh`: grün.
- `blockbruecke/tools/bauen.sh gruen --id2`: BUILD SUCCEEDED, PASS gruen.
- `codesign --verify --strict --deep blockbruecke/build/blockbruecke2-gruen/Build/Products/Debug/BlockbrueckeHost.app`: Exit 0.
- Zentraler `resource_binding_guard.py --repo /Volumes/daten/Begod2026/drobodraft`: pass.
- `git diff --check`: grün; plan_sync/status/next ohne Lücken/unknown IDs.

Belege: `blockbruecke/build/BB-P01-evidence.txt`,
`blockbruecke/build/blockbruecke2-gruen.log` (lokal/ignoriert).

Offen: BB-05 Runtime/Stop; UTM listet keine VM. Kein Aktivieren am Host.
Nächster Test: bereitgestellte VM, v0.4 aktivieren, UserInitializeController und
Provider im IOService-Baum nachweisen, vollständig deaktivieren ohne Panic/Hänger.
Danach erst UserClient/Fake-Target. Keine Gerätekommunikation ausgeführt;
5C nur lesend und EA gesperrt bleiben bindend. Produktgates nicht abgenommen.
Brainlehr: L-d7b25d, 8e97530a, ac2a4efa.
