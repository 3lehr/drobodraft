# Plan: DroboPro (8 Schächte, iSCSI) in DroboDraft — 2026-10-16T21:13:32+0200

Betreiber: „können wir das nicht alles in unser drobo dashboard implementieren um die drobo lauffähig auf den mac zu machen?“ — „erstmal ohne timemaschine dann mit! auf der 8bay drobo liegt nichts wichtiges“ (Testgerät, darf neu eingerichtet werden).

## Ist-Stand (gemessen 2026-10-16, nur lesend)

- Im LAN unter DHCP-Adresse, MAC-Präfix 00:1A:62 (Data Robotics). Offen nur TCP 3260 (iSCSI); kein SMB/AFP/HTTP, kein Dashboard-Port 5000/5001. Darum im Finder unsichtbar.
- Discovery (SendTargets, ohne LUN-Anmeldung): ein Ziel `iqn.2005-06.com.datarobotics:drobopro.<seriennr>.node0`, Portalgruppe 0.
- Anmeldung `AuthMethod=None` angenommen; Sicherheitsphase braucht zwei Runden (Antwort T=0 auf erste Anfrage). Ziel bietet `MaxBurstLength=524288`, `FirstBurstLength=524288`, `InitialR2T=Yes`, `ImmediateData=Yes`, `MaxOutstandingR2T=8`, `ErrorRecoveryLevel=0`.
- INQUIRY `DROBO DroboPro 1.00`; REPORT LUNS: LUN 0 und LUN 1. LUN 0: 34 359 738 368 Blöcke × 512 B = 16 TiB virtuell, GPT.
- Drobo-Statusseiten 5A/3A über iSCSI (Allokationslänge 512; 4096 → keine Antwort, Sitzung hängt): 01 Slots=8 maxLUNs=16 · 02 geschützt ~17,9 TB, belegt ~0,99 TB (einmal beantwortet, einmal nicht) · 06 Protokoll 0.11 · 08 Firmware-Build 22137 (Jan 6 2017) · 09 StatusBits=0x00028000, kein Relayout. 33 und 35 ohne Antwort.
- Modul: Gerätezugriff schon heute über Rückrufe (`lifs_dev_register`: pread/pwrite/ioctl) in `Backend.swift`, einzige Schreibstelle `lifs_dev_pwrite` mit 524288-B-Kappe. Dort ist die Quelle `FSBlockDeviceResource`.
- macOS 26 SDK: `FSGenericURLResource` (FSKit V2) mit `FSSupportedSchemes` im Info.plist — ein Modul darf eine beliebige URL einhängen und den Transport selbst sprechen.

## Alternativen

| Weg | Bewertung |
|---|---|
| **A: iSCSI-Client im FSKit-Modul** (`FSGenericURLResource`, Schema `iscsi`) | **gewählt.** Kein Fremdtreiber, kein zweiter Rechner, gleiche Schutzschichten wie bei der 5C (512-KiB-Kappe, Sicherung, Platzsperre). Scheitert sichtbar binnen einer Messung (Schritt 2), falls FSKit die URL-Ressource nicht lädt. |
| B: Linux-Rechner als iSCSI-Client + Samba | verworfen für Dateien: zweites Gerät im Dauerbetrieb, Mac sieht nur SMB (kein Dashboard). Bleibt Rückfallweg für Time Machine, falls TM ein FSKit-Volume ablehnt. |
| C: iSCSI-Client eines Drittherstellers auf dem Mac | verworfen: Lauffähigkeit unter macOS 26/Apple Silicon ungeprüft, kostenpflichtig, Schreibgröße nicht kappbar. |
| D: USB 2.0 / FireWire 800 an den Mac | verworfen: nicht LAN (Betreiberwunsch), USB-2-Tempo. |

## Reihenfolge (bindend, wo begründet)

1. **iSCSI-Client im Kern** (`drobo_kern`, Swift, nur Network.framework/POSIX): Discovery, Login (mehrrundig), SCSI READ(16)/WRITE(16)/READ CAPACITY(16)/INQUIRY/REPORT LUNS/MODE SENSE(10)/TEST UNIT READY, Logout; Data-In, R2T/Data-Out, Status; Zeitüberschreitung → Fehler statt Hängen. Schreibbefehle ≤ 524288 B (deckt sich mit MaxBurstLength). Befehls-Allowlist wie beim Dext (keine EA-10/MODE SELECT/E1/E2).
   **Prüfstand:** kleines iSCSI-Ziel in Python über eine Abbilddatei (lokal, Fehlerinjektion: Verbindungsabbruch, R2T in Stücken, Zeitüberschreitung). Kern-Tests gegen dieses Ziel; Gegenprobe gegen die echte DroboPro LUN 1. *Vor* dem Modul, weil jeder Modulfehler sonst nicht vom Transportfehler zu trennen ist.
2. **Machbarkeitsmessung FSKit-URL** (kleinster Fall): Modul meldet Schema `iscsi`, `mount -F -t hfsdrobo iscsi://…` lädt, Probe meldet erkannt. Scheitert das, ist Weg A tot → Rückfrage an den Betreiber (B).
3. **Modul-Quelle iSCSI:** `Backend.swift` bekommt die Gerätequelle als kleines Protokoll (Lesen/Schreiben/Größe/Blockgröße); zweite Umsetzung über den Kern-Client. GPT der LUN lesen, HFS-Partition finden (die 5C bekommt die Partition fertig von macOS, iSCSI liefert die ganze LUN). Eich-/Härteläufe zusätzlich gegen das Python-Ziel.
4. **DroboPro einrichten:** LUN mit GPT + HFS+ neu anlegen (Testgerät), lesend/schreibend über das Modul, Eichung auf echter Hardware.
5. **App:** DroboPro als Drobo-Art „Netzwerk“ (Adresse statt Volume-UUID), Statusseiten über iSCSI im Dashboard, Platzsperre aus Seite 02.
6. **Time Machine** (zweite Stufe, Betreiber): erst messen, ob TM ein FSKit-Volume als Ziel annimmt; sonst Weg B.

## Bewusst nicht

- Kein CHAP (Ziel verlangt keins; Heimnetz). Preis: jeder im LAN kann die LUN einhängen — wie heute schon.
- Keine Mehrfachverbindungen/MC/S, kein Fehlerwiederherstellungsgrad > 0: Verbindungsabbruch = Volume nicht mehr erreichbar, Sicherung + Nachprüfung wie beim Abziehen der 5C.
- Keine Digests (CRC32C): TCP-Prüfsumme reicht im LAN. Preis: stille Bitfehler außerhalb von TCP nicht erkannt.
- Keine Seriennummer/MAC/IP im öffentlichen Repo (Prüfstand-Abbilder und Doku anonym).

## Erfolg

- Kern: alle Tests gegen das Python-Ziel grün, Rotprobe je Fehlerinjektion; echte LUN 1: INQUIRY/Kapazität/Lesen identisch zur Python-Sonde.
- Modul: Eichung `alles` gegen das Python-Ziel ohne FAIL; an der DroboPro Lesen/Schreiben mit `max_cmd ≤ 524288`, Prüfsummen nach Aus-/Einhängen gleich.
- App: DroboPro erscheint im Finder unter Orte, Dashboard zeigt Schächte/Füllstand.
