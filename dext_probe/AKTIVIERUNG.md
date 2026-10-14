# Dext-Probe aktivieren (Plan Phase 0b, Weg A)

Stand: 2026-10-14T07:28:08+0200. Alle Texte unten stammen aus den Lokalisierungen von macOS 26.5.1 (SystemExtensions.framework, SettingsSystemExtensionController).

## Voraussetzungen (gemessen)
- Host liegt in /Applications/DextProbe.app (Ablage per `ditto` aus DerivedData). Dort ist `systemextensionsctl developer on` NICHT noetig; das Werkzeug lehnt bei aktiver SIP ohnehin ab ("cannot be used if System Integrity Protection is enabled").
- Beide Profile enthalten die UDID dieses Macs (<UDID>): Host "Mac Team Provisioning Profile", Dext "DriverKit Team Provisioning Profile".
- Personality matcht Vendor "ABT" / Product "CFX Card Reader" (Kartenleser mit CF-Karte "old", Betreiber-Testgeraet). Strings 1:1 aus ioreg, ohne Padding (`cat -vet` zeigt keine Leerzeichen am Ende). Drobo ("Drobo"/"5C"), Samsung T7 und Backup 1 matchen nicht.

## Klickfolge
1. DextProbe.app aus /Applications starten, "Dext aktivieren" druecken.
2. Alert "„DextProbe" möchte eine neue Treibererweiterung verwenden" -> "Systemeinstellungen öffnen".
3. Systemeinstellungen > Allgemein > Anmeldeobjekte & Erweiterungen > Abschnitt Erweiterungen > "Treibererweiterungen" (Info-Knopf).
4. de.begod.drobo.dextprobe einschalten, mit Touch ID/Kennwort bestaetigen.
5. Pruefen: `systemextensionsctl list` (Abschnitt driver_extension: [activated enabled]).
Bleibt die Anzeige "Neustart erforderlich" oder "Sicherheitseinstellungen verhindern ...": Wiederherstellungsumgebung (Systemerweiterungen aktivieren), nicht selbst aendern.

## Testlauf an der CF-Karte
- Skript: `tools/test_cf.sh` (`show` nur lesen; `sudo ... dd` 2 GiB roh bs=1m und 4m mit Hash und MB/s; `sudo ... fs exfat|hfs` Formatieren + 1 GiB Datei). Es bricht ab, wenn nicht genau eine externe Platte mit Media Name "CFX Card Reader" (~512 GB, INQUIRY ABT) da ist; Disknummern wechseln.
- Vorher-Stand (gemessen 2026-10-14T08:06:24+0200): Nub des Lesers IOMaximumByteCountWrite = 131072, BlockCount 256. Ziel des Dext: 524288 / 1024.
- Ablauf: `tools/test_cf.sh show` und `sudo tools/test_cf.sh dd` VOR Aktivierung, Dext aktivieren (Klickfolge oben), Leser abziehen und wieder anstecken (Nub wird neu erzeugt; Annahme, nicht belegt), dann `show` und `dd` erneut, Zahlen vergleichen.
- Systemeinstellungen-Schalter haben bei FSKit nicht persistiert (Lehre L-6f678f). Beim Dext massgeblich ist `systemextensionsctl list` (Zeile de.begod.drobo.dextprobe, [activated enabled]), nicht die Schalterstellung.

## Ordnername des Dext
sysextd findet den Dext nur, wenn der Ordner `<CFBundleIdentifier>.dext` heisst (Fehler OSSystemExtensionErrorDomain Code=4 "Extension not found in App bundle"). Belegt an Blackmagic: ID `com.blackmagic-design.BlackmagicIO.DExt` liegt im Ordner `...BlackmagicIO.DExt.dext`. Hier daher PRODUCT_NAME = `de.begod.drobo.dextprobe.dext` -> Ordner `de.begod.drobo.dextprobe.dext.dext`, ID unveraendert (Profil bleibt gueltig). Nach Austausch der App in /Applications die laufende DextProbe-Instanz beenden und neu oeffnen.

## Erster Aktivierungslauf: AMFI lehnte den Dext ab (gemessen 2026-10-14T08:23)
`log show` (nutze /usr/bin/log, in zsh ist `log` ein Builtin): kernel erzeugte MaxWriteProbe (Matching OK, auch ohne IOProbeScore), kernelmanagerd startete den Prozess, amfid: "Restricted entitlements not validated ... Code=-413 No matching profile found" (unsatisfiedEntitlements privat), ASP "Security policy would not allow process", spawn error=163. Verdacht (nicht bewiesen): signiertes usb-Entitlement idVendor 65535 gegen Profilwert idVendor '*'. Das usb-Entitlement ist fuer einen SCSI-Peripheral-Dext unnoetig und wurde entfernt. Version 1.1/2 und IOProbeScore 10000 gesetzt (Apples IOSCSIPeripheralDeviceType00 hat 5000).
