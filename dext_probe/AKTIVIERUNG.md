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

## Transfergrenzen (v1.2/3)
Gemessen mit v1.1/2: Dext laeuft (`MaxWriteProbe::start(IOSCSILogicalUnitNub) ok`), aber am Knoten MaxWriteProbe bleiben IOMaximumByteCountWrite 131072 / BlockCountWrite 256, `tools/maxwrite.c` liefert dasselbe per ioctl am /dev/rdisk der Karte (als Nutzer lesbar). Vermutung: `SetProperties(props)` ohne SUPERDISPATCH blieb im Dext (Default scheitert). IOHIDEventService.iig: "SetProperties(properties, SUPERDISPATCH) ... properties added to a dictionary in IOReg". v1.2/3 ruft es so auf, loggt per os_log (`/usr/bin/log show --last 5m --predicate 'eventMessage CONTAINS "MaxWriteProbe:"'`) und setzt dieselben Werte zusaetzlich statisch in der Personality. Header-Fakt: `UserDetermineDeviceCharacteristics` hat nur `bool *result`, es gibt keine Rueckgabestruktur und keine Setter-Methode fuer Grenzen.
Pruefen nach Aktivierung+Leser neu stecken: `ioreg -r -c IOUserSCSIPeripheralDeviceType00 -l | grep IOMaximum` und `cc -o /tmp/maxwrite tools/maxwrite.c; /tmp/maxwrite /dev/rdiskN`.

## Quellenlage Transfergrenzen (v1.2 FALL A, v1.3 Verkleinerungstest)
Quellen gelesen in /Volumes/daten/tools/src (apple-oss-distributions, nur lesen): IOSCSIArchitectureModelFamily-139.0.2 (Stand 2021), IOStorageFamily-337.100.1, IOUSBMassStorageClass-408.
- Quelle der Zahl: IOUSBMassStorageClass.cpp:56-59 Defaults 131072 (USB 2) / 1048576 (USB 3, `deviceSpeed >= kUSBDeviceSpeedSuper`, Zeilen 1575-1640); `IsProtocolServiceSupported(kSCSIProtocolFeature_MaximumWriteTransferByteCount)` (Z. 1605) antwortet das, ueberschreibbar nur durch das Dict `kIOPropertySCSIDeviceCharacteristicsKey` des USB-Treibers selbst (Z. 1558, 1612-1623), also durch dessen Personality, nicht durch einen Dext. Block-Zaehler nur wenn im Dict (Z. 1654ff), sonst "storage stack rechnet aus Byte" (256 = 131072/512). Passt zur Messung: Leser "Device Speed" = 2 -> 131072/256, Drobo (USB 3) 1048576/2048.
- Verbraucher unten: IOBlockStorageDriver.cpp:1339-1372 liest alle kIOMaximum*-Keys mit `copyProperty(key, gIOServicePlane)`, d.h. nimmt den naechsten Knoten Richtung Wurzel, der den Key hat: IOBlockStorageDriver -> IOBlockStorageServices -> MaxWriteProbe-Knoten. Die Anwendung steht in Z. 2918-2930: `withMaximumByteCount = min(blockCountInBytes, withMaximumByteCount)` (Block*Groesse gegen Byte, kleinerer Wert gewinnt) und Z. 3027-3031 (breakSize an Byte-Grenze). Das ist die Aufteilung der Anfragen oberhalb des Treibers.
- NICHT in den Quellen: der Kernel-Teil von IOUserSCSIPeripheralDeviceType00 (Aufruf von UserDetermineDeviceCharacteristics, Reihenfolge, Ueberschreiben) ist im offenen IOSCSIArchitectureModelFamily-139.0.2 nicht enthalten (grep UserDetermineDeviceCharacteristics, kIOMaximum*, MaximumWriteTransfer: keine Treffer); auch strings im Kernelcollection brachte nichts. Zeilenbelege fuer (2) fehlen deshalb; belegt ist nur die Messung: IOMatchedPersonality hat 524288/1024, der Knoten selbst 131072/256, Log ret=0x0.
- Folgerung (Hypothese): Der Knotenwert ist der Protokollwert des USB-Treibers (min/Uebernahme unklar). v1.2 vergroesserte (524288 > 131072) und fiel auf 131072 zurueck: vertraegt sich mit "min(Dext, Protokoll)" ebenso wie mit "Kernel schreibt Protokollwert zurueck". v1.3 trennt das: 65536 / 128 am Leser. Zeigt der Knoten 65536 -> kleinere Werte wirken (min), Verkleinerung der Drobo (1 MiB -> 512 KiB) geht per Dext; zeigt er 131072 -> Dext-Properties werden nach dem Aufruf ueberschrieben, dann Weg A so nicht gangbar (naechster Kandidat: Property an anderer Stelle/Dict).
- Pruefen: `ioreg -r -n "CFexpress Card Reader" -l -w0 | grep -E "IOMaximum"` und `/tmp/maxwrite /dev/rdiskN`.

## Diagnose v1.4/5
Ziel: A (Kernel ueberschreibt nach UserDetermineDeviceCharacteristics) gegen B (Kernel-setProperties nimmt an, setzt nichts) unterscheiden. Der Dext loggt `MaxWriteProbe: DIAG ...` mit CopyProperties am eigenen Objekt: in Start() (nach super), direkt nach SetProperties(SUPERDISPATCH) und per Timer nach 2 s und 10 s; je Zeile Keys-Anzahl, kIOMaximumByteCount/BlockCountWrite und Inhalt von "IOUserServiceProperties". Testwert 65536/128. Auswertung: `tools/diag_v14.sh [Minuten]` (liest Log + ioreg + ioctl, ordnet OK / A / B / H zu). Eichung: vier Beispiel-Logs je Fall mit DIAG_RUN_FILE/DIAG_NODE_BYTES/DIAG_IOCTL_BYTES; Timer-Regex zuerst falsch (10-s-Zeile ueberschrieb die 2-s-Zeile), korrigiert.
