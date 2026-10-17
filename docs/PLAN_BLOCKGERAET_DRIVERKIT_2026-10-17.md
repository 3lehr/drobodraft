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
