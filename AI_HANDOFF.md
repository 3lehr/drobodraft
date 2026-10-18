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

## BB-P03 — externer Speicher, Pending-I/O (2026-10-18)

Betreiber benennt externe SSD; Kapazität 228 GiB, HFS+. Repository unverändert
am bisherigen Ort. `DROBO_VM_STORAGE` bindet Home/Log/Freiplatz an einen lokalen
Taskordner; keine private Volumebezeichnung in versionierten Quellen.
Ein Pull blieb nach 50-GB-Allokation bei 0 Prozent. Nach gezieltem Stop blieb
ein exiting Tart-Datensatz ohne offene Handles; Cleanup eigener Dateien blieb
im Kernelzustand U. Ursache unbewiesen, Disk-Zähler zeigten aktive I/O.
120-s-Beobachtung beendet, keine neue Mess-/Retryserie oder Gast-/Dextaktivierung.
Exakte bekannte PID/Taskpfade nur `blockbruecke/build/BB-P03-pending.txt` (ignoriert).
Cleanup und Platzrückgabe NICHT abgeschlossen/bestätigt; BB-05 bleibt BLOCKED.
Sicher weiter: Platte verbunden lassen, I/O abwarten; kein Force-Eject/Reboot
oder Formatieren. Erst nach neuer Zustandsprüfung darf ein neuer Versuch beginnen.

## BB-P05 — reine CDB-Vorbereitung (2026-10-18)

`BlockCDB.swift` + `ISCSITests.swift`: READ/WRITE(10)→16, Datenrichtung,
Transferlimit, LUN-Grenzen/Overflow; unverändertes Send-/ImmediateData-Gate.
Warum: Vorbereitung des gewählten Brückenwegs ohne blockierte Kernelintegration.
Rot: fehlender Adapter, danach übergroße INQUIRY-Länge als fehlschlagender Test.
Grün: im `drobo_kern`-Ordner
`DROBO_TESTDIR=/Volumes/daten/Begod2026/drobodraft/blockbruecke/build xcrun swift test --filter ISCSITests/testBridgeAdapter`
→ 3 Tests / 0 Fehler; nur Loopback-Ziel. Kein UserClient-/Gerätetest.
Risiko/Grenze: zukünftige DriverKit-Verwendung erst nach BB-05; keine Aussage
über Lampen-Livefehler (bisher nur Fixture-Quellinspektion, Mitschnitt fehlt).

VM-Gate weiter: Cleanup-PID 52780 U, Tart-Datensatz 45129 ?E im letzten Check.
/daten zuletzt 61,68 GiB frei, Mindestbudget 71.474.836.480 Byte;
5.235.983.360 Byte (4,88 GiB) fehlen. Keine löschbaren eigenen GiB-Outputs belegt.
Lokale kleine APFS/RAW-Probe erfolgreich, externe I/O nicht wiederholt.
Nächste Betreiberhandlung: geeigneten Speicher bereitstellen oder /daten über
Mindestbudget bringen; SSD-I/O erst auslaufen lassen, kein Force-Eject.

Uncommitted Grenze: `blockbruecke/tools/tart_safe_pull.py` (BB-P03 externer
Validator), keine erneute reale externe Bindungsprüfung möglich. BB-P05 darf
mit Plan/Manifest/Handoff isoliert committen; diese Datei bleibt unstaged.
Brainlehr: e10dee42, L-a76324, efb7a14a, L-dc602d, L-b4609d.

## fix(vm): preserve guarded Tart resume — BB-P06 (2026-10-18)

Der immutable Tahoe-Pull endete mit Exit 0; geklonte headless VM lief und der
Tart Guest Agent antwortete. Gast: macOS 26.6.2, CSR disabled durch das
vorgefertigte Image; keine SIP-/AMFI-Änderung. Beide gültigen Provisioningprofile
enthalten die Gast-UUID nicht. Dext-Entitlements passen zum Profil; App-Abgleich
nicht parsebar. Aktivierung scheiterte mit RBS/POSIX 162; Crashreport meldet
CODESIGNING / Code Signature Invalid. Kein UserInitializeController-, Provider-
oder Stop-PASS: BB-05 bleibt BLOCKED, Produktgates OPEN.
Bundle-IDs: App `de.begod.drobo.blockbruecke2`, Dext
`de.begod.drobo.blockbruecke2.dext`.

Legitime Signierroute: keine Developer-ID-Application-Identität gefunden;
`-allowProvisioningUpdates` ist in Xcode verfügbar, beide Profile sind keine
`ProvisionsAllDevices`-Profile. Betreiber muss die Gast-UUID aus der ignorierten
lokalen Datei `blockbruecke/build/BB-P06evidence/guest-registration-udid.txt`
im vorhandenen Apple Developer Team registrieren bzw. Profile erneuern; danach
`blockbruecke/tools/bauen.sh gruen --id2`. Kein Portal-/Credential-Zugriff.
Nächster Test nach der Betreiberregistrierung: neu signiertes v0.4-Artefakt in
derselben headless VM aktivieren, `UserInitializeController`/Provider belegen,
danach normal deaktivieren und terminalen Guest-Status belegen.

Wrapper enthält APFS-/TART_HOME-Binding mit zwei Kapazitätswächtern, Digest-
Preflight, markergebundener nativer Resume-Validierung, Concurrency 4 und
PID-gebundenem caffeinate. Reviewkorrektur erhält validierte Partialdaten, wenn
der Preflight vor Prozessstart am Platz scheitert. Red/green: vor Fix meldete
ein unpinned `:latest`-Lauf PASS; danach runtime refusal vor Nebenwirkungen.
Vor der Partial-Korrektur löschte `python3 blockbruecke/tools/tart_safe_pull.py
--self-test` eine markergebundene Fixture (Exit 1); danach `make
check-blockbruecke` grün. `git diff --check` grün.

Geprüft: `tart exec --help` zeigt `tart exec <name> <command> ...`; `--`
verursachte rc125, korrigiert durch Wiederholung ohne Trenner. Plan: BB-09
RUNTIME-VERIFIED, Produktgate OPEN; BB-05 BLOCKED. Keine Provider-/Start-/Stop-
Abnahme. Geänderte Dateien und vorgesehene Commitgrenze:
`blockbruecke/tools/tart_safe_pull.py`,
`docs/PLAN_BLOCKGERAET_DRIVERKIT_2026-10-17.md`, `AI_HANDOFF.md`; keine fremden
Changes im geprüften Arbeitsbaum.
Brainlehr: 036f110f, L-2a5737, L-00a72f, L-6fa9a7, 9b65ef41, 8e97530a, 0b6d3d2f, L-01ea2b.
