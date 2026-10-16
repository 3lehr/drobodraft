import SwiftUI

/// Kurze Hilfe; Sprache folgt der Systemsprache (Deutsch ist Entwicklungssprache, Englisch im String Catalog).
struct HilfeAnsicht: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("DroboDraft Hilfe").font(.largeTitle).accessibilityAddTraits(.isHeader)
                Hinweis(symbol: "hammer.fill", text: "Frühe Alpha: Funktionen ändern sich noch. Nicht für den Dauerbetrieb und nicht für Daten ohne Zweitkopie gedacht.")
                Karte(titel: "Installation") {
                    Text("DroboDraft liegt in /Applications. Es enthält ein Treibermodul für das Dateisystem der Drobo (HFS+) und einen kleinen Hilfsdienst. Die Drobo wird per USB oder Thunderbolt angeschlossen und erscheint unter „Drobo“ in der Seitenleiste.")
                }
                Karte(titel: "Freischaltungen") {
                    Text("1. Systemeinstellungen, Allgemein, Anmeldeobjekte & Erweiterungen: den Drobo-Hilfsdienst einschalten.")
                    Text("2. Dort bei Erweiterungen (Dateisystemerweiterungen) das Modul „hfsdrobo“ einschalten.")
                    Text("3. Systemeinstellungen, Datenschutz & Sicherheit, Festplattenvollzugriff: den Drobo-Hilfsdienst einschalten. Die Statuszeile unten zeigt, ob der Zugriff funktioniert.")
                }
                Karte(titel: "Sicherheit") {
                    Text("Standard ist „nur lesen“. Zum Schreiben wird vorher automatisch eine Sicherung der Verwaltungsdaten des Laufwerks angelegt und geprüft; gelingt das nicht, wird nicht geschrieben.")
                    Text("Immer erst aushängen, dann abziehen. Wird ein Laufwerk im Schreibzustand getrennt, prüft die App es vor dem nächsten Einhängen.")
                    Text("„Sicherung zurückspielen“ ersetzt Verwaltungsdaten und macht alles rückgängig, was seitdem geschrieben wurde. Es gibt erst einen Probelauf und dann eine zweite Bestätigung.")
                }
                Karte(titel: "Spotlight und Time Machine") {
                    Text("Spotlight läuft nach unseren Messungen nicht in den Einhängeort unter /Volumes hinein. Wer ganz sicher gehen will, schließt die Drobo in den Systemeinstellungen bei Spotlight und Time Machine aus. Das ist freiwillig; die App ändert dazu nichts.")
                }
            }.padding(24)
        }
        .frame(minWidth: 520, minHeight: 520)
    }
}
