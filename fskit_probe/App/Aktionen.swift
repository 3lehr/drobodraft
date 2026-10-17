import DroboKern
import SwiftUI

/// Aktionskatalog: EINE Quelle fuer Menueleiste (Commands), Menueleisten-Symbol und Steuerung per Text (`aktionen`).
/// Regeln (vom Test tools/aktionen_test.py geprueft): jede Aktion steht im Menue, kein Kuerzel doppelt, jede datenaendernde Aktion hat Rueckgaengig,
/// Ausfuehren + Rueckgaengig = unveraendert. Schreib-Einhaengen, Neu-Schreiben, Formatieren und Zurueckspielen haben BEWUSST kein Kuerzel
/// (Betreiberentscheidung nach dem Vorfall mit Cmd-W): sie oeffnen nur das Bestaetigungsblatt, Abbrechen ist dort die Vorgabe.
struct Kuerzel: Equatable {
    let taste: KeyEquivalent
    let mods: EventModifiers
    let text: String
    init(_ c: Character, _ m: EventModifiers = .command) {
        taste = KeyEquivalent(c); mods = m
        text = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "") + String(c).uppercased()
    }
    init(loeschen m: EventModifiers = .command) { taste = .delete; mods = m; text = "⌘⌫" }
}

enum Aktion: String, CaseIterable, Identifiable {
    case geheUebersicht, geheLaufwerke, geheProtokoll, geheTempo, geheSichern, geheFinden
    case drobosSuchen, gefundeneHinzufuegen, umbenennen, entfernen, erneutPruefen
    case einhaengenLesen, einhaengenSchreiben, neuSchreiben, aushaengen, imFinder, alleEinhaengen, alleAushaengen, formatieren
    case zugriffPruefen, dateisystemPruefen, probelauf, zurueckspielen, wegsichern, tempoMessung, aktualisieren
    case sicherungsortWaehlen, hilfsdienstEinrichten, zugriffOeffnen, spotlightAnleitung
    case rueckgaengig, wiederholen, einstellungen, hilfe, ueber
    var id: String { rawValue }

    struct Def { let menu: String; let titel: String; var kuerzel: Kuerzel?; var aendert = false; var undo = false; let gruppe: Int }

    static var menuGehe: String { String(localized: "Gehe zu") }
    static var menuDrobo: String { String(localized: "Drobo") }
    static var menuVolume: String { String(localized: "Volume") }
    static var menuBearbeiten: String { String(localized: "Bearbeiten") }
    static var menuHilfe: String { String(localized: "Hilfe") }
    static let menuApp = "DroboDraft"

    var def: Def {
        switch self {
        case .geheUebersicht: return Def(menu: Self.menuGehe, titel: String(localized: "Übersicht"), kuerzel: Kuerzel("1"), gruppe: 0)
        case .geheLaufwerke: return Def(menu: Self.menuGehe, titel: String(localized: "Laufwerke"), kuerzel: Kuerzel("2"), gruppe: 0)
        case .geheProtokoll: return Def(menu: Self.menuGehe, titel: String(localized: "Protokoll"), kuerzel: Kuerzel("3"), gruppe: 0)
        case .geheTempo: return Def(menu: Self.menuGehe, titel: String(localized: "Tempo"), kuerzel: Kuerzel("4"), gruppe: 1)
        case .geheSichern: return Def(menu: Self.menuGehe, titel: String(localized: "Ordner sichern"), kuerzel: Kuerzel("5"), gruppe: 1)
        case .geheFinden: return Def(menu: Self.menuGehe, titel: String(localized: "Drobos finden"), kuerzel: Kuerzel("6"), gruppe: 1)
        case .drobosSuchen: return Def(menu: Self.menuDrobo, titel: String(localized: "Drobos suchen"), kuerzel: Kuerzel("f"), gruppe: 0)
        case .gefundeneHinzufuegen: return Def(menu: Self.menuDrobo, titel: String(localized: "Gefundene Drobo hinzufügen"), kuerzel: nil, aendert: true, undo: true, gruppe: 0)
        case .umbenennen: return Def(menu: Self.menuDrobo, titel: String(localized: "Umbenennen …"), kuerzel: Kuerzel("r", [.command, .shift]), aendert: true, undo: true, gruppe: 1)
        case .entfernen: return Def(menu: Self.menuDrobo, titel: String(localized: "Aus der Liste entfernen"), kuerzel: Kuerzel(loeschen: .command), aendert: true, undo: true, gruppe: 1)
        case .erneutPruefen: return Def(menu: Self.menuDrobo, titel: String(localized: "Erneut prüfen"), kuerzel: nil, gruppe: 2)
        case .einhaengenLesen: return Def(menu: Self.menuVolume, titel: String(localized: "Einhängen (nur lesen)"), kuerzel: Kuerzel("e", [.command, .shift]), gruppe: 0)
        case .einhaengenSchreiben: return Def(menu: Self.menuVolume, titel: String(localized: "Zum Schreiben einhängen …"), kuerzel: nil, gruppe: 0)
        case .neuSchreiben: return Def(menu: Self.menuVolume, titel: String(localized: "Zum Schreiben neu …"), kuerzel: nil, gruppe: 0)
        case .aushaengen: return Def(menu: Self.menuVolume, titel: String(localized: "Aushängen"), kuerzel: Kuerzel("e"), gruppe: 0)
        case .imFinder: return Def(menu: Self.menuVolume, titel: String(localized: "Im Finder öffnen"), kuerzel: Kuerzel("o"), gruppe: 0)
        case .alleEinhaengen: return Def(menu: Self.menuVolume, titel: String(localized: "Alle einhängen"), kuerzel: nil, gruppe: 1)
        case .alleAushaengen: return Def(menu: Self.menuVolume, titel: String(localized: "Alle aushängen"), kuerzel: nil, gruppe: 1)
        case .formatieren: return Def(menu: Self.menuVolume, titel: String(localized: "Formatieren …"), kuerzel: nil, gruppe: 1)
        case .zugriffPruefen: return Def(menu: Self.menuVolume, titel: String(localized: "Festplattenzugriff prüfen"), kuerzel: nil, gruppe: 2)
        case .dateisystemPruefen: return Def(menu: Self.menuVolume, titel: String(localized: "Jetzt prüfen"), kuerzel: nil, gruppe: 2)
        case .probelauf: return Def(menu: Self.menuVolume, titel: String(localized: "Probelauf"), kuerzel: nil, gruppe: 2)
        case .zurueckspielen: return Def(menu: Self.menuVolume, titel: String(localized: "Zurückspielen …"), kuerzel: nil, gruppe: 2)
        case .wegsichern: return Def(menu: Self.menuVolume, titel: String(localized: "Wegsichern"), kuerzel: nil, gruppe: 2)
        case .tempoMessung: return Def(menu: Self.menuVolume, titel: String(localized: "Tempomessung starten oder stoppen"), kuerzel: Kuerzel("t"), gruppe: 3)
        case .aktualisieren: return Def(menu: Self.menuVolume, titel: String(localized: "Aktualisieren"), kuerzel: Kuerzel("r"), gruppe: 3)
        case .sicherungsortWaehlen: return Def(menu: Self.menuVolume, titel: String(localized: "Sicherungsort wählen …"), kuerzel: nil, aendert: true, undo: true, gruppe: 4)
        case .hilfsdienstEinrichten: return Def(menu: Self.menuApp, titel: String(localized: "Hilfsdienst einrichten"), kuerzel: nil, gruppe: 1)
        case .zugriffOeffnen: return Def(menu: Self.menuApp, titel: String(localized: "Festplattenvollzugriff öffnen …"), kuerzel: nil, gruppe: 1)
        case .spotlightAnleitung: return Def(menu: Self.menuHilfe, titel: String(localized: "Spotlight-Anleitung …"), kuerzel: nil, gruppe: 1)
        case .rueckgaengig: return Def(menu: Self.menuBearbeiten, titel: String(localized: "Rückgängig"), kuerzel: Kuerzel("z"), gruppe: 0)
        case .wiederholen: return Def(menu: Self.menuBearbeiten, titel: String(localized: "Wiederholen"), kuerzel: Kuerzel("z", [.command, .shift]), gruppe: 0)
        case .einstellungen: return Def(menu: Self.menuApp, titel: String(localized: "Einstellungen …"), kuerzel: Kuerzel(","), gruppe: 0)
        case .hilfe: return Def(menu: Self.menuHilfe, titel: String(localized: "DroboDraft Hilfe"), kuerzel: Kuerzel("?"), gruppe: 0)
        case .ueber: return Def(menu: Self.menuApp, titel: String(localized: "Über DroboDraft"), kuerzel: nil, gruppe: 0)
        }
    }

    /// Wird vom System (Settings-Szene) bzw. vom Befehlsblock mit openWindow bedient, nicht vom Modell.
    var nurMenue: Bool { self == .einstellungen || self == .hilfe || self == .ueber }
    var menuePfad: String { def.menu + " > " + def.titel }
}

extension DroboModell {
    /// LUN, auf die Formatieren aus dem Menue zielt: die Haupt-LUN der gewaehlten Netzwerk-Drobo.
    var lunZiel: Int? { aktuell?.eintrag.netz?.lun }

    func aktiv(_ a: Aktion) -> Bool {
        let d = aktuell
        let frei = arbeit == nil
        let usb = d?.eintrag.netz == nil
        let einhaengbar = d.map { $0.verbunden && !$0.eingehaengt && $0.eintrag.rolle == .arbeitsvolume } == true
        switch a {
        case .geheUebersicht, .geheLaufwerke, .geheProtokoll, .geheTempo, .geheSichern, .geheFinden, .aktualisieren, .hilfsdienstEinrichten, .zugriffOeffnen, .einstellungen, .hilfe, .ueber: return true
        case .sicherungsortWaehlen, .spotlightAnleitung: return blatt == nil
        case .drobosSuchen: return !sucheLaeuft
        case .gefundeneHinzufuegen: return !erkannte.isEmpty || !lanErkannte.isEmpty
        case .umbenennen: return d != nil && blatt == nil
        case .entfernen: return d != nil && einstellungen.drobos.count > 1
        case .erneutPruefen: return d?.eintrag.netz != nil && d?.bremse != .bereit
        case .einhaengenLesen: return frei && einhaengbar
        case .einhaengenSchreiben: return frei && blatt == nil && einhaengbar
        case .neuSchreiben: return frei && blatt == nil && d?.eingehaengt == true && d?.nurlesen == true
        case .aushaengen: return frei && d?.eingehaengt == true
        case .imFinder: return d?.eingehaengt == true
        case .alleEinhaengen: return frei && d.map { x in x.eintrag.netz != nil && x.luns.contains { l in l.hatDateisystem && x.lunEingehaengt[l.lun] == nil } } == true
        case .alleAushaengen: return frei && d.map { $0.eintrag.netz != nil && !$0.lunEingehaengt.isEmpty } == true
        case .formatieren: return frei && blatt == nil && lunZiel.map { d?.lunEingehaengt[$0] == nil } == true
        case .zugriffPruefen, .dateisystemPruefen: return frei && usb && d.map { $0.verbunden && !$0.eingehaengt } == true
        case .probelauf: return frei && usb && !restoreAuswahl.isEmpty && d.map { $0.verbunden && !$0.eingehaengt } == true
        case .zurueckspielen: return frei && blatt == nil && !restoreProbeText.isEmpty && restoreProbeFuer == restoreAuswahl && d?.eingehaengt == false
        case .wegsichern: return frei && usb && !wegQuelle.isEmpty && !wegZiel.isEmpty && d?.eingehaengt == true
        case .tempoMessung: return tempoLaeuft || tempoStartbar
        case .rueckgaengig: return undoManager.canUndo
        case .wiederholen: return undoManager.canRedo
        }
    }

    /// Fuehrt die Aktion aus (Menue, Knopf, Steuerung). `arg` ersetzt Eingabeblatt und Ordnerwahl (nur Steuerung). Rueckgabe: Fehlertext oder nil.
    @discardableResult
    func fuehreAus(_ a: Aktion, arg: String? = nil) -> String? {
        guard !a.nurMenue else { return "nur über das Menü" }
        guard aktiv(a) else { return "nicht möglich" }
        switch a {
        case .geheUebersicht: abschnitt = .uebersicht
        case .geheLaufwerke: abschnitt = .laufwerke
        case .geheProtokoll: abschnitt = .protokoll
        case .geheTempo: abschnitt = .tempo
        case .geheSichern: abschnitt = .volume
        case .geheFinden: abschnitt = .finden
        case .drobosSuchen: abschnitt = .finden; drobosSuchen()
        case .gefundeneHinzufuegen:
            if let e = erkannte.first { hinzufuegen(e) } else if let l = lanErkannte.first { lanHinzufuegen(l) }
        case .umbenennen: if let n = arg { umbenennen(auswahl, name: n) } else { blatt = .umbenennen(auswahl) }
        case .entfernen: entfernen(auswahl)
        case .erneutPruefen: erneutPruefen(auswahl)
        case .einhaengenLesen: einhaengen(schreiben: false)
        case .einhaengenSchreiben, .neuSchreiben: schreibenLun = nil; blatt = .schreiben
        case .aushaengen: aushaengen()
        case .imFinder: imFinderOeffnen()
        case .alleEinhaengen: alleLunsEinhaengen()
        case .alleAushaengen: alleLunsAushaengen()
        case .formatieren: if let l = lunZiel { blatt = .format(l) }
        case .zugriffPruefen: zugriffPruefen()
        case .dateisystemPruefen: pruefen()
        case .probelauf: restoreProbe()
        case .zurueckspielen: blatt = .restore
        case .wegsichern: wegsichern(quelle: wegQuelle, ziel: wegZiel)
        case .tempoMessung: if tempoLaeuft { tempoStoppen() } else { tempoStarten() }
        case .aktualisieren: aktualisieren()
        case .sicherungsortWaehlen: if let p = arg { aendern(String(localized: "Sicherungsort ändern")) { $0.sicherungOrt = p } } else { sicherungsOrtWaehlen() }
        case .hilfsdienstEinrichten: dienstRegistrieren()
        case .zugriffOeffnen: festplattenzugriffOeffnen()
        case .spotlightAnleitung: blatt = .anleitung
        case .rueckgaengig: undoManager.undo()
        case .wiederholen: undoManager.redo()
        case .einstellungen, .hilfe, .ueber: break
        }
        return nil
    }
}

/// Befehle der Menueleiste, alle aus dem Katalog. Rueckgaengig/Wiederholen ersetzen die Systemeintraege, weil der Manager dem Modell gehoert; steht der Cursor in einem Textfeld, gilt dessen eigenes Rueckgaengig.
struct DroboBefehle: Commands {
    @ObservedObject var m: DroboModell
    @Environment(\.openWindow) private var openWindow

    func ausfuehren(_ a: Aktion) {
        switch a {
        case .hilfe: openWindow(id: "hilfe")
        case .ueber: ueberFenster()
        case .rueckgaengig, .wiederholen:
            if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(Selector(a == .rueckgaengig ? "undo:" : "redo:"), to: nil, from: nil) } else { m.fuehreAus(a) }
        default: m.fuehreAus(a)
        }
    }

    @ViewBuilder func knopf(_ a: Aktion) -> some View {
        let d = a.def
        let titel = a == .rueckgaengig && m.undoManager.canUndo ? m.undoManager.undoMenuItemTitle : (a == .wiederholen && m.undoManager.canRedo ? m.undoManager.redoMenuItemTitle : d.titel)
        let b = Button(titel) { ausfuehren(a) }.disabled(!(a.nurMenue || m.aktiv(a)))
        if let k = d.kuerzel { b.keyboardShortcut(k.taste, modifiers: k.mods) } else { b }
    }

    @ViewBuilder func gruppen(_ menu: String) -> some View {
        let l = Aktion.allCases.filter { $0.def.menu == menu }
        let gs = Array(Set(l.map { $0.def.gruppe })).sorted()
        ForEach(gs, id: \.self) { g in
            if g != gs.first { Divider() }
            ForEach(l.filter { $0.def.gruppe == g }) { knopf($0) }
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) { knopf(.ueber); Divider(); knopf(.hilfsdienstEinrichten); knopf(.zugriffOeffnen) }
        CommandGroup(replacing: .undoRedo) { knopf(.rueckgaengig); knopf(.wiederholen) }
        CommandGroup(replacing: .help) { knopf(.hilfe); knopf(.spotlightAnleitung) }
        CommandMenu(Text(verbatim: Aktion.menuGehe)) { gruppen(Aktion.menuGehe) }
        CommandMenu(Text(verbatim: Aktion.menuDrobo)) { gruppen(Aktion.menuDrobo) }
        CommandMenu(Text(verbatim: Aktion.menuVolume)) { gruppen(Aktion.menuVolume) }
    }
}
