# LUN-Verwaltung DroboPro + Time Machine auf DroboDraft-Volumes

Stand: 2026-10-17T18:12:35+0200 · nur statische Analyse, kein Gerätekontakt.
Quellen: Ghidra-Dekompilat von DDService64d (Dashboard 3.6.1, Image-Basis 0x100000000) — `all.c` im Werkzeugordner außerhalb des Repos; `man tmutil` (macOS 26); `tmutil destinationinfo` (nur gelesen: keine Ziele eingerichtet).
Kennzeichnung: **B** = belegt (Adresse/Zitat), **V** = Vermutung.

## 1. LUN-Verwaltung

### 1.1 CDB-Aufbau des Dashboards (B) — berichtigt die bisherige Annahme
`ESASystemOperationRequest` @0x1000c56e4 / `ESASystemOperationCDB` @0x1000c57d6:

| Byte | Inhalt |
|---|---|
| 0–1 | `EA 10` |
| 2 | `(REQUEST_TYPE == 0) << 7` → 0x80 nur bei Typ 0 (Daten **ein**), sonst 0x00 |
| 3 | Op |
| 4 | Arg — bei `sendSystemOperation` = **Transaktionszähler** (`session+0x70`, je Aufruf +1) |
| 5 | immer 0 |
| 6 | `FSEQ<<5 \| Cancel<<6 \| Bit0` — Dashboard ruft immer mit (Cancel 0, FSEQ 1, 1) → **0x21** |
| 7–8 | Länge BE16 |
| 9 | Ctl — Dashboard übergibt **0** |

`(session+0x90)<<6` geht NICHT in Byte 9, sondern als 11. Argument in Feld `request+0x40` (B); Bedeutung V (LUN/Ziel-Auswahl oder Zeitlimit). Plan-Notiz „Ctl=(session+0x90)<<6“ damit falsch.

Alle Schreib-Sysops (`sendSystemOperation(Eh)` @0x1000a33cc, `(EhtPh)` @0x1000a350e) nutzen REQUEST_TYPE 1 = Daten **aus** → Byte 2 = 0x00. Die BERICHTIGUNG im Plan („Dashboard setzt 0x80“) stimmt nur für lesende Ops (Typ 0, z. B. `getNextUniqueLUNID` @0x1000a901a).
Ohne Nutzlast schickt das Dashboard trotzdem 1 Byte Daten-aus (`Buffer(1)`, Len 1).

### 1.2 Vergleich mit dem gemessenen Befehl (2026-10-17)
Gesendet: `EA 10 00 Op 00 txn 20 00 01 Ctl`. Dashboard: `EA 10 00 Op txn 00 21 00 01 00` + 1 Byte Daten-aus.
Unterschiede: txn in Byte 5 statt 4 (Byte 4 = 0) · Byte 6 Bit0 fehlt · Ctl ≠ 0 bei drei Varianten · ob das 1-Byte-Datenpaket (Data-Out/Immediate) tatsächlich gesendet wurde, steht im Messprotokoll nicht.
Folgerung (V): Neustart nach Op 0x06 ist durch das Format nicht erklärt; Op 0x06 ruft das Dashboard zudem mit Len 4 (`identifyESA(Ej)` @0x1000a7f52), nicht Len 1. Der Fehlerweg „unbekannte Nutzlast → Firmware-Ausnahme → Neustart“ ist plausibel, nicht belegt. Sperre aller EA bleibt.

### 1.3 Op-Tabelle LUN/Volume

| Op | Bedeutung | Nutzlast (Daten aus) | Beleg |
|---|---|---|---|
| 0x0F | LUN-Größe ändern (alle LUNs, neue Teilung) | 4 B: neue LUN-Größe in **TB** (aus `ResizePartitionFormat` param_2, verglichen mit ConfigInfo max. LUN-Größe >>21 gerundet; Bytefolge V: BE) | `resizeLUNS` @0x1000a7f78 → `sendSystemOperation(0xf,4)`; `ResizePartitionFormat` @0x10006b7a2: „RESIZING LUN SIZE. EXPECT DROBO RESTART“ |
| 0x12 | LUN anlegen | 12 B: u64 BE Größe (`htonll(Params.Size)`, Einheit V: Blöcke/Bytes) · u8 Flags · u8 0 · u16 BE LUN-ID | `ESABlockDevice::CreateLUN` @0x10006654e, CDB `(1,0x12,0,0,1,1,0xc)` |
| 0x13 | LUN löschen | 4 B: u16 BE UniqueLUNID · u8 (aus LUN+0x68) · u8 0 | `DeleteUniqueLUN` @0x100064008, CDB `(1,0x13,0,0,1,1,4)`; vorher Abhängen + `iSCSILogout` (bis 5 Versuche) |
| 0x20 | nächste freie LUN-ID (lesend) | Antwort 2 B BE | `getNextUniqueLUNID` @0x1000a901a |
| 0x10 | Partition formatieren (gerätintern, nur FAT32-Weg) | 0x220 B `ESAPartitionFormatInfo` | `partitionFormatESA` @0x1000a7eda; „Send fat32 format command“ in `DoPartitionFormatLUN` |
| 0x02 | ganzes Gerät formatieren (alle Daten weg) | 1 B | `formatESA` @0x1000a7e7c |
| MODE SELECT 0x3A/0x0D | LUN-Name | Seite | `setLUNName` @0x1000a909c |

Anmerkungen (B): CreateLUN/DeleteLUN laufen über `ESABlockDevice::sendCDB` direkt, nicht über den Transaktionszähler — Byte 4 = 0. HFS+/NTFS formatiert das Dashboard host-seitig (`newfs_hfs`/`diskutil`, Recon-Bericht), Op 0x10 nur für FAT32. Ablauf „Volume-Größe ändern“: alle LUNs abhängen → Op 0x0F → Drobo startet neu → Dashboard wartet `hasESAFoundAllResizeLUNs` → host-seitig formatieren. **Größenänderung = Datenverlust aller LUNs + Neustart, by design.**
Transport (B): DroboPro = `DAiSCSIManager` (`iSCSIAddAndLogin`, `PingAddress`); dieselben CDBs über die iSCSI-Sitzung, kein eigener Steuerkanal gefunden. Port 3261 im Dekompilat nicht referenziert (früherer Befund).

### 1.4 Sicheres Messverfahren (Vorschlag, nichts davon ausgeführt)
1. **Nachbau ohne Gerät eichen:** CDB-Bauer in drobo_kern exakt nach 1.1 (Byte 4 txn, Byte 6 0x21, Ctl 0, Len + Daten-aus), Test gegen `drobo_kern/Tests/iscsi_ziel.py`: Ziel protokolliert CDB + Data-Out-Länge; harter Vergleich gegen Tabelle 1.1. Rot zuerst mit dem alten Format.
2. **Referenzmitschnitt Dashboard** (Betreiberentscheidung, Gerätekontakt): DroboPro ist Testgerät. Betreiber tippt `sudo tcpdump -i en0 -s0 -w ~/dropro_dash.pcap port 3260` und ändert im Dashboard die Volume-Größe (Datenverlust akzeptiert). Voraussetzung V: DDService64d-LaunchDaemon geladen und Dashboard findet DroboPro über eigenen iSCSI-Login (laut Recon bisher nicht geladen). Auswertung: Wireshark-Filter `iscsi.scsicommand.opcode == 0xea` → Byte-genaue CDB + Data-Out. Entscheidet Format und Nutzlast von 0x0F/0x12/0x13.
3. Erst danach eigener Einzelbefehl, und nur mit dem Byte-identischen Mitschnitt; harmloseste Op zuerst ist **keine** EA (alle haben Nebenwirkung) — Kandidat 0x20 (lesend, Typ 0).

## 2. Time Machine auf DroboDraft-Volumes

Regeln (B, `man tmutil`): Ziel ist „a local HFS+ or APFS volume, AFP share, or SMB share“; Netzwerkziel = Sparsebundle auf der Freigabe. Apple-Support (V aus Doku, nicht lokal geprüft): neue Sicherungen seit macOS 11 auf APFS; HFS+ nur noch für bestehende.

| Option | Urteil | Beleg / Grund | Entscheidende Messung | Stille Fehlerklassen |
|---|---|---|---|---|
| a) FSKit-Volume als lokal melden | geht nicht (V, stark) | hfsdrobo ist kein APFS, ohne Journal, kein MNT_LOCAL; TM verlangt APFS/HFS+(J) lokal | `tmutil setdestination /Volumes/<Name>` (Betreiber, danach `removedestination`) → Fehlermeldung | keine — schlägt laut ab |
| b) Sparsebundle/APFS-Abbild auf dem Volume, eingehängt, als Ziel | technisch möglich (V) | eingehängtes Abbild = lokales APFS; `setdestination` akzeptiert Einhängepunkt | `hdiutil create -type SPARSEBUNDLE -fs APFS` auf Volume + `setdestination` des Abbilds | Abbild hängt nach Neustart nicht automatisch ein → TM meldet nur „Ziel nicht verfügbar“; F_FULLFSYNC/Schreibordnung über FSKit+iSCSI ohne Journal → beschädigte Bänder nach Abbruch, erst bei Wiederherstellung sichtbar |
| c) SMB-Freigabe eines DroboDraft-Ordners (macOS-Dateifreigabe, „als Time-Machine-Ziel“) | offen (V) | offiziell unterstützter Weg; fraglich, ob smbd FSKit-Volumes freigibt und ob TM ein Ziel auf demselben Mac annimmt | Systemeinstellungen-Freigabe auf FSKit-Ordner + `tmutil setdestination smb://…` | Netzweg auf localhost; Sperrsemantik FSKit vs. Sparsebundle |
| d) iSCSI-Initiator als Blockgerät (DriverKit `IOUserSCSIParallelInterfaceController` o. ä.) → LUN als echter Datenträger, APFS | geht (V, beste Lösung) | macOS bindet Blockgerät an `IOSCSIPeripheralDeviceType00` wie bei der 5C (Recon) → APFS + TM nativ | Dext-Prototyp: LUN erscheint in `diskutil list` | LUN muss APFS neu formatiert werden (unumkehrbar für LUN-Inhalt); Dext-Freigabe/Entitlement nötig; Verbindungsabbruch = Gerät weg |

Lokaler Test ohne Drobo: nicht durchgeführt. Grund: jeder aussagekräftige Test braucht `tmutil setdestination` (Betreiberregel: nicht setzen) bzw. sudo. Gelesen: `tmutil destinationinfo` → „No destinations configured“.
Empfehlung: d) als Ziel, b) als Übergang nur mit Warnung „kein Journal“. Nächster Schritt ohne Betreiber: CDB-Bauer nach 1.1 + Ziel-Test (1.4 Schritt 1).
