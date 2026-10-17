# Plan: DroboPro-LUN als echtes Blockgerät am Mac (DriverKit) — 2026-10-17T18:30:22+0200

Stand: PLAN, kein Produktivcode. Kein Gerätekontakt, keine Systemerweiterung geladen. Legende: **B** = belegt (Fundstelle), **V** = Vermutung.

## Ist-Stand (gemessen 2026-10-17T18:30+0200, nur lesend)

- SDK: `DriverKit25.5.sdk` enthält `BlockStorageDeviceDriverKit`, `SCSIControllerDriverKit`, `SCSIPeripheralsDriverKit`, `NetworkingDriverKit` (B, `ls …/Frameworks`).
- **Dext hat keine BSD-Sockets** (B): `…/DriverKit/usr/include/sys/` enthält nur `cdefs.h _endian.h time.h _types.h …`, kein `socket.h`; `netinet/` nur Struktur-Header (`in.h tcp.h ip.h`). `NetworkingDriverKit` = Treiber FÜR Netzwerkkarten (`IOUserNetworkEthernet`), kein TCP-Client. Folge: iSCSI kann nicht im Dext laufen, braucht einen Benutzerprozess.
- `IOUserBlockStorageDevice::DoAsyncReadWrite(isRead, requestID, uint64_t dmaAddr, size, lba, numOfBlocks, options)` (B, `IOUserBlockStorageDevice.iig:100-117`): Daten nur als **DMA-Adresse**, kein `IOMemoryDescriptor`. Für Hardware mit DMA-Engine (NVMe-artig) gebaut; ein Weg, aus `dmaAddr` im Dext die Bytes zu lesen, steht nicht im Header (V: gibt es nicht).
- `IOUserSCSIParallelInterfaceController::UserGetDataBuffer(targetID, controllerTaskID, IOBufferMemoryDescriptor **)` (B, `IOUserSCSIParallelInterfaceController.iig:279-296`): liefert den Datenpuffer eines Befehls als Speicherobjekt — mappbar und an einen UserClient weiterreichbar. „Calling this method can have a significant impact on performance“ (Header).
- Vorhandenes Provisioning-Profil „DriverKit Team Provisioning Profile: de.begod.drobo.dextprobe.dext“, erstellt 2026-10-14T05:26:48Z, enthält `com.apple.developer.driverkit`, `…family.scsicontroller`, `…transport.usb` + `idVendor` (B, `security cms -D`). Antrag L9NZS3U6S4 vom 2026-10-08T14:57+0200 (SCSI Controller + USB Transport, VID 6585; `drobo-nas/apps/drobo-nas/docs/APPLE_ANTRAEGE_2026-10-08.md`). Dass das Profil diese Schlüssel trägt, heißt: für das Team freigeschaltet (V, stark; eine Antwort-Mail ist im Repo nicht abgelegt).
- `com.apple.developer.driverkit.userclient-access` (App-Seite): xcodebuild meldete „requires approval from Apple“, `IOServiceOpen` → `0xe00002e2` (B, `docs/PLAN_DROBO_APP_2026-10-15.md:131`). Nicht im Profil.
- Dext-Probe lief schon (B, `dext_probe/AKTIVIERUNG.md`): Aktivierung über Host-App aus `/Applications`, SIP an, ohne `developer on`. AMFI-Ablehnung bei Profil-Fehlpassung bekannt (Code -413).
- SIP: `enabled` (B, `csrutil status`). `systemextensionsctl developer on` lehnt bei aktiver SIP ab (B, AKTIVIERUNG.md:6).
- Initiator: `drobo_kern` `ISCSISitzung` (Swift, POSIX-TCP `TCPDraht`, Login mehrrundig, `befehl` mit Gate). Gate `WRITE ohne ImmediateData` → verboten (B, `ISCSIBefehle.swift:51-52`). `StatusBremse` (B, `StatusBremse.swift`). Hilfsdienst = Root-launchd-Dienst mit TCP-Weiterleitung (Local-Network-Privacy-Ausnahme, B, `fskit_probe/Helper/main.swift`, `iscsiWeiterleitung`).

## Apple-Doku (abgerufen 2026-10-17 über `developer.apple.com/tutorials/data/documentation/<pfad>.json`)

- `…family.block-storage-device`: „You must request this entitlement from Apple.“ — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.family.block-storage-device
- `…family.scsicontroller`: „Add this entitlement to the default entitlements file …“ (keine Antragszeile) — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.family.scsicontroller
- `…userclient-access`: Array der Dext-Bundle-IDs, in der **App**, die den UserClient öffnet — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.userclient-access
- `…allow-any-userclient-access`: im **Dext**, erlaubt jeder App die Verbindung — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.allow-any-userclient-access
- Antrag: „Apple ties any requested entitlements to your development team’s profile … specify the complete set of entitlements you use to support one product … You can select only one group“ — https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development
- Entwicklung: `systemextensionsctl developer on` (Ort-Prüfung aus), SIP aus umgeht Notarisierung — https://developer.apple.com/documentation/driverkit/debugging-and-testing-system-extensions
- `IOUserBlockStorageDevice` Personality: `IOClass IOUserBlockStorageDevice`, `CFBundleIdentifierKernel com.apple.iokit.IOStorageFamily` — https://developer.apple.com/documentation/blockstoragedevicedriverkit/iouserblockstoragedevice

## 1. Architektur (Entscheidung)

**Gewählt: virtueller SCSI-Controller-Dext (`IOUserSCSIParallelInterfaceController`) + Benutzerprozess (vorhandener Initiator) per UserClient.**

```
Finder/APFS/TM ─ IOMedia ─ IOBlockStorageServices ─ IOSCSIPeripheralDeviceType00 (Apple)
                                                      │ CDB
                     Dext: IOUserSCSIParallelInterfaceController (1 Target = 1 LUN)
                       UserProcessParallelTask → Ring im geteilten Speicher (CDB, Länge, Richtung)
                       UserGetDataBuffer → Puffer an UserClient (CopyClientMemoryForType)
                                                      │ IOUserClient (AsyncCallback)
                     Benutzerprozess „Blockbrücke“ (Swift, drobo_kern)
                       Gate (Allowlist, Längen, ImmediateData, EA-Sperre) → ISCSISitzung.befehl
                                                      │ TCP 3260 (über Hilfsdienst-Weiterleitung)
                                                    DroboPro / iscsi_ziel.py
```

Warum SCSI-Controller statt `IOUserBlockStorageDevice` (Auftrag nannte letzteres):
- Datenpuffer erreichbar (B, `UserGetDataBuffer`); bei BlockStorage nur `dmaAddr` (B) → ohne Hardware nicht verwendbar (V).
- Entitlement `family.scsicontroller` liegt schon im Team-Profil (B); `block-storage-device` bräuchte neuen Antrag (B, Doku).
- Apple-SCSI-Stack oben drüber = gleicher Pfad wie die 5C über USB (Recon: `IOSCSIPeripheralDeviceType00`) → APFS/TM/Finder sehen eine gewöhnliche externe Platte (V, Analogie).
- Preis: Apple sendet die CDBs, nicht wir. Gate muss Apples Befehlsmix kennen (READ/WRITE(10/16), SYNCHRONIZE CACHE 0x35, MODE SENSE(6) 0x1A, TEST UNIT READY, INQUIRY, READ CAPACITY, REPORT LUNS, ggf. UNMAP 0x42). Unbekannter Opcode → im Dext/Brücke mit CHECK CONDITION ILLEGAL REQUEST beantworten, **nie** an die DroboPro weiterreichen (EA-Sperre, L-34239c).

### Alternativen (Kriterien: Umkehrbarkeit · stille Fehlerklassen · Falsifizierbarkeit)

| Weg | Urteil | Grund |
|---|---|---|
| A) SCSI-Controller-Dext + Benutzerprozess | **gewählt** | Umkehrbar (Dext deaktivieren = Gerät weg, LUN-Inhalt bleibt); Falsifizierbar früh (Schritt 1); stille Fehlerklasse: Brücke stirbt → Apple-Stack sieht Zeitüberschreitung, nicht „weg“ → Gate muss nach Zeitgrenze ohne Brücke `Task Aborted`/Gerät entfernen |
| B) `IOUserBlockStorageDevice` + Benutzerprozess | abgelehnt (V) | nur `dmaAddr`, kein Pufferzugriff (B Header); neues Entitlement mit Antrag (B Doku). Kippt, falls Apple-Beispiel/Doku einen Mapping-Weg zeigt → dann Neubewertung (einfachere Schnittstelle, LBA statt CDB, Gate trivial) |
| C) Dext mit eigenem Netz | unmöglich (B) | keine Sockets im DriverKit-SDK |
| D) Kernel-Erweiterung (kext) | abgelehnt | Betreiberregel volle Sicherheit (Antragstext: „no third-party kexts, no reduced security“); Absturz = Kernel-Panik = laute, aber nicht umkehrbare Fehlerklasse im Lauf (Schreibpuffer verloren) |
| E) Drittanbieter-Initiator (globalSAN, ATTO Xtend SAN, KernSafe) | abgelehnt | Fremdcode im Schreibpfad ohne unsere Gates (ImmediateData-Absturz, EA-Neustart, Single-Initiator) → genau die stillen Fehlerklassen, die wir gemessen haben; nicht falsifizierbar (kein Quelltext). Bleibt als **Vergleichsmessung** zulässig (V: zeigt, ob TM eine iSCSI-LUN annimmt) |
| F) NBD/Sparsebundle über FSKit-Volume | Übergang | TM auf eingehängtem APFS-Abbild (PLAN_LUN Option b); stille Fehlerklasse kein Journal unten → Bänder beschädigt, erst bei Wiederherstellung sichtbar |
| G) FSKit bleibt allein | kein TM (V stark) | kein APFS, kein MNT_LOCAL (PLAN_LUN Option a) |

## 2. Entitlements

| Schlüssel | Wo | Stand | Antrag |
|---|---|---|---|
| `com.apple.developer.driverkit` | Dext | im Profil (B) | erledigt |
| `…family.scsicontroller` | Dext | im Profil (B) | erledigt (V: deckt virtuellen Controller) |
| `…transport.usb` + idVendor 6585 | Dext | im Profil (B) | für Blockbrücke **nicht** nötig; Profil-Gruppe ist aber ein Satz („only one group“, B) → V: neue Bundle-ID bekommt dieselbe Gruppe; ob AMFI einen Dext ohne USB-Personality mit diesem Profil annimmt = Messung Schritt 1 |
| `…userclient-access` = [Dext-ID] | App/Brücke | fehlt, „requires approval“ (B) | nur nötig, falls allow-any zur Laufzeit scheitert |
| `…allow-any-userclient-access` | Dext | **im automatisch erzeugten Profil „DriverKit Team Provisioning Profile: de.begod.drobo.blockbruecke.dext“ enthalten, signiert (B, 2026-10-17T18:40:30+0200)** | kein Antrag für Entwicklung; Schutz dann im Dext selbst (nur Root-Helper akzeptieren, V: Prüfung über `NewUserClient`-Aufrufer) |
| `com.apple.developer.system-extension.install` | Host-App | vorhanden in DextProbe (V, Probe aktivierte) | – |
| Provider: `IOUserResources` (kein Gerät) | Personality | V | evtl. kein Transport-Entitlement nötig; Messung Schritt 1 |

Bindung: Team JR9H9Q532P + Bundle-ID (Profil je App-ID, B Profilname). Ohne Entitlement lokal testen: nur mit SIP aus (Doku: SIP aus umgeht Prüfungen; `developer on` nur mit SIP aus, B). **Betreiber müsste selbst**: Wiederherstellungsmodus, `csrutil disable`, Neustart; danach `systemextensionsctl developer on`. Wir empfehlen das NICHT als Weg, nur als Notausgang, falls Apple `userclient-access` ablehnt.

Ohne UserClient-Entitlement denkbar (V, ungeprüft): Dext legt CDBs als Registry-Property ab, Brücke antwortet über… — kein Rückkanal ohne UserClient → verworfen.

## 3. FSKit-Weg bleibt, Koexistenz, Gates

- **5C (USB):** unverändert FSKit `hfsdrobo` + Status-Dext-Arbeit. Kein Matching-Konflikt: neuer Dext matcht `IOUserResources`, nicht USB (V).
- **DroboPro:** FSKit `hfsdropro` (iscsi://) bleibt als Lesepfad für bestehende HFS+-LUNs. Blockgerät nur für LUNs, die neu APFS werden. **Single-Initiator:** eine LUN ist entweder FSKit- oder Blockbrücken-verbunden, nie beides (Sperre im Kern: `netzEinhaengung(lun:)` vor Brückenstart prüfen; Brücke trägt eigenen ISID-Zweck `block-lun<N>`).
- **Gates im neuen Pfad, alle in der Brücke vor `ISCSISitzung.befehl` (eine Stelle, alle Wege laufen durch):**
  - ImmediateData: bestehend (`ISCSIBefehle.swift:51`). Erweitern auf WRITE(10) 0x2A, das Apple sendet (V) — oder Brücke übersetzt 0x2A → 0x8A. Entscheidung: übersetzen (ein Gate statt zwei).
  - Längen: `maxTransferSize` in `UserGetDMASpecification` = 524288 (MaxBurstLength, B Ist-Stand iSCSI-Plan) → Apple teilt größere I/Os selbst (V; Messpunkt Schritt 3).
  - Opcode-Allowlist: nur Liste oben; EA/MODE SELECT/E1/E2/≥0xC0 → ILLEGAL REQUEST lokal.
  - StatusBremse: Statusabfragen weiter nur ausgehängt; Brücke sendet selbst keine Status-Seiten. Bei Zeitüberschreitung: eine, dann Gerät „entfernt“ melden, kein Wiederholsturm (gleiche Regel wie Bremse).
  - Schlaf/Abmeldung: App hängt aus (bestehend), Brücke sendet Logout, Dext meldet Medium weg.

## 4. Reihenfolge (rot vor grün, jeder Schritt mit Messpunkt)

0. **Kopfprüfung ohne Gerät** (kein Laden): Dext-Gerüst bauen, `codesign -d --entitlements -` zeigt `family.scsicontroller`; rot: Profil ohne passende Gruppe → xcodebuild-Fehler. 
1. **Erster falsifizierender Test:** Dext `IOUserSCSIParallelInterfaceController` auf `IOUserResources` aktivieren (Betreiber-Klick). Messung: `log show --predicate 'process == "kernelmanagerd" OR process == "amfid"'` + `ioreg -c IOUserSCSIParallelInterfaceController`. **Kippt den Weg**, wenn (a) AMFI ablehnt (Profil passt nicht ohne USB) oder (b) `Start` scheitert, weil der Controller einen PCI-/Hardware-Provider verlangt. Dann: Neuantrag/B prüfen. Rot-Probe vorher: dieselbe Messung mit absichtlich fehlendem Entitlement → muss AMFI-Ablehnung zeigen (eicht das Messwerkzeug).
2. Dext meldet ein Target mit festem Fake-INQUIRY und READ CAPACITY 64 MiB, beantwortet READ mit Nullen **im Dext** (ohne Brücke). Messung: `diskutil list` zeigt neue externe Platte. Rot: vorher keine.
3. UserClient + Brücke gegen `drobo_kern/Tests/iscsi_ziel.py --image LUN0.img` (Abbilddatei, kein Gerät). Messungen: `diskutil eraseDisk APFS T GPT diskN` ok; `dd` 256 MiB Muster schreiben/lesen, SHA-256 gleich; Ziel-Log zeigt nur Allowlist-Opcodes und keinen Datentransfer > 524288. Fehlerinjektion: `--drop-after`, `--hang-after` → Gerät verschwindet, kein Kernel-Hänger, kein Wiederholsturm (Zählung im Ziel-Log, Muster wie Bremse-Test „1 statt 6“). `--reject-other-initiator` → Brücke meldet „belegt“. Ohne ImmediateData (Default des Python-Ziels) → **kein** WRITE im Log (Rotprobe Gate).
4. Zwei Ausgangszustände: frisch aktiviert UND nach Dext-Update/Neustart je Schritt 3 wiederholen.
5. Erst dann DroboPro (Testgerät, darf formatiert werden): eine LUN, vorher `iscsi-lunsize`-Trockenlauf-Sicherung der Seiten. Messung wie 3, plus Zieltempo; drei Läufe.

## 5. Time-Machine-Beleg

An Abbild-LUN (Schritt 3) und DroboPro-LUN (Schritt 5): `diskutil info diskNsM` → `Protocol`, `Device Location: External`, `Removable Media`; `tmutil setdestination -a /Volumes/T` (sudo, Betreiber) → Exit 0; `tmutil destinationinfo` listet Ziel; `tmutil startbackup --block` mit Kleinstsicherung (Ausschlüsse), `tmutil listbackups -d /Volumes/T` zeigt einen Eintrag; Wiederherstellung einer Datei per `tmutil restore`, Hash gleich. Danach `tmutil removedestination <ID>`. Rot: vor Schritt 3 lehnt `setdestination` auf FSKit-Volume ab (PLAN_LUN a, laut).

## 6. Bewusst nicht + Preis

- Kein `IOUserBlockStorageDevice` (Preis: komplexeres CDB-Gate statt LBA-Schnittstelle).
- Kein kext, keine SIP-Abschaltung als Normalweg (Preis: abhängig von Apple-Freigabe `userclient-access`, Wartezeit unbekannt).
- Kein Mehrfach-Initiator, kein MPIO, keine Persistent Reservation (Preis: zweiter Mac sieht LUN nicht).
- Keine Datenübernahme: LUN wird APFS neu formatiert (Preis: LUN-Inhalt weg; DroboPro = Testgerät).
- Kein Drittanbieter-Initiator im Produkt (Preis: kein Sofortweg).
- Keine EA-Befehle über die Brücke (Preis: keine LUN-Größe/Blinken aus dem Blockpfad).

## Stopp-Punkte des Betreibers (gesammelt)

1. **Entitlement-Antrag (nur falls allow-any zur Laufzeit von AMFI abgelehnt wird)** `com.apple.developer.driverkit.userclient-access` (ggf. Gruppe mit `family.scsicontroller` für neue Bundle-ID) bei https://developer.apple.com/contact/request/system-extension/ — Außenwirkung, eigenes Wort nötig.
2. **Systemerweiterung zulassen** (Systemeinstellungen > Anmeldeobjekte & Erweiterungen > Treibererweiterungen, Touch ID/Kennwort) ab Schritt 1.
3. **Kennwort/sudo:** `diskutil eraseDisk` an echter LUN, `tmutil setdestination/removedestination`, `log show` mit privaten Feldern.
4. Nur falls Apple ablehnt: SIP-Abschaltung im Wiederherstellungsmodus (Sicherheitsminderung, nicht empfohlen).
5. Formatieren einer DroboPro-LUN (Testgerät, Freigabe 2026-10-16 deckt Löschen; Wort vor Schritt 5 trotzdem bestätigen).

## Umsetzung Schritt 1 bis vor Aktivierung (2026-10-17T18:40:30+0200)

Gebaut in `blockbruecke/` (eigenes Projekt, 5C-`dext_probe` unberührt): Dext `Blockbruecke` (`IOUserSCSIParallelInterfaceController` auf `IOUserResources`, kein Target, jeder Befehl abgelehnt, Log `Blockbruecke: Start ret=0x…`), Host `BlockbrueckeHost.app` (Aktivieren/Deaktivieren per `OSSystemExtensionRequest`, wie `dext_probe/Host`).

Belege (gemessen, `tools/bauen.sh`):
- gruen: BUILD SUCCEEDED, `codesign --verify --strict --deep` ok, Dext-Entitlements `driverkit`, `family.scsicontroller`, `allow-any-userclient-access`; Profil automatisch erzeugt, enthält alle drei, ohne neuen Antrag.
- rot: BUILD SUCCEEDED, Dext-Entitlements nur `driverkit` (Rotprobe).
- Nicht gemessen: ob AMFI/sysextd zur Laufzeit annehmen (braucht Aktivierung).

### Betreiber-Schritte (Rotprobe zuerst, eicht die Messung)
1. `blockbruecke/tools/bauen.sh rot` → Pfad `APP …`. App nach `/Applications` kopieren: `ditto <APP> /Applications/BlockbrueckeHost.app`.
2. `/Applications/BlockbrueckeHost.app` öffnen, „Treiber aktivieren“. Alert „… möchte eine neue Treibererweiterung verwenden“ → Systemeinstellungen öffnen → Allgemein > Anmeldeobjekte & Erweiterungen > Treibererweiterungen (ⓘ) → `de.begod.drobo.blockbruecke.dext` einschalten, Touch ID/Kennwort.
3. Beleg rot (ohne sudo): `systemextensionsctl list | grep blockbruecke` und `/usr/bin/log show --last 5m --predicate 'eventMessage CONTAINS "blockbruecke" OR eventMessage CONTAINS "Blockbruecke"' --style compact`. Erwartet: kein `Blockbruecke: Start ret=0x0`; amfid/kernelmanagerd-Ablehnung oder kein Matching.
4. „Treiber deaktivieren“, bestätigen. `tools/bauen.sh gruen`, `ditto` erneut (ersetzt), „Treiber aktivieren“ (Ersetzen = `.replace`), ggf. Schalter erneut.
5. Beleg gruen (ohne sudo): `systemextensionsctl list | grep blockbruecke` → `[activated enabled]`; `ioreg -l -c IOUserSCSIParallelInterfaceController | grep -E "IOUserClass|Blockbruecke"`; Log-Befehl wie 3 → `Blockbruecke: Start ret=0x0`, `UserInitializeController`, `UserStartController`.
Kippt den Weg: gruen zeigt dieselbe Ablehnung wie rot (Profil/AMFI) oder `Start ret≠0` (Controller braucht Hardware-Provider).
Rückbau: „Treiber deaktivieren“, App aus /Applications löschen.

## Messung Aktivierung v0.1 und Fix v0.2 (2026-10-17T19:06:00+0200)

Rohbefunde (Betreiber klickte, Lesen per `log show`/`ioreg`, ohne sudo):
- ROT 18:44:32: Dext gestartet, exit nach 391 ms, kein `Blockbruecke: Start` — Rotprobe wie erwartet rot.
- GRUEN 18:54:15: `taskgated-helper … allowing entitlement(s) for de.begod.drobo.blockbruecke.dext due to provisioning profile` (B: AMFI nimmt Profil mit `allow-any-userclient-access` an). `openat_authenticated_np() failed … (errno 80)` gefolgt von „Loading codeless extension“ und erfolgreichem Spawn — trat auch bei ROT auf, nicht ursächlich (V).
- Zwei Prozesse 93710/93734 laufen, zwei `IOUserServer` mit `IOAssociatedServices` 0x1000916ad/0x1000916af; diese IDs stehen **nicht** im IOService-Plane. `IOKitDiagnostics` zählt `"IOUserSCSIParallelInterfaceController"=2` Instanzen: Kernelobjekte entstanden, hängen aber an keinem Provider. Keine einzige Logzeile der Dext-Prozesse.
- Apple-Quelle `IOSCSIParallelFamily` (github apple-oss-distributions, `IOSCSIParallelInterfaceController::start`): kein PCI-Zwang für User-Controller (`provider->open` und Interrupt nur ohne Dext). Also nicht „braucht Hardware“.
- Muster an diesem Mac (ioreg): alle Apple-Dexts auf `IOUserResources` nutzen `IOClass IOUserService` und legen Unterobjekte über eine verschachtelte Personality an (`IOUserDockChannelSerial` → `"PTY"={"IOClass"="IOUserSerial",…}`).

Ursache (V, stark): Familienklasse direkt als Personality auf `IOUserResources` wird instanziiert, aber nie angehängt/gestartet. Kernel-DK-Meldungen sind in diesem Build stumm (`DKLOG` nur mit Debug-Flag, xnu `IOUserServer.cpp:5854`), daher keine Logzeile vom Kernel.

Fix v0.2 (gebaut, `bauen.sh gruen` PASS, CFBundleVersion 2): Personality `IOClass IOUserService`/`IOUserClass BlockbrueckeWurzel` auf `IOUserResources`; Wurzel ruft `Create(this, "BlockbrueckeController", …)` mit Unterpersonality `IOUserSCSIParallelInterfaceController`/`Blockbruecke`. Logpunkte trennen die Stufen: `Wurzel init` → `Wurzel Start ret` → `Controller init` → `Start ret` → `UserInitializeController` → `UserStartController` → `Wurzel Create(Controller) ret`. `bauen.sh` meldet Build-Fehler jetzt als FAIL (vorher PASS mit alter App).

Betreiber: `ditto <APP aus bauen.sh gruen> /Applications/BlockbrueckeHost.app`, App öffnen, „Treiber aktivieren“ (Ersetzen 1→2), Schalter falls verlangt. Beleg: `/usr/bin/log show --last 5m --predicate 'eventMessage BEGINSWITH "Blockbruecke:"' --style compact` und `ioreg -w0 -t | grep -iE "Blockbruecke|IOUserSCSIParallel"`. Erwartet grün: alle sieben Logzeilen, `ret=0x0`, Controller unter `IOUserResources` > `BlockbrueckeWurzel` sichtbar. Fehlt nach `Wurzel Start` die Zeile `Controller init`, scheitert `Create` im Kernel (ret-Wert steht im Log).

## Hängende Deinstallation und Fix v0.3 (2026-10-17T19:28:55+0200)

Befund 19:20 (Koordinator): v0.1-Prozesse 93710/93734 „terminating for uninstall but still running“, kernelmanagerd `SysExtensionWaitForUninstallTerminationError`; v0.2 „activated enabled“, nie gestartet. Gelesen (2026-10-17T19:28:55+0200): `systemextensionsctl list` zeigt 0.1 und 0.2 je „terminating for uninstall but still running“ und 0.2 „activated enabled“.

Ursache v0.1-Hänger (B, Quelle + ioreg): xnu `IOUserServer.cpp:5813` beim Beenden der Dienste eines Servers: `if (!provider) { DKLOG("stale service … found, skipping termination") ; return false; }`. Die v0.1-Kernelobjekte haben keinen Provider (nicht im IOService-Plane, siehe oben) → werden nie terminiert → Dext-Prozess endet nie → sysextd wartet. Das liegt am v0.1-Matching, nicht an fehlendem Stop-Code; v0.2/0.3 hängen den Controller über `Create` an die Wurzel (Provider vorhanden).
v0.2 startet nicht (V): sysextd/kernelmanagerd starten die neue Version derselben Bundle-ID erst nach Ende der alten.

Fix v0.3 (gebaut, CFBundleVersion 3):
- `Blockbruecke::Stop`: Log, `Stop(provider, SUPERDISPATCH)` am Ende, Rückgabe durchgereicht (Doku IOService::Stop: „Call super at the end of your implementation … Don’t use this method to release your ivars“, https://developer.apple.com/documentation/driverkit/ioservice/stop).
- `BlockbrueckeWurzel::Stop`: per `Create` erzeugtes Kind mit `Terminate(0)` beenden, dann super; Logzeilen mit ret.
- `IOMatchCategory` = eigene Bundle-ID, Host leitet Dext-ID aus eigener Bundle-ID ab.
- Fallback-ID: `tools/bauen.sh gruen --id2` → `de.begod.drobo.blockbruecke2(.dext)`, eigenes Profil „DriverKit Team Provisioning Profile: de.begod.drobo.blockbruecke2.dext“ automatisch erzeugt, Entitlements wie gruen (B, codesign/security cms). Umgeht die hängenden alten Instanzen ohne Neustart.

Stopp-Punkt hängende Altinstanzen (Betreiber, Kennwort): ohne Neustart nur `sudo kill 93710 93734` (V: Prozessende → IOUserServer räumt auf, sysextd schließt Deinstallation ab; Beleg `systemextensionsctl list` ohne „still running“). Sonst bleiben die Einträge bis zum nächsten Neustart, stören `…blockbruecke2` aber nicht (eigene ID, eigene IOMatchCategory).

Messung ohne Neustart (mit `--id2`):
1. `ditto <APP aus bauen.sh gruen --id2> /Applications/Blockbruecke2.app` (eigener Name, alte App bleibt), öffnen, „Treiber aktivieren“, Schalter `de.begod.drobo.blockbruecke2.dext`.
2. Start-Beleg: `/usr/bin/log show --last 5m --predicate 'eventMessage BEGINSWITH "Blockbruecke:"' --style compact`, `ioreg -w0 -t | grep -iE "Blockbruecke|IOUserSCSIParallel"`.
3. Stop-Beleg (grün): „Treiber deaktivieren“ → Log `Wurzel Stop`, `Wurzel Terminate(Controller) ret=0x0`, `Controller Stop ret=0x0`, `Wurzel Stop ret=0x0`; `pgrep -fl blockbruecke2` leer binnen 30 s; `systemextensionsctl list | grep blockbruecke2` ohne „still running“.
4. Rot zum Vergleich ist v0.1 (gemessen: hängt). Eigene Rotprobe für den Stop-Pfad nur, falls 3 grün und Zweifel bleiben: Variante ohne `Terminate(Controller)` muss bei Schritt 3 hängen (kostet ggf. wieder ein `sudo kill`).

## Kernel-Panic 2026-10-17 ~19:35 — Analyse (2026-10-17T19:50:01+0200, nur gelesen)

**Panic** (`/Library/Logs/DiagnosticReports/panic-base+socd-2026-10-17-193924.000.panic`): „Kernel data abort at pc 0xfffffe00461b2c3c“, `x0: 0x0`, `far: 0x0`, Kext im Backtrace `com.apple.iokit.IOSCSIParallelFamily(3.0)@0xfffffe00461b2680`, KernelCache slide 0x3b658000, Fileset-UUID 9FA0EFBB-….
**Symbol** (B): Kernelcache aus Preboot (UUID 9FA0EFBB passt) per `compression_tool -decode -a lzfse` entpackt, Fileset-Eintrag IOSCSIParallelFamily: `__TEXT_EXEC` 0xfffffe000ab5a680 = Panic-Basis − Slide; Symtab des Eintrags: pc − Slide = 0xfffffe000ab5ac3c = **`IOSCSIParallelInterfaceController::didTerminate(IOService*, unsigned int, bool*) + 0x28`**.
**Quelle** (apple-oss-distributions/IOSCSIParallelFamily, `IOSCSIParallelInterfaceController.cpp`): `didTerminate` beginnt mit `if ( fProvider->isOpen ( this ) == true )` ohne NULL-Prüfung. `fProvider` wird nur in `start()` nach erfolgreichem `super::start` gesetzt.
**Warum fProvider NULL war** (B, xnu `iokit/Kernel/IOUserServer.cpp`, `IOService::Create_Impl`): `Create` macht nur `allocClassWithName` → `init` → `attach(this)` → `serviceAttach` und setzt `uvars->started = true` — **es ruft nie den Kernel-`start()`** der erzeugten Klasse. Der per `Create` angelegte Controller (v0.2) hatte daher nie `fProvider`; Prozessende (`sudo kill`) bzw. Ersetzen terminiert ihn → `didTerminate` → NULL-Zugriff → Panic.
**Ursache:** unser Entwurf v0.2/v0.3 (Familienklasse per `Create`), nicht Apples Fehler allein (fehlende NULL-Prüfung macht ihn tödlich statt laut).

**v0.3 seit Neustart** (B, `log show` ab 19:39): `Blockbruecke: Wurzel init`, `Wurzel Start ret=0x0`, `Wurzel Create(Controller) ret=0xe00002c7` (kIOReturnUnsupported). `kmutil showloaded`: IOSCSIParallelFamily **nicht geladen**; `Create_Impl` liefert Unsupported, wenn `allocClassWithName` scheitert (V stark: Klasse unbekannt, weil Kext nur über Matching nachgeladen wird; vor dem Neustart hatte v0.1-Matching ihn geladen — „last started kext IOSCSIParallelFamily“). Wurzel-Start scheitert → kein Wurzel-/Controller-Objekt im ioreg, nur `IOUserServer(…0x1000012ea)`; `IOKitDiagnostics` ohne `IOUserSCSIParallelInterfaceController`-Instanz.

**Ist Deaktivieren jetzt gefährlich?** Im jetzigen Zustand nein (V stark): es existiert kein IOSCSIParallel-Objekt, also kein `didTerminate`. Bedingung vor dem Klick: `kmutil showloaded | grep -i SCSIParallel` leer und `ioreg -l -w0 -d1 | grep -o '"IOUserSCSIParallelInterfaceController"=[0-9]*'` leer. **Gefährlich wird v0.3, sobald der Kext geladen ist** (dann gelingt `Create` → derselbe Sprengsatz). Deshalb: v0.3 nur noch deaktivieren, nie neu aktivieren/ersetzen, solange der Kext geladen sein könnte.

**Invarianten (ab jetzt bindend)**
1. Nie eine Familien-Kernelklasse (`IOUserSCSIParallelInterfaceController` u. ä.) per `IOService::Create` anlegen — `Create` ruft keinen Kernel-`start()` (B). Familienobjekte nur über Matching (Kernel ruft `probe/start`).
2. Nie einen Dext-Prozess beenden (`kill`), solange ein Familienobjekt existiert; Entfernen nur über „Treiber deaktivieren“.
3. Vor jedem Deaktivieren/Ersetzen: ioreg-Zustand messen (Controller im IOService-Plane **mit** Provider, Logzeile `UserInitializeController` gesehen = Kernel-`start` lief, `fProvider` gesetzt).
4. Controller erst veröffentlichen (Matching auslösen), wenn die Wurzel vollständig gestartet ist; jede neue Stufe zuerst unter eigener Bundle-ID (`--id2`).

**Weiterbauen (Vorschlag v0.4, nicht gebaut):** Wurzel bleibt `IOUserService` auf `IOUserResources`, trägt in ihrer Personality eine Kennung (z. B. `BlockbrueckeNub = true`) und ruft `RegisterService()`. Zweite Personality: `IOProviderClass IOUserService`, `IOPropertyMatch {BlockbrueckeNub: true}`, `IOClass IOUserSCSIParallelInterfaceController`, `CFBundleIdentifierKernel com.apple.iokit.IOSCSIParallelFamily` → Kernel lädt den Kext, ruft `start` mit echtem Provider (Wurzel) → `fProvider` gesetzt. Erster Messpunkt: Log `UserInitializeController` + Controller im ioreg unter der Wurzel. Erst danach Deaktivieren messen. Offenes Risiko (V): stirbt der Dext **während** Kernel-`super::start`, bleibt `fProvider` NULL; ob dann `didTerminate` läuft, ist aus der Quelle nicht sicher abzulesen → Messung nur unter `--id2`, Prozess nie beenden.

Lehre: Ein DriverKit-`Create` ist kein Ersatz für Matching; „ret=0x0“ beim Anlegen sagt nichts über den Kernel-Start der Familienklasse.

## Wiedereinstieg (2026-10-17T19:58:30+0200)

- Treiber v0.3 (de.begod.drobo.blockbruecke.dext) aktiv, aber leer: IOSCSIParallelFamily nicht geladen, kein Controller (geprüft 2026-10-17T19:58:30+0200). Deaktivieren ist so gefahrlos; Klick in BlockbrueckeHost „Treiber deaktivieren“ steht aus (Betreiber).
- Nächster Schritt: v0.4 (Nub + Matching statt IOService::Create, eigene Bundle-ID --id2), Test bevorzugt in VM. Invarianten siehe Abschnitt Kernel-Panic.
- Offen DroboDraft-App: Schachtlampen grau (Ursache unbekannt), Dashboard-Mitschnitt LUN-Größe (en8!), LUN-Befehle 0x0F/0x12/0x13 nur gegen Python-Ziel getestet, Gate zu.
