# Drobo-5C-Protokoll: Recon von Drobo Dashboard 3.6.1 und DDService64d

Stand: 2026-10-14T07:46:54+0200 · Nebenpfad Dashboard (P7) zu `docs/PLAN_FSKIT_HFS_2026-10-14.md` · nur gelesen, nichts an Geräten ausgeführt, DDService64d nicht gestartet, keine Befehle an die Drobo.

Kennzeichnung: **B** = belegt (Fundstelle am Binary, Header oder Quelltext), **R** = Bericht (Quelle ohne eigenen Lauf), **V** = Vermutung (ungeprüft).
Werkzeug: REA 6.4.0 hat hier keine Analyse-Engine (Hopper, Ghidra, IDA fehlen laut `rea doctor`; `rea analyze/decompile` → `provider_unavailable`). Gelesen mit `nm`, `otool`, `strings`, `llvm-objdump -d` (Xcode) und Registerverfolgung per Skript. Kein Dekompilat; Opcodes stammen aus Disassembly und sind unabhängig gegen drobo-utils abgeglichen (Abschnitt 4).

## 1. Inventar (B)
Annahme „.NET/Mono“ ist falsch: alles native Mach-O.

| Komponente | Art | Befund |
|---|---|---|
| `/Applications/Drobo Dashboard.app` 3.6.1 [115880] | Mach-O **x86_64** (läuft unter Rosetta), C++/ObjC, Cocoa+OpenGL+WebKit | `.xaml` und `strings_*.xml` liegen nur als Ressourcen in `Contents/Resources` (565 versiegelte Dateien), eigene UI-Engine. Signatur Developer ID Drobo Inc., Team 7L83S9698G, 2021-02-22 |
| `/Library/Application Support/Data Robotics/Drobo Dashboard/DDService64d` | Mach-O x86_64, 7,3 MB, **16 710 lokale Symbole** (C++, nicht gestrippt) | Links: IOKit, DiskArbitration, SystemConfiguration, Security |
| LaunchDaemon `com.datarobotics.ddservice64d` | RunAtLoad + KeepAlive | **nicht geladen** (`launchctl print` → „Could not find service“, kein Prozess, Port 4502 nicht offen). Nur `DDAssist` läuft |
| `/Library/Extensions/TrustedDataSCSIDriver.kext` v1.9.1 | Kext, fat x86_64+arm64e, Klasse `com_TrustedData_driver_VendorSpecificType00`, UserClient `com_TrustedData_UserClient_SCSIType00` | Personality 22 matcht `IOSCSIPeripheralDeviceNub`, Vendor „Drobo“, Product „5C“, PDT 0 (Info.plist). **Nicht geladen** (`kmutil showloaded`: 0 Treffer) |
| `/Library/Extensions/DroboTBT.kext` v1.4 | PCI/Thunderbolt-Controller (`IOPCIMatch 0x38444452`, `0x55704452`) | für die USB-5C irrelevant |
| `/Applications/DroboMenubar.app` | eigenes Bash/Python-Skript (`scripts/drobo-menubar.py`) | kein Drobo-Produkt |

Live-Zustand der 5C (B, `ioreg -l`): `Drobo5C@02200000`, VID 6585 (0x19B9), PID 13379 (0x3443), Interface 8/6/80 (BOT). Gebunden an Apples `IOSCSIPeripheralDeviceType00` (Max 1 048 576 B Lesen/Schreiben), **nicht** an die Drobo-Kext. Der `IOSCSILogicalUnitNub` trägt `IOMatchCategory = SCSITaskUserClientIniter`.
Folge (B+V): DDService64d fände auf diesem Mac keine Zielklasse; selbst gestartet könnte er die 5C nicht ansprechen. Kext laden auf Apple Silicon braucht reduzierte Sicherheit (V).

## 2. Transport auf macOS (B)
- `nm -u DDService64d`: `IOServiceMatching`, `IOServiceGetMatchingServices`, `IOServiceOpen`, `IOConnectCallStructMethod`, `IOConnectCallScalarMethod`, `IORegistry*`, `DADisk*`. **Kein** `IOCreatePlugInInterfaceForService` (also kein SCSITaskUserClient/IOUSBLib-Plugin), kein IOUSBHost.
- String `com_TrustedData_driver_VendorSpecificType00` (Matching-Name, `dd.strings` Z. 26035) und `kTrustedDataUserClientOpen failed`. Pfade `/com_TrustedData_driver_VendorSpecificType00/IOBlockStorageServices/IOBlockStorageDriver/Drobo 5C Media`.
- Klasse `IOCSCSISession::execute(SCSIRequest&)` @`0x1000ad55c` ruft `IOConnectCallStructMethod` (Stub `0x1003b6806`) mit Selektor 6 oder 7, Struktur 32 B.
- Kext-UserClient `externalMethod`, Tabelle `sMethods` @`0xb950` (je 24 B): 0 open · 1 close · 2 getESAModePage (2 Scalar-In, 1308 B out) · 3 setESAModePage (3 Scalar, 1308 B in) · 4 vendorSpecificOut (24 B) · 5 vendorSpecificIn · **6 PassThroughOut (32 B)** · **7 PassThroughIn (32 B in, 4 B out)** · 8 setLoggingLevel · 9 ataRead (40 B in, 16 B out) · 10 ataWrite.
- Netz nur für NAS/iSCSI-Modelle: `ESANASSession`, UDP-Discovery (`DRIDPROP`, `DRINASD4`), `xtendsancli`; lokaler Listener `SkyPCManager::Listen` (`0x10003e810`, Portkonstante 0x1196 = 4502, 127.0.0.1) für die GUI. Für die 5C unerheblich.
- GUI→Dienst-Befehle `eCmd*` (`dd.strings` Z. 24136-24243, u. a. `eCmdModeSense`, `eCmdFormatDevice`, `eCmdStandby`, `eCmdInstallFirmware`).

## 3. Protokoll (B, Disassembly + drobo-utils)
Alles läuft über **Page 0x3A (herstellerspezifisch, SPF)**; Antwortseite beginnt mit `0x7A, <Subseite>, Länge`.

**CDBs (10 Byte):**
- Lesen: MODE SENSE(10) `5A | LLBAA<<4 \| DBD<<3 | 3A (PC<<6) | Subseite | 0 0 0 | Len_hi Len_lo | 0` — `ModeSenseSCSIRequest::ModeSenseSCSIRequest` @`0x1000c5420` (Dashboard: DBD=1, Seite 0x3A, Subseite = Seitennummer).
- Schreiben: MODE SELECT(10) `55 01 7A <Subseite> …` (Form nach drobo-utils; Dashboard baut `55 | PF<<4 or SP | …`) — `ModeSelectSCSIRequest` @`0x1000c5500`, Kext `SetModePage` @`0x1734`.
- VPD-INQUIRY 6 Byte `12 01 <Seite> 00 <Len> 00` (`VPDInquirySCSIRequest` @`0x1000c5224`; Seite 0x80 = Seriennummer).
- **Systemoperationen** `EA 10 <dir 0x80=ein> <Op> <arg> 00 <Flags (bit6 Cancel, bit5 FSEQ)> <Len BE16> <Ctl>` — `ESASystemOperationRequest` @`0x1000c56e4`. Die Dashboard-Dienstseite lässt über IOKit **nur** `EA` mit Byte1=0x10, `12`, `5A`, `55` zu (`IOCSCSISession::execute` cmpb 0x12/0x5A/0x55/-0x16, `cmpl $0x1000`).
- Kext-Whitelist für PassThrough (`CREATE_PASS_THROUGH_CDB` @`0x22ea`, Bitmasken `0x4000010000000001` und `0x1080000000001` entschlüsselt): nur `12`, `28`, `2A`, `55`, `5A`, `EA`; CDB-Länge 6 oder 10. **WRITE(10) ist erlaubt.**

**Lese-Subseiten** (`getSubPageType()` je Klasse, Rückgabe-Immediate): 0x01 Configuration (Slots, max LUN, max LUN-Größe, DemoMode, ScaleFactor, readonly) · 0x02 Capacity (4×u64 BE ab Byte 4: frei/benutzt/gesamt geschützt/gesamt ungeschützt) · 0x03 SlotInfo · 0x04 LUNInfo · 0x05 SystemSettings (Zeit, GMT, Name) · 0x06 ProtocolVersion (**zuerst lesen**, steuert Strukturgrößen) · 0x07 LUNInfo2 · 0x08 FirmwareInfo (Version, Build, Datum, Arch) · 0x09 Status (u32-Bits, Disk-Pack-Status, Relayout) · 0x11 DiskPackInfo · 0x10 Snapshot · 0x15 LUNMapping · 0x30 Options (Gelb-/Rot-Schwelle) · 0x31 Options2 · 0x33 SystemInfo · 0x34 SystemPerformance · **0x35 SlotInfo2** · 0x36 PowerSupply · 0x37 Fan · 0x38 ControllerCard · 0x39 Expander · 0x3A Battery · 0x82 KernelInterfaceInfo.
**SlotInfo2** (108 B je Slot, `ESASlotInfoStruct2::parse` @`0x10009d534`, Größe `calculateSize` = 0x6C): +0 u8 Slot-Id · +1 u8 Slot-Status · +2 u16 Fehlerzähler · +4 u32 Disk-Zustand · +8 u8 Typ · +9 u8 **Temperatur** · +A u8 **Restlebensdauer** · +B u8 Drehzahl · +C char[44] Hersteller/Modell · +38 char[12] Firmware · +44 char[24] Seriennummer · +5C u64 Kapazität · +64 u64 verwaltete Kapazität. Feldnamen aus `print()`-Strings; Einheiten (°C, %) **V**.
Lüfter, LED-Zustände, Rebuild-/Relayout-Fortschritt: nur Klassen/Subseiten belegt (0x37, 0x09), Byte-Offsets nicht ausgewertet.

## 4. Öffentliche Referenz drobo-utils (B, Quelle gelesen)
Repo `github.com/petersilva/drobo-utils`, Stand `fd4ff89` (2025-10-20), Python, `DroboIOctl.py` (SG_IO 0x2285) + `Drobo.py`. Dieselbe Sprache: `Drobo.py:459` `pack(">BBBBBBBHB", 0x5a, 0, 0x3a, sub_page, …)`; `Drobo.py:503` `0xea, 0x10, 0x00, command, 0, txnID, 1<<5, 1, 0` (Kommentar: 0x06 blink, 0x0d Standby); `:618` 0xea/0x10/0x0f LUN-Größe; `:660` Diagnose 0x80/Code 4 und 7; `:1030/:1076` Firmware 0x70/0x71; Schreiben `0x55 0x01 0x7a <sub>` (`:546,562,594`). Lese-Subseiten 0x01-0x09, 0x30, 0x31 dort gebraucht → Dashboard-Opcodes **unabhängig bestätigt**. Unterschied: drobo-utils setzt Byte 5 = Transaktions-ID, das Dashboard 0.
Modelle laut README: Gen1/2, Share, Pro, Elite, S, FS; Repo-Kopf: „vintage 2008“. **5C nicht gelistet** (R: README-Matrix). Dass die 5C dieselbe Page-0x3A-Sprache spricht, stützt: Kext-Personality 22 „5C“ nutzt dieselbe Klasse (B), das Dashboard 3.6.1 unterstützt 5C ausdrücklich (`Drobo 5C Media`, B). Die Slot-Struktur im Repo (72 B, `HBQQB32s16sL`) weicht vom Dashboard-SlotInfo2 (108 B) ab → für die 5C zuerst ProtocolVersion lesen und **nicht** blind drobo-utils-Strukturen übernehmen (V).

## 5. Gefährliche Befehle: im eigenen Werkzeug sperren (Allowlist statt Denylist)
Erlaubt (Vorschlag): `INQUIRY 12` (Standard, VPD 0x00/0x80) und `MODE SENSE(10) 5A` mit Seite 0x3A und Subseite aus Whitelist {0x01-0x09, 0x30, 0x31} (durch drobo-utils-Nutzung bewährt); 0x33-0x3A/0x35 erst nach Eichung. Alles andere zu.
Gesperrt (B, Dashboard-Disassembly, Registerverfolgung heuristisch):
- `EA 10` komplett. Op-Codes: 0x02 **Format** (`formatESA`) · 0x03 Restart · 0x05 **Crash** (`crashESA`) · 0x09 Flash-Config/Demo · 0x0A `runEsaCommand` (beliebiger ESA-Befehl) · 0x0B Used-Capacity · 0x0D **Standby** (`ESA_SYSOPID_STANDBY_ESA`) · 0x0F LUN-Größe/Resize · 0x16 Write-Host-Buffer · 0x17 **Power-Off** · 0x18 Dimming · 0x70 **Firmware schreiben** · 0x71 Firmware-Status · 0x80 **Revert Firmware**. Lesend, aber ebenfalls zu: 0x06 Identify/Blink, 0x08 LEDs, 0x15, 0x20, 0x21, 0x22, 0x23, 0x81, 0x83, 0x84, Diagnose 4/7.
- `MODE SELECT(10) 55` mit Seite 0x3A: 0x05 SystemSettings, 0x0A CHAP, 0x0B SingleInitiator, 0x0C Used-Capacity, 0x0D LUN-Name, 0x30/0x31 Options, 0x32 Netz, iSCSIAdmin (Dashboard `set*`-Methoden).
- **MODE SENSE mit Nebenwirkung:** Seite 0x3A, Subseite **0xE1/0xE2** = Laufwerk einstecken/entfernen (`insertRemoveDrive` @`0x1000a92fa`, CDB `5A 08 3A <E1|E2> <Slot> …`). Eine Allowlist mit Subseiten fängt das; eine Opcode-Sperre nicht.
- WRITE(6/10/16), FORMAT UNIT, UNMAP, START STOP UNIT, SYNCHRONIZE CACHE, WRITE BUFFER, ATA-Selektoren 9/10 (Kext: beliebige LBA lesen/schreiben): generisch gesperrt, Drobo-Verhalten ungeprüft.
- Host-Seite des Dashboards (`newfs_hfs`, `diskutil`, `FormatMacDiskWithDefaults`): außerhalb jedes Statuswerkzeugs.

## 6. Wege ohne den Drobo-Dienst
- **(a) Eigener Dext, `IOUserSCSIPeripheralDeviceType00`** — *B (SDK-Header)*: `UserSendCDB` schickt eine beliebige 16-Byte-CDB; „Exclusive access must be obtained … vendor specific commands i.e. opcode 0 between 0xC0 and 0xFF“; `UserSuspendServices` = Exklusivzugriff, „Volume must be unmounted“. Folge: `5A`/`12` gehen laut Header ohne Exklusivität, `EA` nur ausgehängt. Ein Dext muss ohnehin an „Drobo“/„5C“ gebunden werden (Schreibkappung 512 KiB, Plan Phase 0b) und kann Status als UserClient (`NewUserClient`, V: Entitlement `driverkit.userclient-access` an der App) nach außen reichen. *R/V*: Nichts davon an der Drobo gelaufen. Dext-Probe signiert, Aktivierung wartet auf Betreiber (`macos/dext_probe/AKTIVIERUNG.md`); aktueller Entitlement-Satz dort: driverkit, family.scsicontroller, transport.usb.
- **(b) Linux-VM + SG_IO** — *R*: drobo-utils nutzt exakt das (SG_IO auf `/dev/sdX`, root). *B*: bestehende VM reicht die Platte als **virtio-blk Rohgerät** durch (`PLAN_LINUX_VM`) → dort **kein** SCSI-CDB-Pfad. Nötig wäre USB-Durchreichung (`usb-host` 19b9:3443); im Plan als „verworfen/Rückfallweg, Freigabe unbelegt, macOS hält das Gerät“ vermerkt (*B*, Plan). Durchreichung nimmt der Mac das Volume weg (V).
- **(c) SCSITaskUserClient am belegten Gerät** — *V*: Der Knoten trägt `SCSITaskUserClientIniter` (B), SCSI-Task-Interfaces verlangen `ObtainExclusiveAccess` und scheitern, solange `IOSCSIPeripheralDeviceType00`/Block-Storage das Gerät hält (R/Gedächtnis, nicht gemessen, kein Versuch). Vorschlag zur Prüfung ohne Drobo: gleicher Code gegen einen USB-Stick, `INQUIRY`, mit Mount und ohne. Das Dashboard selbst nutzt diesen Weg **nicht** (B, kein Plugin-Import).

## Offen / nicht geprüft
Kein Lauf gegen die Drobo, keine Byte-Dumps der Antworten, Offsets nur für SlotInfo2/Capacity/Config aus Disassembly. Lüfter/Temperaturgehäuse (0x34-0x3A) und Status-Bitmasken noch nicht ausgewertet. Bytes `EA 10` Flag-Bedeutung (Cancel/FSEQ) nach Variablennamen im Kext, nicht erprobt.

## Ghidra-Nachtrag (2026-10-14T08:20:00+0200)
Alles weiter nur gelesen (kein Gerätezugriff, DDService64d und Kext nicht geladen). Fundstellen: `Klasse::Methode @ Adresse` im Ghidra-Dekompilat von DDService64d (Image-Basis 0x100000000, x86_64).

**Werkzeug (B):** Ghidra 12.1.4 + JDK 21. Das Release enthält keinen Mac-Decompiler (`os/mac_arm_64/decompile` fehlte → Dekompilierung schlug im ersten Lauf fehl). Gebaut aus den mitgelieferten C++-Quellen (`make ARCH_TYPE="-arch arm64" ghidra_opt`), abgelegt unter `Ghidra/Features/Decompiler/os/mac_arm_64/decompile`. Projekt `<lokaler Arbeitsordner>` (Programm `DDService64d`, analysiert), Export aller 12 489 Funktionen als C nach `ghidra_work/out/all.c` per Skript `scripts/DumpFns.java`. Symbole sind Mach-O-gemangelt, daher Suche mit `ZN11ESAProtocol…`. REA: Provider-Bindung verlangt genau diesen arm64-Decompiler (`rea decompile … --provider ghidra` → vorher `executable_missing`); Nach dem arm64-Bau kippt der Fehler von `provider_unavailable` auf `cancelled` (eigener 100-s-Timeout): die Bindung steht, die REA-eigene Voll-Analyse (`--snapshot ghidra_work/rea_snapshot`) lief bei Abgabe noch und ist **nicht** Grundlage dieses Nachtrags; alle Befunde stammen aus `analyzeHeadless` + `DumpFns.java`.

### Korrekturen am Text oben
- Op 0x0E (Restart-Variante) **gestrichen**: war ein bool-Parameter in der Registerverfolgung, kein Opcode (`ESABlockDevice::restartESA(bool)` ruft `execCmd(3,1,0,0)`).
- Status-Seite 0x09: Feldfolge ist anders als oben angedeutet, siehe unten.
- Capacity-Seite hat feste Größe 0x24, nicht „min 0x1b“ (`calculateModePageSize`).
- Einheiten: bleiben V, soweit nicht ausdrücklich „B“.

### 1. Seitenlayouts (B; Offsets ab Seitenanfang, Byte 0 = 0x7A, Byte 1 = Subseite; Mehrbyte-Felder big-endian)
Antwort beginnt unmittelbar mit 0x7A (kein 8-Byte-Mode-Parameter-Header; drobo-utils entpackt `>BBH` direkt, Dashboard prüft `p[0]=='z'`). Bytes 2-3 = Längenfeld; der Dienst vertraut ihm nicht (SlotInfo2 überschreibt es, `ESASlotInfo2::parse`). „Max“ = `getMaximumModePageSize`, „Soll“ = `calculateModePageSize`.

| Sub | Klasse (Parse @) | Soll/Max | Felder |
|---|---|---|---|
| 0x01 | `ESAConfigurationInfo::parse` @0x10009bc4c | 0x1C | +4 u8 Slots · +6 u8 max. LUNs · +7 u64 max. LUN-Größe (drobo-utils ×512 → Blöcke) · +0x10 u32 DemoMode · +0x14 u32 ScaleFactor · +0x18 u32 readonlyMode |
| 0x02 | `ESACapacityInfo::parse` @0x10009c8e6 · `…PT` | 0x24 · PT 0x48 | +4 frei · +0xC benutzt · +0x14 gesamt (geschützt) · +0x1C gesamt (ungeschützt), je u64. PT (Transactional Tier) zusätzlich +0x24 frei · +0x2C benutzt · +0x34 gesamt. Einheit Bytes (V; drobo-utils-Beispielwert 495452160000) |
| 0x05 | `ESASystemSettings` | 0x2A | Zeit (u32), GMT-Offset, Name (char[32]) (drobo-utils `LH32s`) |
| 0x06 | `ESAProtocolVersion::parse` @0x10009b76c | 6 | +4 u8 Major · +5 u8 Minor |
| 0x08 | `ESAFirmwareInfo::parse` @0x10009f1a0 | 0x13A | +4 u8 · +5 u8 · +6 u16 Build · +8 u8 · +9 u8 · +0xA char[32] Version · +0x2A char[16] (nur wenn Länge ≥ 0x2B) · weitere Strings laut drobo-utils (+0x3A char[16], +0x4A char[240]) |
| 0x09 | `ESAStatusInfo::parse` @0x10009be82 | 0x10 / 0x14 / 0x18 je Firmware-Merkmal | +4 u32 **Status-Bits** · +8 u32 **relayoutCnt** · +0xC u32 **diskPackStatus** · +0x10 u32 **doubleDegradedCnt** (ab Länge 0x11 und Merkmalsbit) · +0x14 u32 (unbenannt) |
| 0x30 | `ESAOptions::parse` | 0xD | +4 u8 Gelb-Schwelle (ganz) · +5 u8 Rot-Schwelle (ganz) · +6 Flags (Bit 4-5, ≥0x40; unterstes Nibble getrennt) · +7 u32 Background-Data-Check · +0xB u8 Gelb Nachkomma · +0xC u8 Rot Nachkomma (`print`: „%u.%u%%“) |
| 0x31 | `ESAOptions2::parse` | 0x200 | +4 u64 FeatureOnOffStates · +0xC u16 · +0xE/+0x12 u32 IP-Adressen (NAS), weitere Netzfelder; für die 5C unerheblich |
| 0x33 | `ESASystemInfo::parse` | 0x18 (Max 0x14) | +8 u32 **UpTime** · +0xC u32 **Temperatur** (XML-Tags in `ESADevice::GetSysInfo` @0x10007b5fc) · +0x10 u32 vom Dienst nicht ausgegeben |
| 0x34 | `ESASystemPerformance::parse` | 0x20 (Max 0x1C) | +8 u32 **Iops** · +0xC u32 **ReadThroughput** · +0x10 u32 **WriteThroughput** · +0x14 u32 (ungenutzt) · +0x18 u32 **TierIOps** (nur wenn BE-u16 an +6 > 1). UI-Einheit „MB/s“ (`kUIString_IOUnit`), ob Rohwert MB/s: V |
| 0x35 | `ESASlotInfo2::parse` / `ESASlotInfoStruct2::parse` @0x10009d534 | 0xC + n·0x6C (Max 0x51C = 1308, deckt Kext-Puffer) | Kopf: +8 u8 Slotanzahl · +9 u8 (Satzgröße) · Sätze ab +0xC, je 0x6C: +0 Slot-Id · +1 Slot-Status · +2 u16 Fehlerzähler · +4 u32 Disk-Zustand · +8 u8 Typ (bekannte Werte 0, 2, 4) · +9 u8 Temperatur · +A u8 Restlebensdauer (SSD) · +B u8 Drehzahl · +C char[44] · +0x38 char[12] · +0x44 char[24] · +0x5C u64 Kapazität · +0x64 u64 verwaltete Kapazität. Zuordnung der drei Strings (Hersteller+Modell / Firmware / Seriennummer) nach `print()`-Reihenfolge, Zeichenkettenaufteilung in `constructHSSlot2Update` @0x1000a55f0: V. Typnamen aus UI: SATA_SSD, SAS_SSD (`strings_en.xml`) |
| 0x36 | `ESAPowerSupply::parse` @0x10009c27a | 0x2D | +9 u16 · +0xB u16 (Health 0/1, Zuordnung V) · +0xD char[16] Serial0 · +0x1D char[16] Serial1; XML `PowerInfo`: Serial*, Health* |
| 0x37 | `ESAFanInfo::parse` @0x10009c394 | 0x2E | +8 char[16] **Serial** · +0x18 u16 **Health** · +0x1A 4× u32 **RPMLevel0-3** · +0x2A 4× u8 **RPMHealth0-3** (`ESADevice::GetFanInfo` @0x10007baee). RPM-Einheit V |
| 0x38 | `ESAControllerCard::parse` | 0x55 | +8 u8 Anzahl (≤2) · +9 2×char[16] **Serial** · +0x29 2×char[16] **BattSerial** · +0x49 2×u16 **Health** · +0x4D 4×u16 **PortSpeed** |
| 0x39 | `ESAExpanderInfo::parse` | 0x2D | +8 u8 Anzahl (≤2) · +9 n×char[16] **Serial** · +0x29 n×u16 **Health** |
| 0x3A | `ESABatteryInfo::parse` | 0x2D | gleiche Gestalt wie 0x39 (Serial, Health je Batterie) |
| 0x82 | `ESAGetKernelInterfaceInfo::parse` | 0x14B | memcpy der ganzen Seite, BE-u16 an +5, +7, +9, Liste ab +0xD; Zweck V (Schnittstellen-Info), für Status nicht nötig |
Lüfter-/Strom-/Batterie-„Health“-Wertebereiche (was grün, was rot ist) stehen nicht in den Parsern: **offen**. Ein Rebuild-**Prozentwert** existiert in Seite 0x09 nicht (nur `relayoutCnt` und Bit 0x200); das Dashboard-Log nennt „Relayout in progress/is done“ (`getStatusInfo`, `doPollESAUpdate`).

### 2. Status-Bits (B für Immediate-Werte; 32 Bit aus Seite 0x09, Bits ≥ 2³² errechnet der Dienst selbst)
Aus `ESAAlertHistory::getMessageForStatusBitAndLanguage` (Konstante → `kStatusString_*`) und drobo-utils `_unitstatus`: 0x2 Rot-Schwelle · 0x4 Gelb-Schwelle · 0x8 keine Platten · 0x10 defekte Platte · 0x20 zu viele fehlende Platten · 0x40 keine Redundanz · 0x80 (drobo-utils: kein Magic-Hotspare) · 0x100 (drobo-utils: kein Platz) · 0x200 **Relayout läuft** · 0x400 (drobo-utils: Format läuft) · 0x800 gemischte Platten · 0x1000 unbekannte Version · 0x2000 neue Firmware installiert (drobo-utils) · 0x4000 neue LUN nach Neustart (drobo-utils) · 0x40000 inkompatibles Disk-Pack · 0x10000000 unbekannter Zustand. Schweregrad im Dienst: **kritisch** `status & 0x14C4187A`, **Warnung** `status & 0x36002300244`, sonst Info (`getSeverityForStatus` @0x100038b92). `diskPackStatus` (+0xC) erzeugt zusätzlich Bits (`ESASCSISession::getStatusInfo` @0x1000a7c22): 2→0x1000, 3→0x10000000, 4→0x800, 5/6/7→0x20, 8→0x40000. Slot-LED-Code (drobo-utils, altes Format, für SlotInfo2 V): 0 aus, 1 rot, 2 gelb, 3 grün, 4 rot/grün blinkend, 5 rot/gelb, 6 rot/aus, 0x80 leer; der Dienst prüft `(Status & 0x8F) == 0x86` für „defekt“.

### 3. `EA 10`-Systemoperationen, per Dekompilat bestätigt (B)
CDB (10 B), Konstruktor `ESASystemOperationRequest` @0x1000c56e4: `EA 10 | [Richtung: 0x80 = Daten ein] | Op | Arg | 00 | [Bit6 Cancel, Bit5 FSEQ] | Len_hi Len_lo | Ctl`. Aufrufstellen (Argumentlisten aus Dekompilat):

| Op | Aufrufer | Wirkung |
|---|---|---|
| 0x02 | `formatESA` | **Format** |
| 0x03 | `restartESA`, `ESABlockDevice::restartESA` | Neustart |
| 0x05 | `crashESA` | **absichtlicher Absturz** |
| 0x06 | `identifyESA(…)` (mit Arg 4) | Identify/Blinken |
| 0x08 | `setCapacityLEDs` (Len 2) | LED-Kapazitätsanzeige |
| 0x09 | `setFlashConfig`, `setDemoMode` (Len 4) | Flash-/Demo-Konfiguration |
| 0x0A | `runEsaCommand` | beliebiger ESA-Befehl (Ein/Aus) |
| 0x0B | `setUsedCapacity` (Len 0x10) | Used-Capacity setzen |
| 0x0D | `ESABlockDevice::standBy/standDownESA`, `ESAMPDevice::shutdownESA` (`execCmd(0xd,1,0,0)`) | **Standby** |
| 0x0F | `resizeLUNS` (Len 4) | LUN-Größe |
| 0x10 | `partitionFormatESA` (Len 0x220) | **Partition formatieren** (neu gefunden) |
| 0x15 / 0x16 | `readHostBuffer` / `writeHostBuffer` | Host-Puffer lesen / schreiben |
| 0x17 | `powerOffESA`, `ESAMPDevice::shutdownESA` | **Ausschalten** |
| 0x18 / 0x21 | `setDimLevel` / `getDimLevel` | Helligkeit |
| 0x20 | `getNextUniqueLUNID` | lesend |
| 0x22 / 0x23 | `getUserEventLog` / `postUserEvent` | Ereignislog lesen / schreiben |
| 0x70 | `Firmware::getHeader/getBlock` | **Firmware schreiben** |
| 0x71 | `downloadSystemOperation` (lesend) | Firmware-Status/Download |
| 0x80 | `revertFirmware` | **Firmware zurückrollen** |
| 0x81 / 0x83 / 0x84 | `getLUNsInfoEx` / `…Ex2` / `getLunInitiatorExtraInfo` (lesend) | LUN-Infos |
| var. | `uploadDiagnostics`, `getDiagnosticsCatalog` (Op 4) | Diagnose lesen (drobo-utils: Codes 4 und 7) |
Alle 0xEA-Familien-Befehle bleiben im Statuswerkzeug gesperrt, auch die lesenden (Nebenwirkungen unbekannt, Richtungs-Bit im Werkzeug nicht prüfbar).

**Subseiten 0xE1/0xE2 bestätigt:** `ESASCSISession::insertRemoveDrive` @0x1000a92fa baut `5A 08 3A <E1|E2> <Slot> 00 00 00 08 00` (`E1`, wenn `insert` wahr, sonst `E2`) und sendet es per `sendCDB`: ein **MODE SENSE mit Zustandsänderung**. Der Dienst-Filter (`IOCSCSISession::execute`) lässt MODE SENSE ohne Subseitenprüfung durch.

### 4. ProtocolVersion, Seite 0x06 (B)
Anfrage (`detectESAProtocolVersion` @0x1000a2c54, `ModeSenseSCSIRequest(LLBAA=0, DBD=1, PC=0, Page=0x3A, Sub=6, Alloc=6)`): `5A 08 3A 06 00 00 00 00 06 00`, Datenrichtung ein. Antwort (6 Byte, `ESAProtocolVersion::parse` @0x10009b76c verlangt ≥ 6 und `p[0]==0x7A`, `p[1]==0x06`): `7A 06 <Len_hi> <Len_lo> <Major> <Minor>`. Längenfeld-Wert nicht belegt (V: 0x0002). Fehlschlag: `*(u16*)(session+0x82)=0`. Die Version steuert (über Firmware-Merkmale) die Größe von Seite 0x09 und die Satzgrößen.

### 5. Exakte Allowlist für ein Nur-Lesen-Statuswerkzeug (Vorschlag aus B-Befunden)
Nur zwei Opcodes, nur Datenrichtung „Gerät → Host“, nie Daten-out:
1. **INQUIRY** (6 B): `12 00 00 00 24 00` (Standard, belegt: drobo-utils `DroboIOctl.identifyLUN`) · `12 01 80 00 1C 00` (VPD Seriennummer, Alloc 0x1C, `VPDInquirySCSIRequest` @0x1000c5224, `getVPDInquiryPage`).
2. **MODE SENSE(10)** (10 B), exakt `5A 08 3A SS 00 00 00 LH LL 00`: Byte1 = 0x08 (DBD=1, wie Dashboard; 0x00 wie drobo-utils/Kext wäre ebenfalls belegt) · Byte2 = 0x3A (PC=0 „aktuell“) · Byte3 SS ∈ Whitelist · Bytes 4-6 = 0 · Bytes 7-8 = Alloc-Länge BE ≤ Max der Subseite · Byte9 = 0.

| SS | Seite | Alloc (Max) | Status |
|---|---|---|---|
| 06 | ProtocolVersion | 0x0006 | immer zuerst |
| 01 | Config | 0x001C | drobo-utils-bewährt |
| 02 | Capacity | 0x0024 (PT-Firmware: 0x0048) | drobo-utils-bewährt |
| 05 | SystemSettings | 0x002A | drobo-utils-bewährt (Lesen) |
| 08 | Firmware-Info | 0x013A | drobo-utils-bewährt |
| 09 | Status | 0x0018 | drobo-utils-bewährt (`LL`) |
| 35 | SlotInfo2 | 0x0C + Slots·0x6C (5C: 0x0228; Max 0x051C) | nur Dashboard |
| 03 | SlotInfo (alt) | 0x0360 | drobo-utils-bewährt |
| 04 / 07 | LUNInfo / LUNInfo2 | 0x009D / Anz·0x13+5 | drobo-utils-bewährt |
| 30 / 31 | Options / Options2 | 0x000D / 0x0200 | drobo-utils-bewährt |
| 33 / 34 | SysInfo / Performance | 0x0018 / 0x0020 | nur Dashboard |
| 36 / 37 / 38 / 39 / 3A | Power / Fan / Controller / Expander / Battery | 0x2D / 0x2E / 0x55 / 0x2D / 0x2D | nur Dashboard |

„nur Dashboard“-Seiten: erst gegen die echte 5C mit Einzelanfrage und Sense-Auswertung eichen (V: ob die 5C-Firmware sie kennt). Alles andere abweisen, insbesondere SS = E1, E2, 80, 82 und jede Subseite ≥ 0xA0, Opcodes 0x55, 0xEA, 0x2A, 0x28, 0x08/0x0A, 0x04, 0x1B, 0x35, 0x3B, 0x42, 0x2F, 0xA0-0xBF. Zusätzlich zur Opcode-Prüfung Sense-Key auswerten und bei Fehler **nicht wiederholen** (ioreg der 5C zeigt am Protokollknoten Read/Write-Timeout 30 s und Retry Count 20). Antworten nur gegen `p[0]==0x7A && p[1]==SS` und `Len ≥ Soll` akzeptieren, wie die Parser.

### 6. Noch offen
Wertebereiche von Health-/Status-Bytes der Hardwareseiten (Lüfter, Strom, Batterie, Controller), Einheiten von UpTime, Temperatur, RPM, Throughput, Typ-Codes des Slot-Typs außer 0/2/4, 5C-Firmware-Unterstützung für Dashboard-Seiten 0x33-0x3A, Längenfeld in Bytes 2-3. Kein Lauf gegen die Drobo.
