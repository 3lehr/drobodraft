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

## BB-P02 — VM-Kapazitätsgate (2026-10-18)

Tart 2.41.1 signaturgeprüft; begrenzter Tahoe-base Pull abgebrochen, weil `df`
nach 5 s unter 28-GiB-Reserve fiel (19,4 GiB, kurz 18,6). Exakte Ursache des
transienten Verbrauchs unbewiesen; danach Daten wieder 64 GiB, System 43 GiB,
Task-Home leer, kein Tart-Prozess. Kein VM-/Dext-Start, BB-05 bleibt BLOCKED.
Konservativer neuer Vorabbedarf: 50.000.000.000 + 20 GiB = 66,57 GiB frei.
Kein erneuter Versuch; mehr freier Platz erforderlich. Keine Fremddaten gelöscht.
Belege: `blockbruecke/build/BB-P02-tart-source-evidence.txt` und
`blockbruecke/build/tart-p02-pull.log`. Brainlehr L-319c31/L-b48625/L-3c1b1d.

Kapazitätswrapper `python3 blockbruecke/tools/tart_safe_pull.py` ist vorbereitet:
aktueller Preflight verweigert vor Netzwerk bei 63,96 GiB frei gegenüber
66,57 GiB Bedarf. Selbsttest läuft über `make check-blockbruecke`.
Vor erneuter Ausführung mindestens 71.474.836.480 Byte auf Daten freistellen;
keine automatische Löschung fremder Daten. Wrapper pinnt den gemessenen
Image-Digest; ein Wächterabbruch bleibt FAIL auch bei Child-Exit 0.
BB-05 ist nicht erfüllt, UserClient/Fake-Target darf noch nicht starten.

Integrationstest: Quellmutationen `:latest` und alte `rc == 0`-Erfolgsregel
führten jeweils zu AssertionError im tatsächlichen Selbsttest (ROT); unveränderte
Quelle GRÜN. Beleg `blockbruecke/build/BB-P02-regression-evidence.txt`.
`make check-blockbruecke`, Resource-Guard und `git diff --check` grün.
