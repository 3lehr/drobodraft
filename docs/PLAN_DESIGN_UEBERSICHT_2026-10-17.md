# Plan: Design der App überarbeiten — 2026-10-17T06:28:42+0200

Betreiber: „wir können dann aber noch einmal über das Design sprechen wie optimieren wir dieses? Was ist nicht gut gelöst?“
Grundlage: docs/screens/overview.png, drives.png, speed.png (Stand 2026-10-16).

## Befunde (gemessen an den Bildschirmfotos)
1. Übersicht zeigt den virtuellen HFS-Füllstand (63,65 von 70,37 TB, blau) und „Alles in Ordnung“ (= letzte Dateisystemprüfung), während Laufwerke „Zustand: Warnung“, gelbe Schwelle, Schacht 1 gelb, 4,25 TB physisch frei zeigt. Zwei Füllstände, Warnung nur im Nebenreiter.
2. Kein Gerätebild: Schachtliste ohne Lage (oben/unten), „Gelb“ ohne Bedeutung und ohne Handlung.
3. Statusleiste dauerhaft mit Entwicklerinfo (Helfer, Plattenzugriff, Modul); Übersetzungsfehler „nicht geprüft“ in englischer Oberfläche.
4. Navigation mischt Zustand (Übersicht, Volume, Laufwerke, Protokoll) und Werkzeug (Tempo); „Volume“/„Laufwerke“ für Laien gleichbedeutend.
5. Seitenleiste: Häkchen und Halbkreis-Symbol ohne klare Bedeutung. Tempo: alte Messwerte ohne Datum bei getrennter Drobo; feste Skala 0–200 (DroboPro misst ~5 MB/s).

## Entwurf Übersicht (ASCII zuerst, Hausregel)
```
┌ Drobo 5C ─────────────────────────────── Frühe Alpha ┐
│  ┌──────┐   ⚠ Platz wird knapp                       │
│  │ ▮ 1 ●│   Noch 4,25 TB frei (6 %). Ab 95 % stoppt  │
│  │ ▮ 2 ●│   das Schreiben.                           │
│  │ ▮ 3 ●│   → Schacht 1 durch größere Platte ersetzen│
│  │ ▮ 4 ●│                                            │
│  │ ▮ 5 ●│   Schutz: aktiv (eine Platte darf ausfallen)│
│  │▪▪▪▪▪▪▫│                                           │
│  └──────┘   Echter Füllstand ████████████░░  94 %    │
├──────────────────────────────────────────────────────┤
│  Eingehängt: nein   [Einhängen (nur lesen)]          │
│                     [Zum Schreiben einhängen …]      │
├──────────────────────────────────────────────────────┤
│  Dateisystem zuletzt geprüft: 16.10., in Ordnung     │
└──────────────────────────────────────────────────────┘
Seitenleiste: Drobos (Zustandspunkt je Drobo: verbunden/eingehängt/Warnung)
              Ansicht: Übersicht · Laufwerke · Protokoll
              Werkzeuge: Tempo · Ordner sichern · Volumes
```

## Entscheidungen (Assistent; Betreiber kann widersprechen)
- Oberste Aussage = Schutz- und Platzzustand der Drobo (Statusseite 09 + 02 + Schwellen 30), mit genau einer Handlungsempfehlung. Virtuelle HFS-Größe nur in „Details“.
- Gerätebild je Modell (5 oder 8 Schächte, Schachtlampen + blaue Füllstandsleiste wie am Gerät), Schacht 1 oben (am Gerät geeicht 2026-10-16). Farbe nie allein: Symbol + Text (WCAG 1.4.1).
- Statusleiste nur bei Problem, mit Anleitung. Alle Zeichenketten über Localizable.xcstrings (de+en), Lint gegen fest verdrahtete Texte.
- Tempo: Datum der letzten Messung; Skala passt sich an (z. B. nächste runde Größe über dem Messwert).
- Bewusst nicht: animierte 3D-Drobo, eigenes Farbschema (Systemfarben, Hell/Dunkel automatisch).

## Reihenfolge
Nach der Netzwerk-Ansicht (Agent, selbe Dateien). Dann: (1) Zustandsmodell im Kern (eine Funktion „Gesamtzustand“ aus 09/02/30/Prüfung, getestet), (2) Übersicht + Gerätebild, (3) Seitenleiste/Navigation, (4) Statusleiste/Übersetzung, (5) Tempo. Erfolg: Übersicht zeigt bei der Drobo 5C mit Stand 16.10. „Platz wird knapp“ + Schacht 1; neue Bildschirmfotos ersetzen docs/screens.

## Ergänzung Betreiber (2026-10-17T06:29:50+0200)
Wörtlich: „Können wir uns bei Design am Original drobo Layout orientieren, und ebenfalls die [Drobo] bildlich darstellen, dann könnten wir Zusatzinformationen wie Temperatur … auch direkt in der dargestellten drobo Laufwerk anzeigen lassen“.
- Mitte: eigene, gezeichnete Vorderansicht (SwiftUI-Formen, kein Drobo-Logo, keine Grafiken aus dem Original — Urheberrecht), 5 oder 8 Schächte, Schacht 1 oben, Statuslampe je Schacht (Farbe + Symbol + Text), blaue Füllstandsleiste unten wie am Gerät.
- Je Platte im Bild: Kapazität; bei Zeigen/Antippen/VoiceOver: Modell, Temperatur, Restlebensdauer, Fehlerzähler (Seite 0x35 SlotInfo2, 108 B je Schacht; 5C gemessen, DroboPro mit Länge 512 ohne Antwort → exakte Länge messen wie bei 04/07). Einheiten Temperatur/Lebensdauer laut Recon nur Vermutung → erst am Gerät gegen einen bekannten Wert eichen, bis dahin ohne Einheit anzeigen.
- Rechts: Aufteilung belegt / frei / für Schutz reserviert (Seite 02), Schutzzustand und eine Handlungsempfehlung.
- Barrierefreiheit: Bild ist ein zusammenhängendes Element mit Kinder-Elementen je Schacht (VoiceOver liest „Schacht 1, gelb, 16 TB, …“); Tastatur-Fokus je Schacht.

## Ergänzung Betreiber 2 (2026-10-17T07:04:20+0200): Suche und Netzwerksuche zusammenfassen
Wörtlich: „sollten wir drobo suche und netzwerksuche nicht zusammenfassen, als ein tab in der seiten leiste und dann den inhalt dazu im hauptspalte anzeigen?!“
Entscheidung: ja. Die Knöpfe „Drobos suchen“ und „Per Adresse hinzufügen …“ verlassen die Seitenleiste; es gibt genau einen Eintrag „Drobos finden“ (en: „Find Drobos“) direkt unter der Drobo-Liste, bei neuen Funden mit Zähler „N neu“. Suche beim App-Start bleibt; nichts wird automatisch übernommen.
```
Seitenleiste                   Hauptspalte "Drobos finden"
┌ Drobos ────────────┐         ┌ Drobos finden ─────────────────────────────┐
│ ⚠ Drobo 5C         │         │ Die App sucht Drobos (USB) und DroboPros   │
│   Platz wird knapp │         │ im lokalen Netzwerk. Übernommen wird erst  │
│ ● DroboPro         │         │ nach „Hinzufügen“.                         │
│   Verbunden …      │         │ [🔍 Suchen]  (Fortschritt: ⟳ Suche läuft …)│
│ 🔍 Drobos finden 2 neu│      │ ┌ Per USB angeschlossen ─────────────────┐ │
├ Ansicht ───────────┤         │ │ Drobo, 70 TB            [Hinzufügen]   │ │
│ Übersicht          │         │ ├ Im Netzwerk ───────────────────────────┤ │
│ Laufwerke          │         │ │ DroboPro (192.168.x.y)  [Hinzufügen]   │ │
│ Protokoll          │         │ ├ Schon hinzugefügt ─────────────────────┤ │
├ Werkzeuge ─────────┤         │ │ ✓ Drobo 5C, USB                        │ │
│ Tempo              │         │ └────────────────────────────────────────┘ │
│ Ordner sichern     │         │ Leer: „Noch keine neue Drobo gefunden …“   │
└────────────────────┘         │ ┌ Per Adresse hinzufügen ────────────────┐ │
                               │ │ [192.168.1.20      ] [Prüfen]          │ │
                               │ │ Treffer: Name [DroboPro] Volume … [Hinzufügen] │
                               │ └────────────────────────────────────────┘ │
                               └────────────────────────────────────────────┘
```
Barrierefreiheit: jede Zeile ein VoiceOver-Element, Tastatur: Suchen = ⌘F; „Prüfen“ greift erst bei gültiger IPv4 (vier Zahlen 0 bis 255).

## Umsetzungsstand (2026-10-17T07:04:20+0200)
Siehe Commits auf feature/dropro-iscsi. Abweichungen vom Entwurf oben:
- Füllstand-Prozent wird abgerundet angezeigt (93 statt 94 % bei 63,54 von 67,79 TB), damit „95 %“ auf dem Schirm genau dann steht, wenn die Rot-Schwelle erreicht ist.
- Schwellen: DroboPro Seite 30 (85/95); USB-Drobo: Seite 30 noch nicht gelesen, Vorgabe 85/95 plus die Schwellen-Bits der Drobo (0x2/0x4).
- „Für Schutz reserviert“ = gesamt ungeschützt minus gesamt geschützt (Seite 02): Deutung ungeprüft.
- Temperatur/Restlebensdauer als Rohwert ohne Einheit (OFFEN: am Gerät eichen).
- Seite 0x35 an der DroboPro: Gate mit exakter Länge 12 + 8 x 108 = 876; NICHT am Gerät gemessen, weil die DroboPro vom Betreiber eingehängt ist (keine zweite Sitzung).
- „Volumes“ im Abschnitt Werkzeuge entfällt (es gibt keinen eigenen Volumes-Bildschirm); „Ordner sichern“ öffnet die bisherige Ansicht „Volume“.

## Werkzeug-Prinzip: Umsetzung in der App (2026-10-17T10:00:00+0200)
Auftrag: Regeln wcag.md (Werkzeug-Prinzip, Maße, Nutzerführung), Wissensknoten 3d76cdf5. Layoutänderungen zuerst als ASCII.

### Menüleiste (neu, alle Einträge aus dem Aktionskatalog `Aktion`, eine Quelle)
```
DroboDraft  Bearbeiten  Gehe zu        Drobo                         Volume                         Hilfe
 Über …      Rückgängig ⌘Z  Übersicht ⌘1   Drobos suchen ⌘F               Einhängen (nur lesen) ⇧⌘E      DroboDraft Hilfe ⌘?
 ──────      Wiederholen ⇧⌘Z Laufwerke ⌘2  Gefundene Drobo hinzufügen      Zum Schreiben einhängen …  (kein Kürzel)
 Hilfsdienst             Protokoll ⌘3  ───────────────                 Zum Schreiben neu …        (kein Kürzel)
 Vollzugriff …           ──────────    Umbenennen … ⇧⌘R                Aushängen ⌘E
 Einstellungen ⌘,        Tempo ⌘4      Aus der Liste entfernen ⌘⌫      Im Finder öffnen ⌘O
                         Ordner sichern ⌘5  ─────────────              ─────────────
                         Drobos finden ⌘6   Erneut prüfen              Alle einhängen / Alle aushängen
                                                                       Formatieren …              (kein Kürzel)
                                                                       Festplattenzugriff prüfen · Jetzt prüfen · Probelauf
                                                                       Zurückspielen …            (kein Kürzel) · Wegsichern
                                                                       Tempomessung ⌘T · Aktualisieren ⌘R · Sicherungsort wählen …
```
Menüeinträge ohne Symbole. Zerstörende Aktionen (Schreib-Einhängen, Formatieren, Zurückspielen) bleiben ohne Kürzel mit Bestätigungsblatt, Abbrechen ist Vorgabe (Entscheidung Betreiber nach dem Vorfall ⌘W).

### Bestätigungsblatt mit „Erprobt mit“ (ein Blatt, kein zweites Popup)
```
┌ Zum Schreiben einhängen? ───────────────────────────────────┐
│ Vorher wird eine Sicherung … angelegt.                      │
│ ✓ Ihre Drobo entspricht der erprobten: DroboPro · Firmware  │  voller Treffer
│   22137 · über WLAN.                                        │
│ ── oder ──────────────────────────────────────────────────  │
│ ⚠ DroboPro und Firmware erprobt, der Anschluss über Kabel   │  Teiltreffer / kein Treffer
│   noch nicht.                                               │
│ Bisher erprobt für diese Aktion:                            │
│  • Drobo 5C Gen3 · Firmware 50532 · über USB                │
│  • DroboPro · Firmware 22137 · über WLAN                    │
│ ☐ Ich habe eine aktuelle Sicherung meiner Daten.            │  gibt die Bestätigung erst frei
│                          [Abbrechen]  [Zum Schreiben …]     │
└─────────────────────────────────────────────────────────────┘
```
Formatieren zeigt zusätzlich Volume-Nummer, bisherigen Namen, Größe und Partition. Entscheidung im Kern (`erprobt()`), je Merkmal Modell/Firmware/Anschluss; unbekannte Firmware gilt als abweichend; Anschluss zur Laufzeit aus der Schnittstelle der Route (WLAN/Kabel).

### Weitere Entscheidungen
- Höchstens ein Blatt: `m.blatt` (Enum) statt fünf getrennter `.sheet`.
- Rückgängig: jede Änderung an Drobo-Liste, Namen, Rollen, Orten, Einstellungen läuft über `aendern(_:_:)` (UndoManager des Modells). Nicht rückgängig machbar bleibt Zerstörendes (Formatieren, Zurückspielen, Einhängen zum Schreiben) und die Anmeldeobjekt-Einstellung (Systemzustand, nicht App-Daten).
- Zustand wiederherstellen: gewählter Bereich und Drobo in `ansicht.json` im Datenordner.
- Steuerung per Text: nur Debug-Bau, `DROBO_STEUERUNG=<port>` (127.0.0.1): `/aktionen`, `/menue` (echte Menüleiste), `/zustand`, `/aktion`, `/undo`, `/redo`, `/bild`. Test `fskit_probe/tools/aktionen_test.py`.
- Grenze: Zeilen-Aktionen (je LUN einhängen, Hinzufügen je Fund) stehen im Menü nur für die Haupt-LUN bzw. den ersten Fund; die Zeilenknöpfe bleiben als Beschleuniger.
