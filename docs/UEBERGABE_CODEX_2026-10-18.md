# Übergabe an Codex — DroboDraft, Stand 2026-10-18T06:38:11+0200

Zweig `feature/dropro-iscsi`, Kopf `a1cfdfe`, gepusht, Arbeitsbaum sauber. Nicht auf `main` arbeiten, kein Merge ohne Wort des Betreibers.

## Zuerst lesen (in dieser Reihenfolge)

1. `docs/PLAN_BLOCKGERAET_DRIVERKIT_2026-10-17.md` — Treiber-Umbau, Abschnitt „Kernel-Panic“ und „Wiedereinstieg“ am Ende.
2. `docs/PLAN_LUN_UND_TIMEMACHINE_2026-10-17.md` — Dashboard-Befehle für LUNs, Time-Machine-Wege.
3. `docs/PLAN_DROBOPRO_ISCSI_2026-10-16.md` — Messwerte und Schutzregeln der DroboPro.

## Geräte und Regeln (nicht verhandelbar)

| Gerät | Status | Darf |
|---|---|---|
| Drobo 5C („Drobo 2018a“, USB) | **Produktivdaten ohne Sicherung** | nur lesen. Keine Systembefehle (EA), kein MODE SELECT, kein neuer Schreibweg ohne ausdrückliches Wort des Betreibers |
| DroboPro 8-Bay (iSCSI im LAN, Adresse in den App-Einstellungen) | Testgerät | lesen, schreiben, formatieren. **Alle EA-Systembefehle bleiben gesperrt** (`verbot()` in `ISCSIBefehle.swift`); falsches Format löste Neustarts aus |

- Keine IP, IQN, Seriennummer oder MAC ins Repo (öffentlich).
- Kennwörter, `sudo`, Klicks in Systemeinstellungen/Datenschutz macht der Betreiber.
- Agenten öffnen keine sichtbaren Fenster, kein Computer-Use.
- `enabledModules.plist`/`fskit_agent` nicht anfassen, kein `lsregister -u`, keine registrierten App-Kopien löschen (FSKit-Freischaltung geht verloren).
- Keine Prozesse per Namen beenden (`pkill`/`killall`). Laufende App des Betreibers nur mit Grund beenden (`osascript … quit`).
- Temporäres nur unter `$TMPDIR`/`/private/tmp`, nie direkt unter `/Volumes/daten`. Systemplatte hat ~10 GB frei.
- Commit je Schritt, Nachricht nennt das Warum. Push auf diesen Zweig ist freigegeben.
- Kein „funktioniert“ ohne Test, der vorher rot war.

## Treiber (DriverKit, `blockbruecke/`) — Vorsicht

- 2026-10-17T19:39 **Kernel-Panic** durch unseren Treiber v0.2: Controller per `IOService::Create` angelegt → Kernel-`start()` nie aufgerufen → `fProvider` NULL → Absturz in `IOSCSIParallelInterfaceController::didTerminate` beim Beenden. Lehre L-d7b25d.
- Jetzt: v0.3 aktiv, aber leer (IOSCSIParallelFamily nicht geladen, kein Controller). Deaktivieren ist so gefahrlos; der Betreiber klickt es in „BlockbrueckeHost“.
- **Invarianten:** Familienklassen nie per `Create`, nur über Matching (Nub + Personality). Nie einen Dext-Prozess killen. Vor jedem Aktivieren/Deaktivieren `kmutil showloaded | grep -i SCSIParallel` und `ioreg -l -w0 -d1 | grep -o '"IOUserSCSIParallelInterfaceController"=[0-9]*'` prüfen. Jede neue Stufe mit eigener Bundle-ID (`tools/bauen.sh gruen --id2`).
- Nächster Schritt: v0.4 nach Vorschlag im Plan (Wurzel registriert Nub, zweite Personality matcht darauf). **Test bevorzugt in einer VM**, nicht auf dem Arbeitsrechner.
- Danach: UserClient + Brücke zum vorhandenen Swift-iSCSI-Client (Helper), zuerst gegen `drobo_kern/Tests/iscsi_ziel.py`, dann DroboPro, dann Time Machine (`tmutil` tippt der Betreiber).

## Swift-Design (verbindlich für jede UI-Änderung)

Quelle: Werkzeug-Prinzip (Wissensknoten 3d76cdf5, Ergebnis 3588c88f) und `docs/PLAN_DESIGN_UEBERSICHT_2026-10-17.md`.

- Mac-nativ, kein großes iPad: Menüleiste, Tastaturkürzel, Undo (`UndoManager`), Fokus, VoiceOver, WCAG 2.2 AA.
- Werte nur aus Tokens `Mass.swift` / `Farben.swift`; `ui_guard.py` mit `sperrlisten/drobodraft.json` muss 0 Befunde zeigen.
- Ein Aktionskatalog `Aktionen.swift` speist Menü, Menüleisten-Symbol und Textsteuerung — neue Aktionen nur dort.
- Ein Blatt (Sheet) zur Zeit. Destruktive Aktionen ohne Tastenkürzel, mit Bestätigung, „Abbrechen“ als Standard.
- Schreib-/Formatier-Bestätigung mit „Erprobt mit“-Block (Modell + Firmware + Anschluss) und 15-s-Sperre beim ersten Mal, bei Änderung oder wenn nicht erprobt.
- Anrede „du“, Texte de + en, keine Entwicklerinformation in der Oberfläche.
- Gerätebild nach Original-Drobo: gezeichnetes Gerät, Schachtlampen je Bay, blaue Füllstands-LEDs senkrecht rechts, darunter Power-LED und zwei Statuslampen; Zusatzinfos an den Platten. „Drobos finden“ fasst USB- und Netzsuche zusammen.
- Während kritischer Vorgänge Sperr-Überlagerung nur über der betroffenen Drobo (kein Sheet), Wechsel zu anderer Drobo bleibt möglich.

## DroboDraft-App — offen

- Schachtlampen in der App grau, obwohl Rohbytes grün; Ursache unbekannt (Test mit echten Bytes ist grün). Braucht einen Rohbyte-Mitschnitt im Moment des Fehlers.
- LUN-Befehle nach Dashboard-Format (`EASysop` in `ISCSIGroesse.swift`: 0x0F Größe, 0x12 anlegen, 0x13 löschen, 0x20 nächste ID) nur gegen das Python-Ziel getestet; Bytefolge der Nutzlast teils Vermutung. Klärt ein Dashboard-Mitschnitt: Betreiber startet `sudo tcpdump -i en8 -s0 -w ~/dropro_dash.pcap port 3260` (Kabel ist **en8**, nicht en0) und ändert im Dashboard die LUN-Größe. Erst bei Byte-Gleichheit und mit Wort des Betreibers je Befehl das Gate öffnen.
- Zuordnung LUN ↔ Mac: Dashboard kennt `ForceSingleInitiator` und Initiator-Liste je LUN — Grundlage für das gewünschte Feature.
- App-Einbau: `fskit_probe/tools/install_module.sh` (vorher alle Drobo-Volumes aushängen, App beenden). Tests: `drobo_kern` mit `DROBO_TESTDIR` unter `build/` (nicht Systemplatte), `fskit_probe/tools/aktionen_test.py`, `make lint-texte`, `lokalisierung_test.py`.
