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

## Fortschritt

- **Schritt 1 erledigt** (Commits 6d2c76d…e2ab9d2): iSCSI-Client im Kern, 9 Tests gegen Python-Ziel grün, 7 Rotproben; Gegenprobe an der DroboPro (INQUIRY, Kapazität, LUN 0/1, Seiten 01/02/06/09) gleich der Python-Sonde. Nicht geschrieben: LUN 0 und 1 tragen beide GPT.
- **Schritt 2 belegt (2026-10-16T21:51:41+0200):** zweites Modul `hfsdropro` (nur `FSSupportsGenericURLResources`, Schema `iscsi`, Commit 47eb503). `mount -F -t hfsdropro iscsi://probe.invalid/lun0 …` → Modul-Log `URL-LOAD scheme=iscsi host=1` (loadResource erreicht; URL-PROBE nicht aufgerufen). Gemessen davor: Block+URL in EINEM Modul → `mount -F` findet das Modul weder für URL noch für Abbilder („No extension with fsShortName“), bei eingeschaltetem Modul; eine Änderung der Quellenarten setzte die FSKit-Freischaltung zurück (Exit 3). Darum getrennte Module; das 5C-Modul bleibt unverändert.
- **Neueinrichtung der DroboPro** (Betreiber: „nichts wichtiges“): HFS+ für eine LUN ohne lokales Blockgerät — newfs_hfs auf eine lokale Sparse-Datei gleicher Größe, dann nur Volume-Header, Ersatz-Header und die laut Bitmap belegten Blöcke per iSCSI schreiben; GPT mit einer HFS+-Partition davor.
- **Schritte 3 (Quelle) und Neueinrichtungswerkzeug erledigt (2026-10-16T22:05:00+0200):** `Geraet`-Protokoll in `fskit_probe/Module/Geraet.swift`; `hfsdropro` öffnet `iscsi://HOST[:PORT]/<IQN>/<LUN>`, liest die GPT, nimmt die erste HFS+-Partition. `drobo iscsi-format --lun 1 --name N [--partition-gib G] [--execute]` (nur LUN 1). Eichung `fskit_probe/tools/eich_iscsi.sh` gegen das Python-Ziel: 19 PASS / 0 FAIL, max WRITE am Ziel 524288 B, `fsck_hfs -fn` auf der Partition OK.
- **Offen:** Freigabeliste im Container des iSCSI-Moduls (Shell gesperrt, TCC), SYNCHRONIZE CACHE/Schreibcache der DroboPro ungemessen, Platzsperre bei iSCSI ohne Statusdaten (Schritt 5). Das Formatieren der echten LUN 1 und die Montage stehen noch aus.

## Volume-Verwaltung der DroboPro (2026-10-16T23:16:22+0200)

Betreiber: „wir müssen für diese ja auch noch rausfinden wie neue platten anlegen und formatieren usw“.
Gemessen (nur lesend, Seiten 5A/3A mit **genau passender Allokationslänge** — 04/07 antworten bei 512 nicht, bei 157 schon; Länge = drobo-utils-Strukturgröße):
- 04 LUNInfo: 2 aktive LUNs; geschützt 17,88 TB, belegt 0,99 TB. 07 LUNInfo2: LUN 0/1 je 16 TiB, GPT, 1 Partition, Format-Kennung 0x40 (in drobo-utils nicht belegt, offen); LUN 2–7 16 TiB, ohne Schema (Platzhalter).
- 05 Name „DroboPro“; 03 SlotInfo (Platten ST8000DM004); 30 Schwellen gelb 85 %, rot 95 %.
Modell (drobo-utils Drobo.py SetLunSize/GetSubPageLUNs, gelesen): Volumes = LUNs, die die Firmware selbst anlegt; einstellbar ist nur die **LUN-Größe** (EA 10 00 0F, 4 Byte TiB, ausgehängt). Anzahl LUNs folgt aus geschützter Kapazität / LUN-Größe. Formatieren macht der Host (iscsi-format).
Schritte: (V1) Kern liest 04/07/05/03/30 mit exakter Länge, Dashboard zeigt LUNs. (V2) LUN-Größe setzen: EA 10 0F mit Daten **im Befehls-PDU** (DroboPro startet sonst neu), nur bei ausgehängt, nur DroboPro (Testgerät), Messung: Neustart? Datenerhalt? neue LUN-Zahl. (V3) iscsi-format je LUN. Offen: EA 10 0x02 (Drobo-Format = alles löschen) nur auf eigenes Wort.

## Netzweg: Weiterleitung im Hilfsdienst (2026-10-16T23:34:30+0200)

Betreiber: „Na dann fixe das!“ (auf: Weiterleitung in den Hilfsdienst).
Gemessen: Das Modul hfsdropro bekommt zu 192.168.178.x „connect: No route to host“; nehelper „Could not find bundle ID or display name for app: de.begod.drobofsprobe.iscsi“ → macOS-Datenschutz *Lokales Netzwerk* sperrt die Erweiterung, eine Abfrage erscheint nicht (auch nicht mit NSLocalNetworkUsageDescription im appex). Über eine Weiterleitung auf 127.0.0.1 (Loopback ist ausgenommen) liest/hängt das Modul die LUN ein (DROPRO1, 2,0 TiB, nurlesen). Außerdem: das FSKit-URL-Volume gilt für TCC als **Netzwerkvolume** (kTCCServiceSystemPolicyNetworkVolumes je zugreifender App).
Entwurf (verworfen: Weiterleitung in der App — Volume stirbt mit der App; Drittanbieter-Initiator — siehe oben):
- Hilfsdienst (launchd-Daemon; laut Apple TN3179 nicht vom Datenschutz *Lokales Netzwerk* erfasst — **erst messen**) bekommt XPC `iscsiWeiterleitung(host, port) -> lokaler Port`.
- Grenzen: Ziel nur IPv4-Literal in 10/8, 172.16/12, 192.168/16, 169.254/16; Port nur 3260; Listener nur 127.0.0.1, Port vom System; eine Weiterleitung je Ziel, wiederverwendet. Jeder lokale Prozess kann den Loopback-Port nutzen — gleichwertig zum direkten LAN-Zugang, keine neue Reichweite.
- Leerlauf-Ende des Dienstes nur, wenn auch keine weitergeleitete Verbindung offen ist.
- CLI `drobo iscsi-mount` holt den Port, setzt die Freigabe im Container des iSCSI-Moduls über den Dienst und hängt `iscsi://127.0.0.1:PORT/IQN/LUN` ein.
Erfolg: Modul hängt DroboPro-LUN 1 ohne Terminal-Weiterleitung ein; Gegenprobe Weiterleitung aus → `No route to host`.
