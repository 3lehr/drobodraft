# Dext-Probe aktivieren (Plan Phase 0b, Weg A)

Stand: 2026-10-14T07:28:08+0200. Alle Texte unten stammen aus den Lokalisierungen von macOS 26.5.1 (SystemExtensions.framework, SettingsSystemExtensionController).

## Voraussetzungen (gemessen)
- Host liegt in /Applications/DextProbe.app (Ablage per `ditto` aus DerivedData). Dort ist `systemextensionsctl developer on` NICHT noetig; das Werkzeug lehnt bei aktiver SIP ohnehin ab ("cannot be used if System Integrity Protection is enabled").
- Beide Profile enthalten die UDID dieses Macs (<UDID>): Host "Mac Team Provisioning Profile", Dext "DriverKit Team Provisioning Profile".
- Personality ist Platzhalter (Vendor NODEVICE / Product PLATZHALTER-0000). Vor dem Aktivieren Stick anstecken, Vendor/Product aus `ioreg -r -c IOSCSIPeripheralDeviceNub -l` ("Vendor Identification", "Product Identification") in Dext/Info.plist eintragen, neu bauen, neu nach /Applications kopieren. Drobo ("Drobo"/"5C") darf nie matchen.

## Klickfolge
1. DextProbe.app aus /Applications starten, "Dext aktivieren" druecken.
2. Alert "„DextProbe" möchte eine neue Treibererweiterung verwenden" -> "Systemeinstellungen öffnen".
3. Systemeinstellungen > Allgemein > Anmeldeobjekte & Erweiterungen > Abschnitt Erweiterungen > "Treibererweiterungen" (Info-Knopf).
4. de.begod.drobo.dextprobe einschalten, mit Touch ID/Kennwort bestaetigen.
5. Pruefen: `systemextensionsctl list` (Abschnitt driver_extension: [activated enabled]).
Bleibt die Anzeige "Neustart erforderlich" oder "Sicherheitseinstellungen verhindern ...": Wiederherstellungsumgebung (Systemerweiterungen aktivieren), nicht selbst aendern.
