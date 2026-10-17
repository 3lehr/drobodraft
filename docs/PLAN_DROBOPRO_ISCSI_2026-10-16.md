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
- **Erledigt (2026-10-17T05:40:38+0200):** Weiterleitung im Hilfsdienst (5da37a9) — launchd-Dienst ist von der Sperre nicht betroffen (Verbindung ESTABLISHED, Probe über Dienst-Port = direkt). `drobo iscsi-mount --host H --lun 1 --write` hängt DROPRO1 ohne Terminal ein. Schreibtest über das Modul an der echten DroboPro: 200 MiB + Ordner/Verschieben, aus-/einhängen, md5 gleich; max_cmd=524288; dev_bytes 425 MB für 210 MB Nutzdaten (Nullen bei Zuweisung, ×2). Tempo über WLAN, ein Befehl zur Zeit im Modul: schreiben 5,1 MB/s, lesen 4,9 MB/s.
- **Offen, nach Wirkung:** (1) LAN-Kabel (WLAN 5–83 ms RTT); (2) mehrere iSCSI-Befehle gleichzeitig im Modul/Client (gemessen QD4 ≈ 2,5× QD1 beim Lesen); (3) Nullen nur für den nicht beschriebenen Teil einer Zuweisung (×2 beim Schreiben); (4) Volume-Verwaltung V1/V2; (5) App-Oberfläche für Netzwerk-Drobos; (6) Time Machine.
- **Schritt 5 (App) erledigt, Stand 2026-10-17T06:45:00+0200:** Netzwerk-Drobo in der App (Hinzufügen per Suche oder Adresse, Einhängen nur lesen/Schreiben mit Sicherung, Aushängen, Status 02/03/05/06/08/09/30 vor dem Einhängen), Knopf „Drobos suchen“ (USB + LAN-Scan im Hilfsdienst, Präfix-Filter Data Robotics), `drobo detect` findet die DroboPro. Nicht umgesetzt: Prüfung nach dem Schreiben, Zurückspielen, Wegsichern, Tempo für Netzwerk-Drobos; Status wird bei eingehängter DroboPro nicht neu gelesen (eine Sitzung); LUN-Seiten 04/07 nur im Gate erlaubt, nicht dekodiert. Bild: docs/screens/netz_uebersicht_2026-10-17_app.png.

## Volume-Verwaltung, Stand 2026-10-17T07:44:26+0200
- **Seiten 04/07 dekodiert** (gegen Rohbytes der echten DroboPro, 2026-10-17): Kopf `7A <sub> <len16>` (Seite 07 antwortet mit Unterseite 0x04), 1 Byte Anzahl, je Satz u16 Länge (17) + Nutzdaten. 07: LUN, Größe (16 TiB), Schema (3 = GPT), Partitionen, Format-Kennung 0x40, Kennung 1000/1001 (unbelegt), 3 Rohbytes; Sätze hinter der Anzahl sind Füllung. 04: nur der erste Satz gefüllt (Pool: geschützt 17,89 TB, benutzt 0,99 TB = Seite 02), LUN 1 fehlt dort. Je-LUN-Belegung kommt deshalb aus dem HFS-Header, nicht aus Seite 04.
- **Seite 0x35 (SlotInfo2):** beantwortet die DroboPro bei keiner Allokationslänge (Messbefund Orchestrator 2026-10-17: 4, 8, 864, 868, 869, 872, 876). Das Gate sendet sie nie. Folge: keine Temperatur/Restlebensdauer/Fehler für die DroboPro, die Zeilen entfallen.
- **Lampencodes Seite 03** gegen die echten Bytes geprüft (Byte 19 des 72-B-Satzes: 3 grün, 0x80 leer; Test: Schächte 1–6 und 8 grün, 7 leer). Alle Codes 0–6 und 0x80 sind abgebildet, unbekannt wird benannt.
- **iscsi-format** für jede LUN (nie eine eingehängte; `--execute` braucht `--confirm N`). **iscsi-mount/-unmount --all**, **iscsi-luns**. Ob die DroboPro mehrere gleichzeitige Mounts (je LUN eine iSCSI-Sitzung) verträgt, ist **ungemessen**.
- **EA 10 0F (LUN-Größe)**: Gate nur für den exakten CDB mit 4 Datenbytes im Command-PDU, nur während `lunGroesseSetzen`, nur mit ausgehandeltem ImmediateData, nur bei DroboPro-INQUIRY. `iscsi-lunsize --tib N` (Trockenlauf, sichert Seiten 01/02/04/07/09 + LUN-Liste). **Messlauf NICHT gelaufen** (siehe unten). Die App-Schaltfläche „Aufteilung ändern …“ ist deshalb nicht gebaut.
- **Messblockade:** Ab ca. 07:30 (Mac per Kabel an der DroboPro) antwortet die DroboPro auf keinen iSCSI-Login mehr (TCP-Verbindung kommt zustande, danach „iSCSI timeout: no data within 10.0 s“; jede Sonde bleibt als FIN_WAIT_2 stehen, die DroboPro schließt ihre Seite nie). Ping 0,6 ms, Port 3260 offen. Vermutung (ungeprüft): hängende Sitzung auf der DroboPro nach den Timeout-Messungen an Seite 0x35. Keine weitere Sonde gesendet, um nicht weitere halboffene Sitzungen anzuhäufen.
- **Feste Kennung:** `NetzZiel` trägt IQN und LUN-Liste (alte Einträge ohne beides lesbar). Wechselt die IP: Suche über den Hilfsdienst, nur Treffer mit gleicher IQN (höchstens alle 5 Minuten), Protokoll „Adresse geändert: alt → neu“ oder „nicht erreichbar“.
- **Umbenennen:** App-Name je Drobo änderbar. Gerätename per MODE SELECT (55 01 7A 05): NICHT gebaut, erst messen (Gerät antwortet nicht). Volume-Name: das Modul (`Module/HFSVolume.swift`) hat nur `renameItem` für Dateien, kein Umbenennen des Volumes; der Name wird beim Formatieren gesetzt (`--name`).

## Hänger der DroboPro und Sitzungsleichen (2026-10-17T08:09:27+0200)

Befund: Seit ~07:25 nimmt die DroboPro keine normale Sitzung mehr an (Ping, Port 3260, Discovery noch ok bis 07:47). Vorher: 07:11 0x35-Probe (Swift, Zeitüberschreitung), danach 7 weitere 0x35-Proben (Python) ohne Antwort; die abgebrochenen Verbindungen blieben in FIN_WAIT_2 (DroboPro schließt nie). Erklärungen, nicht getrennt: (1) Sitzungsplätze erschöpft durch abgebrochene, nie abgemeldete Sitzungen; (2) Befehlsverarbeitung hängt. Fehler des Orchestrators: 0x35 nach der ersten Zeitüberschreitung noch siebenmal gesendet.
Betreiberfrage: „das könnte auch zu Problemen führen, wenn der User den Mac z.B. 10 mal herunterfährt, ohne dass sich DroboDraft von der Drobo abmeldet?“ → ja (folgt aus (1)).
Maßnahmen: (a) keine Befehle ohne gemessene Antwort (0x35 gesperrt, erledigt); (b) Logout vor jedem Verbindungsabbau, auch nach Zeitüberschreitung; (c) Modul/Hilfsdienst melden sich bei Aushängen, Ruhezustand, Herunterfahren (SIGTERM) ab; (d) feste Initiator-Kennung + ISID je Mac und Zweck → RFC 7143 Session Reinstatement räumt Leichen beim nächsten Login; (e) eine gemeinsame Sitzung über den Hilfsdienst, max. 2 gleichzeitig; (f) Hänger-Erkennung (Discovery ja, Normal-Login nein) → App meldet „DroboPro reagiert nicht – neu starten“, Abfragen pausieren.
Messung nach Neustart (Testgerät, ggf. weitere Neustarts nötig): (i) Login, TCP ohne Logout kappen, erneuter Login mit GLEICHER ISID → ersetzt? (ii) dasselbe mit NEUER ISID je Versuch, zählen bis Verweigerung → Anzahl Plätze, bestätigt/widerlegt (1). (iii) Zeit, nach der die DroboPro eine Leiche selbst räumt (NOP-In ohne Antwort).

### Hänger: Umsetzung (2026-10-17T09:00:50+0200)
- **Auslöser gemessen (Orchestrator):** MODE SENSE(10) 5A/3A mit nicht gemochter Allokationslänge wird nicht beantwortet UND haengt die Befehlsverarbeitung bis zum Neustart (Login geht weiter): 0x35 jede Länge, Seite 01 mit 4096, Seite 03 mit 864. Seite 03 meldet `7a03 0241` = 581 B; die App fragte sie alle 60 s mit 864.
- **Erledigt, jeweils mit Rotprobe:** (1) Gate `modeSenseExakt` = Kopf+4 für 01/02/03/04/05/06/07/08/09/30 (28/36/581/157/42/6/157/314/16/13), keine 512-Vorgabe, 33/35 nie; Test n−1/n/n+1 je Seite (864 für 03 rot). Decoder Seite 03 las schon 8×72 B ab Byte 5 = 581, unverändert. (2) ISID = 0x80 + 5 B SHA-256(Hardware-UUID|Zweck), Zwecke `status`, `discovery`, `mount-lun<N>`, `format`, `groesse`, `sonde`; Initiator-Name je Mac `iqn.2026-10.local.drobodraft:<16 hex>` aus Hash der Hardware-UUID (ein fester Name für alle Macs ließe zwei Macs sich per Reinstatement gegenseitig verdrängen). (3) Logout (eigene Grenze 2 s) nach jedem Fehler inkl. Zeitüberschreitung, im Modul bei `deactivate`, App hängt iSCSI-Volumes bei willSleep/willPowerOff aus, Hilfsdienst schließt bei SIGTERM alle Weiterleitungen (shutdown beider Seiten; die Pumpe kennt kein iSCSI, sendet also selbst keinen Logout). (4) `StatusBremse`: höchstens alle 5 min, nie eingehängt, höchstens eine Status-Sitzung, nach EINER Zeitüberschreitung Pause bis „Erneut prüfen“ („DroboPro reagiert nicht – bitte neu starten“); auch keine Adresssuche (LAN-Scan öffnet Sitzungen) während der Pause. Verbindungsaufbau ohne Antwort zählt NICHT als Hänger (Host weg). (5) Python-Ziel: `--hang-after N` (und falsche Länge) → ab da keine Antwort auf allen Verbindungen; Test: Bremse → genau 1 Befehl am Ziel statt 6.
- **Mehrere Rechner:** Login-Ablehnung 2/2 → Zustand „von einem anderen Rechner belegt“, gleiche Bremse, keine Wiederholschleife; Python-Ziel `--reject-other-initiator`.
- **Hilfe (de/en):** Abschnitt „Wenn die DroboPro nicht reagiert“ (Anzeichen alle Lampen rot, Platten still; aus per Knopf, Netzkabel ziehen, 1–2 min warten, einschalten, bis zu 30 Minuten bis alle Lampen grün, keine Platten ziehen) und „Mehrere Rechner“ (iSCSI = rohe Platte, jede LUN nur ein Rechner, gemeinsame Nutzung nur per SMB-Freigabe von einem Rechner). Gemessene Zeiten 2026-10-17 (nur hier, nicht in der Oberfläche): aus/an 08:16, iSCSI 08:38, alle Lampen grün 08:46.
- **Ungeprüft:** Verhalten der echten DroboPro mit den neuen Längen/ISIDs (kein Kontakt, sie hängt); ob Session Reinstatement dort greift (Messung (i)–(iii) oben); die App-Oberfläche wurde gebaut, nicht gestartet.

## LUN-Zuordnung je Rechner (Entwurf, NICHT gebaut, 2026-10-17T09:00:50+0200)
Wunsch Betreiber: LUN einem Rechner zuordnen und wieder freigeben, nicht über die IP. **Identität = Initiator-Name je Mac** (Rechnername nur Anzeige). Zwei Schichten, kombiniert:
- **Unten, Gerätesperre (Schutzwirkung am Ziel), je nach Messung:** (1) Seite 0x15 LUNMapping / Client-Einstellungen der DroboPro (ungemessen; exakte Länge aus dem Kopf, erst nach Neustart messen); (2) SCSI-3 Persistent Reservation, bevorzugt „Write Exclusive“ bzw. „Write Exclusive – Registrants Only“: andere Rechner dürfen LESEN. Messen nur lesend: PR IN REPORT CAPABILITIES (5E, Dienst 02) und READ KEYS (5E/00). Ist keines von beidem vorhanden, bleibt nur (3).
- **Oben, Belegungsvermerk auf der LUN (nur DroboDraft untereinander, keine Schutzwirkung gegen andere Software):** Rechnername, Initiator, seit, Lebenszeichen alle ~5 min solange eingehängt.
- **Rettung, wenn Rechner B (z. B. defekter Laptop) die LUN hält:** (1) Fremder Mac darf jederzeit NUR LESEND einhängen (Reservierung lässt Lesen zu); Warnhinweis, falls der Besitzer zuletzt vor < 15 min aktiv war. (2) „Übernehmen“ = PR PREEMPT (bzw. Zuordnung umschreiben) nur wenn das Lebenszeichen > 15 min alt ist ODER ausdrücklich bestätigt „Rechner B ist aus/defekt“; danach zuerst nur lesend einhängen + Dateisystemprüfung, erst dann schreiben. (3) Letzter Ausweg ohne Software: DroboPro-Neustart löst alle Sitzungen; Reservierungen sind persistent und bleiben, darum ist (2) nötig.
- **Oberfläche:** je LUN „frei / zugeordnet an <Rechner>“, Knöpfe „Diesem Mac zuordnen“, „Freigeben“, „Übernehmen“ (mit Warnung).
- **Reihenfolge:** erst messen (nach Neustart der DroboPro), dann bauen; kein Schreibbefehl der PR-Familie ohne gemessene Antwort.
