import Foundation

/// LUN-Groesse der DroboPro aendern: GESPERRT. Die Aenderung ist ein 0xEA-Systembefehl; jeder solche Befehl loest an der DroboPro einen Neustart aus
/// (gemessen 2026-10-17, siehe `ISCSISitzung.verbot`). Wirft sofort, vor jedem Netzkontakt und jeder Dateiaktion.
public func iscsiLunGroesse() throws {
    throw ISCSIFehler.verboten("system commands to the DroboPro are blocked: they trigger a restart (measured 2026-10-17)")
}
