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
