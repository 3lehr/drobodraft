# Plan: Drobo 5C nativ am Mac — Apples HFS+-Code (livefiles_hfs) als FSKit-Modul

Stand: 2026-10-14T00:30:00+0200 · Auftrag Betreiber, wörtlich: „ja zu allem, "B. Apples eigener HFS+-Code als Erweiterung für macOS (FSKit)" umstzten!“

## Ist-Stand (gemessen/recherchiert, Knoten e4696f85)
- Drobo verträgt Schreibbefehle ≤ 512 KiB; macOS-Kernel-HFS schickt 1 MiB (IOMaximumByteCountWrite 1048576 am IOSCSIPeripheralDeviceType00).
- Interim: Linux-VM (tools/vm), Lesen ~205 MB/s über SMB, Schreiben an der Drobo 1× OOM-Absturz (behoben, 64-GiB-Dauerlast am Abbild grün).
- Xcode 26.6, bezahltes Team JR9H9Q532P. FSKit ab macOS 15.4; Entitlement com.apple.developer.fskit.fsmodule (ExtendFS signiert es mit Automatic Signing, Antragspflicht unbelegt).
- livefiles_hfs (apple-oss-distributions/hfs, Tag hfs-715.100.10): Schreiben + Journal (lf_hfs_journal.c), I/O über pread/pwrite (lf_hfs_raw_read_write.c, lf_hfs_generic_buf_write, do_journal_io). Hängt an privatem <UserFS/UserVFS.h>; baut laut README nicht außerhalb Apples.
- Bekannt: Kernel-FS wird vor FSKit bevorzugt (mount -F nötig, eigener Shortname, fstab noauto existiert); EACCES auf physischen Platten (Workaround chown).

## Bauform
FSKit-App-Extension (FSUnaryFileSystem) mit eigenem Shortname (z. B. `hfsd`), darin livefiles_hfs als statische Bibliothek; ein eigener UVFS-Shim ersetzt die privaten Header. Alle Geräte-I/O laufen über FSBlockDeviceResource mit harter Kappung 512 KiB (ein Wrapper, grep-Invariante wie tools/hfs_io.py).

## Reihenfolge (bindend, jede Phase falsifiziert die nächste)
0a. FSKit-Machbarkeit: Xcode-Vorlage, Automatic Signing → Profil mit fskit.fsmodule? Aktivierung (Betreiber-Klick), `mount -F` an hdiutil-Abbild und USB-Stick, Roh-Durchsatz 512-KiB-Schreiben/Lesen durch FSBlockDeviceResource. Abbruchkriterium: kein Profil, EACCES ohne Workaround, < 200 MB/s.
0b. Parallel Weg A: Test-Dext (IOUserSCSIPeripheralDeviceType00, kIOMaximumByteCountWriteKey 524288) mit Automatic Signing; Fehler 9/fehlende Capability = warten auf Apple. Erst USB-Stick.
1. livefiles_hfs außerhalb Apple bauen: UVFS-Symbole inventarisieren, Shim schreiben, statische Lib, Selbsttest gegen Abbild (Lesen/Schreiben/Journal) im Userspace ohne FSKit.
2. FSKit-Adapter: Volume-/Item-Operationen auf LIFS-Operationen abbilden; xattrs, Rename, Löschen, große Dateien, viele Extents.
3. Eichung: Kernel-HFS als Richter (fsck_hfs -fn, ro-Mount, md5), Absturzproben (Modul während Schreiben beenden → Journal-Replay), 64-GiB-Dauerlast, fragmentierter Freiraum, Befehlsgrößen-Trace ≤ 524288.
4. Drobo: erst nur lesend über das Modul, dann Schreiben — je Schritt Betreiberwort, Metadatensicherung davor.

## Verworfen
- iSCSI/NBD-Initiator: ohne Kext/Entitlement auf macOS 26 nicht möglich (DTS-Thread 837879).
- livefiles über userfsd: private Entitlements → SIP/AMFI aus.
- Eigener HFS+-Treiber von Grund auf: Monate, kein Apple-Code.

## Erfolg
Drobo erscheint per Doppelklick als normales Volume im Finder, Schreiben/Lesen ≥ 200 MB/s, max. Schreibbefehl ≤ 524288 B, Kernel-fsck nach jeder Sitzung OK, ohne SIP-Änderung.

## Fortschreibung Phase 0a (2026-10-14T07:25:00+0200)
- Projekt `macos/fskit_probe/` (xcodegen, Host + FSKit-Extension `drobofsprobe`, Marker `DROBOFSPROBE`, Messung 2 GiB in 512-KiB-Stuecken ab 1 MiB) baut unsigniert (CODE_SIGNING_ALLOWED=NO: BUILD SUCCEEDED).
- Signing Entwicklung: scheitert an "Device 'MacBook Pro' isn't registered in your developer account" (UDID <UDID>). Registrierung = Kontoaenderung ausserhalb der Freigabe, wartet auf Betreiberwort.
- Antragspflicht-Frage: Archiv + `-exportArchive` (app-store-connect, Automatic) erzeugt ein "Mac Team Store Provisioning Profile" mit `com.apple.developer.fskit.fsmodule = true` ohne Antrag. Das Entitlement ist fuer das Team frei verfuegbar; nur das Entwicklungsprofil braucht das registrierte Geraet.
- Offen: Aktivierung durch Betreiber, `mount -F`, MB/s (Skript `macos/fskit_probe/tools/run_probe.sh`).

## Fortschreibung Phase 0a, Aktivierung (2026-10-14T08:00:00+0200)
- Dev-Signing nach Geraeteregistrierung OK: Profil enthaelt `com.apple.developer.fskit.fsmodule`, Release-Build ohne `get-task-allow` (CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO) aendert nichts: `mount -F` meldet weiter `Module de.begod.drobofsprobe.fsmodule is disabled!` (Text steht in /sbin/mount, Quelle: fskitd -> fskit_agent).
- Disassemblat FSKit (`dyld_info -disassemble`): `[FSModuleHost _updateProviderListForMatchingExtensionRecords:]` setzt `enabled = [_enabledModules containsObject:bundleID]` bei jeder LS-Aenderung; `_enabledModules` kommt aus `loadEnabledList` (Datei `~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist`). Der Agent (PID 1492 seit Oct 12) liest die Datei nur beim Start: Handeintrag wird nicht uebernommen.

## Umsetzungsstand Phase 0a (2026-10-14T08:05:00+0200, Orchestrator gemessen)
- Dev-Profil „Mac Team Provisioning Profile: de.begod.drobofsprobe.fsmodule“ mit fskit.fsmodule + Mac-UDID, ohne Apple-Antrag.
- Freischaltung: Settings-Schalter sprang zurück; Eintrag in ~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist (Betreiber) + Neustart → wirksam (Lehre L-6f678f).
- run_probe.sh am 4-GiB-Abbild: mount -F ok, Lesen 416,6 MB/s, Schreiben 4033,7 MB/s (gepuffert, kein Durchsatzwert), verify_bad 0. Abbruchkriterien „kein Profil“, „EACCES“, „< 200 MB/s“ widerlegt.
- Offen: Schreibdurchsatz ohne Puffer (an echtem Gerät), Phase 1 (livefiles_hfs-Bau) läuft.

## Phase 1: Ergebnis (fortgeschrieben 2026-10-14T08:34:53+0200)
- Gebaut: macos/Makefile → build/liblivefiles_hfs.a (arm64, Xcode 26.6/SDK 26.5) + build/lifs_cli. Apples Quellen unter macos/vendor/hfs-715.100.10/ (Lizenz siehe dort), bis auf einen Eingriff aus Phase 5a: lf_hfs_vnode.c:218 liest die unkomprimierte Größe des decmpfs-Headers jetzt als uint64_t statt uint32_t (Größen ab 4 GiB wurden abgeschnitten; Beleg: Eichung n_t7_size5g meldete 1073741824 statt 5368709120). Siehe macos/livefiles_shim/INVENTAR.md, Abschnitt Eingriffe in Apples Quellen. Kein Stub nötig; Shim = eigener UserFS/UserVFS.h + 3 Mini-Header (vnode, decmpfs, uuid/namespace) + lifs_devio.c. Inventar: macos/livefiles_shim/INVENTAR.md.
- I/O-Invariante: pwrite/ioctl von Apples Code werden per -D auf lifs_dev_pwrite/lifs_dev_ioctl umgeleitet; harte Kappung 524288 B, DKIOCGETMAXBYTECOUNTWRITE=524288. Beleg: make check-io (nm: kein anderes Objekt ruft libc-Schreibfunktionen; Rot-Probe mit Lecköbjekt schlägt an).
- Eichung: macos/eich.sh (Kernel als Richter: newfs_hfs/hdiutil/fsck_hfs -fn/ro- und rw-Mount): 79 PASS, 0 FAIL, jeweils mit Rot-Kontrolle (Bytekipper, Build ohne Kappung, nicht-journaled-Abbrüche).
- Befunde für Phase 2/3: (1) frisch formatiertes Abbild (lastMountedVersion != HFSJ) wird nach Abbruch zwischen Journal-Commit und Rückschreiben vom Replay ignoriert → fsck korrupt; Kernel schreibt die Version beim ersten rw-Mount sofort, livefiles journaled. Adapter muss sie vor dem ersten Journal-Schreiben direkt setzen. (2) Nach Unmount bleibt die letzte Transaktion im Journal (start≠end); ro-Kernel-Mount wird verweigert bis ein rw-Mount/Replay lief. (3) Allokation schreibt Nullen vor die Daten: Geräteverkehr ≈ 2× Nutzdaten.

## Phase 1: Nachtrag Pflichten (fortgeschrieben 2026-10-14T09:38:17+0200)
- lastMountedVersion: `lifs_prepare_volume` setzt 'HFSJ' vor dem Mount direkt (nur bei journaled, Journal leer oder "needs init"). Rot: eich.sh `befund` ohne Fix (LIFS_SKIP_PREPARE) korrupt, mit Fix fsck OK. Neu gefunden: frisch newfs'tes Journal hat Flag "needs init" (JIB-Bit 2), Journalkopf ist noch leer.
- Unmount: `lifs_unmount_clean` (sync, hfs_flush, journal_close, jnl=NULL, dann LFHFS_Unmount schreibt den Volume-Header direkt) → Journal start==end, Kernel-ro-Mount direkt nach Unmount möglich (vorher verweigert). eich.sh: 85 PASS, 0 FAIL.
- fsck-Spawn gesperrt: `-Dposix_spawn=lifs_blocked_spawn` (EPERM), `startCheck` im Modul ist leer; make check-io prüft zusätzlich posix_spawn/exec/system/popen/fork.
- Zero-Fill (Apples "KBZ: for now" in BlockAllocate): Messung Geräteverkehr/Nutzdaten 2,01 mit, 1,00 ohne. Ohne Nullen zeigen Dateilücken (Schreiben ab 128 MiB-Offset) Plattenreste (Belege eich.sh zerofill) → nicht pauschal entfernbar. **Grenze**: Schreibdurchsatz bei ~½ des Gerätedurchsatzes. Möglicher Ausbau: Nullen nur überspringen, wenn die Allokation vom Anhängen an das Dateiende kommt und die Metadaten-Allokation (B-Bäume) ausgenommen bleibt; ungetestet.

## Phase 2: FSKit-Adapter (fortgeschrieben 2026-10-14T09:38:17+0200)
- Modul wiederverwendet Bundle-ID de.begod.drobofsprobe.fsmodule (Freischaltung bleibt), Kurzname jetzt `hfsdrobo` (geprüft: FSKit lässt die Umstellung zu, aber fskit_agent muss danach neu starten, weil er Kurznamen im Speicher hält).
- Quellen: macos/fskit_probe/Module/{Extension,HFSFileSystem,HFSVolume,Backend,Gate}.swift + Bridge.h. Backend = FSBlockDeviceResource (read/write; keine metadata*-Aufrufe), lifs_devio.c besitzt die Kappung, Backend.swift die zweite: genau ein dev.write, nie > 524288, nie < Offset 1024, nie über das Geräteende. Abgebildet: lookup, getattr/setattr, readdir(+attr), read, write, create, mkdir, remove, rmdir, rename, symlink/readlink, link, xattr get/set/list, sync (+5-s-Timer), statfs, activate/deactivate (Mount in loadResource, sauberer Unmount in deactivate).
- Sperre (Probe-Phase): nimmt nur Geräte mit Marker "DROBOFSPROBE" in den Boot-Bytes UND ≤ 8 GiB UND HFS+/HFSX-Signatur. Beleg: tools/eich_fskit.sh sperre (ohne Marker und 9-GiB-Abbild abgelehnt). Drobo (64 TiB), CF-Karte, T7, Backup 1 erfüllen das nicht.
- Eichung tools/eich_fskit.sh (31 PASS, 0 FAIL): mount -F -t hfsdrobo am Abbild; cp 1 GiB, ditto 1000 Kleine, mv, rm, rmdir, mkdir, xattr, Symlink, Hardlink; umount; Kernel fsck_hfs -fn OK, Kernel-ro-Mount md5 gleich (J und NJ). Absturz: kill -9 des Modulprozesses mitten im Kopieren, 7 Zeitpunkte J und NJ: J 7/7 fsck OK nach Kernel-Replay (4 mit nicht leerem Journal); NJ 6/7 fsck rot (Kontrolle, dass die Prüfung scharf ist; erwartet ohne Journal).
- Durchsatz über den Mount am Abbild (Disk-Image-Treiber, gepuffert): Schreiben 223–516 MB/s (J), 386–460 (NJ); Lesen 551–693 (J), 563–668 (NJ). Geräteverkehr/Nutzdaten 2,00 (J) / 2,19 (NJ). Max. Schreibbefehl 524288 (Zähler in lifs_devio und in Backend.swift).
- Grenzen: (1) FSBlockDeviceResource kennt keinen Cache-Flush zum Medium (DKIOCSYNCHRONIZE wird auf metadataFlush abgebildet, der nur den Metadatenpuffer leert) – Journal-Reihenfolge am echten Gerät ungeprüft. (2) NJ-Volumes (Drobo derzeit ohne Journal) sind nach Modulabsturz meist fsck-pflichtig; Journal auf der Drobo einschalten ist Voraussetzung für Phase 4. (3) Finder-GUI, 64-GiB-Dauerlast, fragmentierter Freiraum, Stromausfall nicht geprüft. (4) fskit_agent streicht die Bundle-ID aus enabledModules.plist, sobald der Modul-Eintrag kurz aus der LaunchServices-Datenbank verschwindet (rm/ditto/lsregister -u); Update daher nur in place (tools/install_module.sh).

## Entscheidung 2026-10-14T12:15:00+0200 (Betreiber)
Weg A (DriverKit-Dext) gemessen blockiert: Kernel überschreibt kIOMaximumByteCountWrite nach UserDetermineDeviceCharacteristics mit dem USB-Protokollwert (Diagnose v1.4/5, Knoten 7113f33b). Keine weitere Apple-Anfrage. Betreiber, wörtlich: „wir hatten schon einmal eine anricht an apple geschick, las suns den weg ohne nehmen!“ → Weg B (FSKit + livefiles_hfs) ist der Hauptweg. Testtreiber bleibt bis zum Aufräumen aktiv (Kartenleser läuft normal darüber).

## Phase 3 (A): Härtetest über den FSKit-Mount (fortgeschrieben 2026-10-14T10:14:43+0200)
tools/hard_fskit.sh (nur Abbilder, Gate auf ≤ 24 GiB angehoben für das 20-GiB-Abbild; Marker bleibt Pflicht). 34 PASS, 0 FAIL, Kernel jeweils fsck_hfs -fn OK und ro-Mount md5 gleich:
- Dauerlast journaled: 16 × 4 GiB schreiben/md5/löschen (64 GiB), Schreiben Ø 204 MB/s (min 112), Lesen+md5 Ø 499 MB/s, kein md5-Fehler. Nicht journaled: 4 × 4 GiB, 108–155 MB/s schreiben. Geräteverkehr/Nutzdaten 2,00 / 2,02.
- Fragmentierung (J und NJ): 256-MiB-Volume mit ~29–30 k Dateien à 8 KiB gefüllt, jede zweite gelöscht, 100-MiB-Datei in die Lücken: 12 476 Extents in 1 560 Überlaufsätzen (Extents-Überlauf-B-Baum), md5 gleich, fsck OK, Datei samt allen Kleinen über den Mount gelöscht, fsck OK. Schreiben dabei 37 MB/s (J) bzw. 14 MB/s (NJ).
- Große Datei: 17 GiB (> 16 GiB, 18 253 611 008 B) auf 20-GiB-Abbild journaled, 411 MB/s schreiben, 400 MB/s lesen+md5, Kernel-ro-Mount md5 gleich.
- max. Geräte-Schreibbefehl in allen Läufen 524288. Speicher des Modulprozesses (alle 3 s protokolliert): RSS 12–57 MiB, kein Anstieg über 64 GiB Dauerlast (13–20 MiB, Viertelvergleich −2 MiB); die 57 MiB gehören zur Fragmentierung (30 k Einträge).

## Phase 3 (B): Journal einschalten ohne Kernel-rw-Mount (fortgeschrieben 2026-10-14T10:14:43+0200)
- Code-Suche vendor/hfs-715.100.10: Apples livefiles_hfs kennt nur journal_create beim Mount eines Volumes mit Flag "needs init"; Anlegen der Journal-Dateien gibt es nicht.
- Umsetzung lifs_glue.c lifs_enable_journal / lifs_cli enable-journal: .journal_info_block und .journal im Wurzelverzeichnis (Journal vorab zusammenhängend belegt, ein Extent), JIB InFS|NeedInit mit Ort/Größe, vcbJinfoBlock + Bit 0x2000, die LFHFS_Unmount in Haupt- und Alternativ-Header schreibt; Rückbau bei Fehler.
- Vergleich mit diskutil enableJournal am Klon desselben gefüllten Abbilds: Journal 8 MiB an derselben Stelle (Block 37484), JIB-Block 39532, 2048 Blöcke; Unterschiede: FileIDs (Kernel verbraucht eine), Finder-Info (hier newfs-Form jrnl/hfs+/0x5000, Kernel 0x0040), JIB-Flags 5 statt 1 und lastMountedVersion 10.0 statt HFSJ bis zum ersten Mount.
- Eichung (eich.sh enablejournal, 19 PASS): fsck vor jedem Mount OK, Kernel meldet "Journaled HFS+", md5 gleich, nach Absturzprobe (8 Punkte) Kernel-Replay fsck OK, zerstückelter Freiraum → ENOSPC mit Rückbau (Volume unverändert). Schreibbefehle ≤ 524288.
- Größe: Standard 8 MiB bis 16 GiB (gemessen = newfs/diskutil); darüber eigene Regel vol/8192, höchstens 512 MiB – Kernel-Formel nicht belegt, sparse Abbilder > freier Platz ließen sich nicht anlegen. Für die Drobo Größe ausdrücklich wählen. Voraussetzung: zusammenhängender freier Bereich dieser Größe.
- Regel seit 2026-10-14: install_module.sh fasst enabledModules.plist und fskit_agent nicht mehr an; fehlt die Freischaltung, Exit 3 und Meldung.

## Phase 4 Vorbereitung: Freigabeliste, nurlesen, Betreiberwerkzeug (fortgeschrieben 2026-10-14T10:28:11+0200)
- Gate: Marker-Testabbild wie bisher, ODER Eintrag in ~/Library/Containers/de.begod.drobofsprobe.fsmodule/Data/freigabe.json (Container des sandboxed Moduls, dort liest es via NSHomeDirectory()). Format [{"volume_uuid","modus":"nurlesen"|"schreiben","max_bytes"}]. Ungültige/fehlende Datei = nichts freigegeben. Geräte > max_bytes werden abgelehnt.
- Volume-UUID wie diskutil: MD5(kFSUUIDNamespaceSHA1 ‖ VH.finderInfo[24..31]) mit Version-3-Bits (lifs_volume_uuid, Quelle lf_hfs_volume_identifiers.c). Beleg: lifs_cli uuid == diskutil info am Abbild (9C671B2D-DB62-376F-B9AE-62589DE02422 beide); die Drobo-UUID C2E343A1-0D4C-3B35-B5DC-0325C1E1E1B1 ist Version 3 (MD5) wie erwartet.
- nurlesen: drei Sperren: (1) Modul meldet dem Kernel read-only (requestedMountOptions, macOS 26.4+; mount zeigt "read-only" mit und ohne -o rdonly), (2) alle Schreiboperationen des Moduls liefern EROFS und zählen (ro_blockiert), (3) Backend.write verweigert hart und zählt Versuche (dev_schreibversuche); lifs mountet read-only (kein lastMountedVersion-Schreiben). Journal nicht leer (lifs_journal_dirty) oder unlesbar → Mount abgelehnt.
- Eichung tools/eich_fskit.sh freigabe (72 PASS) und alles (105 PASS, 0 FAIL): ohne Eintrag, fremde UUID, Gerät > max_bytes, kaputte Liste → abgelehnt; mit Eintrag nurlesen: Lesen md5 gleich, cp/touch/mkdir/rm/xattr -w/mv/ln -s/truncate scheitern (J und NJ), Abbild-SHA256 vorher == nachher, dev_writes=0, dev_schreibversuche=0, ro=1; Journal nicht leer → abgelehnt, SHA unverändert, Kontrolle: nach Kernel-Replay wird derselbe Eintrag angenommen. Prüfbau (XC_EXTRA='SWIFT_ACTIVE_COMPILATION_CONDITIONS=TEST_MOUNT_RW' install_module.sh, danach wieder normal installiert) lässt Schreibzugriffe die Modul-Sperren erreichen: 10 Versuche → ro_blockiert=10, Backend-Zähler 0 (tools/eich_fskit.sh freigabe-modul, 14 PASS). Grenze: Die Backend-Sperre (3) wurde nur per Code, nicht per auslösendem Versuch geprüft – das Modul hat keinen Pfad, der sie erreicht.
- tools/drobo_lesen.sh (Betreiber; am Abbild mit DROBO_UUID/DEV/LISTE/MNT geprüft, die Drobo wurde nicht berührt): findet das Volume per UUID, prüft nicht eingehängt / keine QEMU / VH 0x100 gesetzt, 0x800 und 0x4000 nicht / Journal leer, Freigabeeintrag (--freigabe-anlegen), Wirt-SHA (VH, erstes, letztes MiB) vor und nach dem Mount, mount -F -t hfsdrobo -o rdonly, Leseliste (sha256 der ersten 256 MiB, MB/s je Datei und gesamt), umount, Schreibzähler aus dem Modul-Log. Negativproben am Abbild: falscher Hash → Exit 7, falsche UUID/eingehängt/Journal nicht leer → STOP.

## Phase 4 Ergebnis: erster Lesetest an der Drobo (fortgeschrieben 2026-10-14T11:04:23+0200)
- drobo_lesen.sh, nurlesen, Leseliste 16/16 OK, 128,2 MB/s (je Datei 61–171), Wirt-SHA gleich, dev_writes=0, dev_schreibversuche=0. Erster Lauf meldete FEHLER durch Skriptfehler (TotalSize im Mount = Volume-Größe, L-92654b; umount busy → diskutil unmount), behoben 471c6e674.

## Phase 5 Plan: Lesedurchsatz Modul ≥ 200 MB/s an der Drobo (2026-10-14T11:04:23+0200)
**Ist (gemessen):** Modul an der Drobo 128 MB/s; Mac-Kernel direkt an der Drobo 205–230 MB/s (1-MiB-Befehle, PLAN_LINUX_VM); Modul am Abbild 400–690 MB/s. Engpass liegt also an der Kombination Modul × Gerätelatenz, nicht an der Drobo allein.
**Bau heute:** HFSVolume.read → `locked{}` (ein globaler libLock) → fsops_read → lifs_dev_pread → Backend.read (eigener NSLock, synchron, ≤ 1 MiB je dev.read, Bounce-Puffer). Kein Vorauslesen, Warteschlangentiefe 1.
**Schritt 1 Messen (kein Umbau):** Zähler im Backend für Leseaufrufe (Anzahl, Bytes, Größenverteilung, Zeit in dev.read, gleichzeitig wartende FSKit-Lesungen). Messgerät mit echter USB-Latenz: CF-Karte „old“ (darf gelöscht werden), Vergleich Kernel-ro-Mount vs Modul am selben HFS+-Inhalt. Gegenprobe Abbild.
**Hebel (Reihenfolge nach Messung, nicht vorab):**
- A Vorauslesen im Backend bei sequentiellem Muster (nächste N MiB asynchron, nur Lesen; Schreibpfad unberührt, Kappung 524288 bleibt).
- B Lesungen parallel zulassen (libLock nur um Metadaten, Datenblock-Lesen außerhalb) — nur, wenn livefiles fsops_read das trägt; sonst verworfen.
- C FSKit Kernel-Offload-IO (Kernel liest direkt per Extent-Abbildung): nur für nurlesen denkbar, weil der Kernel beim Schreiben 1-MiB-Befehle schickt (Drobo-Grenze). Zweiter Codepfad → nur, wenn A/B nicht reichen.
**Erfolg:** Leseliste an der Drobo ≥ 200 MB/s gesamt, 16/16 OK, Schreibzähler 0; Eichung 105/105 und Härtetest unverändert grün.
**Nicht getan:** Schreibdurchsatz an der Drobo (braucht eigenes Wort), Drobo-Firmware/-Einstellungen.

### Phase 5 Schritt 1 Ergebnis (2026-10-14T11:50:00+0200, Commit b0729d532)
- Abbild, Modul nurlesen, 1 GiB sequentiell: dev_reads 1035, davon 1024 zu 1 MiB; dev_read_ms 893–2234, lock_wait_ms 6327–15571, max_wartend=14. FSKit schickt bis zu 14 Lesungen gleichzeitig, der libLock reiht sie hintereinander. Die Wartezeit am Lock ist 7× die Gerätezeit.
- Bei einer Latenz wie an der Drobo (≈ 8 ms je MiB, 128 MB/s seriell) ist Warteschlangentiefe 1 die Obergrenze. Der Kernel liest dort 205–230 MB/s mit mehreren offenen Befehlen.
- CF-Karte „old“ taugt nicht als Latenz-Ersatz: Leser hängt mit 480 Mb/s (USB 2), roh 34 MB/s. Ersatz: künstliche Verzögerung je dev.read im Prüfbau (Zustand herstellen statt Gerät suchen).
- Nebenbefund behoben: eich_fskit.sh löschte die Betreiber-Freigabeliste (a4b86d19b).

### Phase 5 Entscheidung: Hebel B zuerst
- B: Unter libLock nur die Zuordnung Datei-Offset → Geräte-Offset (hfs_vnop_blockmap über neue Glue-Funktion), das Lesen vom Gerät danach außerhalb des Locks, parallel, mit eigenem Puffer je Aufruf. Fallback auf fsops_read bei allem, was keine einfache Zuordnung hat (komprimierte Dateien, Lücken, Fehler, Schreibmodus).
- Begründung: nutzt die 14-fache Parallelität, die FSKit schon liefert. Kein Cache, keine Vorhersage. Das Muster trägt später auch den Schreibpfad. Falsifizierbar mit einer Messung: Prüfbau mit 8 ms Verzögerung je dev.read, seriell ≈ 125 MB/s, mit B deutlich darüber oder nicht.
- A (Vorauslesen) verworfen, solange B reicht: zweiter Zustand (Cache) mit Kohärenzfrage beim Schreiben. C (Kernel-Offload) verworfen, solange B reicht: nur für nurlesen tragfähig, zweiter Volume-Codepfad.
- Zunächst nur im Modus nurlesen aktiv. Für den Schreibmodus erst nach eigener Prüfung der Kohärenz mit livefiles-Puffern.

### Phase 5 Schritt 2 Ergebnis (2026-10-14T13:05:00+0200, Commits 45eb3d7e4, 3df1206c9)
- Hebel B gebaut (lifs_map_read unter libLock, readDirect außerhalb, nur nurlesen). Prüfbau 8 ms je dev.read: alt 87–98 MB/s, neu 1034–1053 MB/s, max_dev_read_parallel=14. Eichung 105/105, Härtetest 34/34. An der Drobo noch nicht gemessen.
- BEFUND (vorbestehend, nicht durch B): HFS-komprimierte Dateien (UF_COMPRESSED, decmpfs) liest das Modul falsch, ohne Fehler und mit wechselndem Inhalt je Lauf. livefiles_hfs hat keine decmpfs-Leseunterstützung (vendor: nur Flag-Weitergabe in lf_hfs_vnode.c:175).
- Betroffen auf der Drobo (gemessen offline an der Katalog- und Attributsicherung vom 2026-10-13): 849 komprimierte Dateien, alle LZVN: Typ 8 (Ressourcengabel) 828 Dateien / 839,7 MB, Typ 7 (im xattr) 21 Dateien / 0,44 MB. Andere Typen: 0.

### Phase 5a: decmpfs lesen (vor jeder Nutzung des Moduls an der Drobo)
- LZVN Typ 7/8 entpacken über Compression.framework (Rohdaten in 'bvxn'-Rahmen, Dekodierer COMPRESSION_LZFSE), kein neuer Fremdcode. Erstes Byte 0x06 je Block = unkomprimiert gespeichert. Typ 8: Offsettabelle am Anfang der Ressourcengabel, Blöcke zu 64 KiB.
- Jeder andere Typ und jeder Dekodierfehler → EIO. Nie falsche Bytes ausliefern.
- Abnahme: Kernel ist das Orakel. Am Abbild per Kernel-rw Testdateien vom Typ 7 und 8 erzeugen (xattr com.apple.decmpfs + Ressourcengabel + chflags compressed), md5 Kernel-ro == Modul. Negativprobe: kaputte Offsettabelle bzw. unbekannter Typ → EIO statt Daten. Rot vorher: heutiger Stand liefert falschen md5.

### Phase 5 Lauf an der Drobo mit Hebel B (2026-10-14T14:55:00+0200)
- drobo_lesen.sh, Normalbau: Leseliste 16/16 OK, aber 113,8 MB/s (vorher 128). Wirt-SHA gleich, Schreibzähler 0. GEOM: alle Blockgrößen 512, hfsPlusIOPosOffset=0.
- STATS-LESEN: vol_reads=4481, dev_reads=16564, davon 11956 ≤ 128 KiB (≈ 98 MB, im Mittel ≈ 8 KiB, also Metadaten), 4608 zu 1 MiB (4,83 GB für 4,29 GB Nutzdaten, ≈ 12 % zu viel gelesen), lock_wait_ms=94665, max_dev_read_parallel=14.
- decmpfs-Vergleich an der Drobo nicht möglich: Kernel UND Modul bekommen EPERM für alle 51 Dateien unter /.Spotlight-V100 (macOS sperrt den Pfad). Alle 849 komprimierten Dateien liegen dort, also keine Nutzerdatei betroffen.
- Rohmessung Drobo (/dev/rdisk7s2, nur lesend, je 768 MiB): 1 MiB qd1 214–224 MB/s, qd4 226, qd14 232; 512 KiB qd14 193; 128 KiB qd14 123. 8 KiB sequentiell 0,57 ms je Befehl; 8 KiB zufällig 35 ms; 1 MiB nach Sprung 41 ms.
- **Hypothese aus Schritt 1 widerlegt:** Parallelität bringt der Drobo nichts, sie arbeitet Befehle nacheinander ab. Was zählt, sind große Befehle und keine Sprünge. Der Prüfbau mit festen 8 ms je Befehl (unabhängig von Größe und Position) hat genau das nicht abgebildet, deshalb sah B dort zehnfach schneller aus (Prüfstand misst mit, L-0e0ab6).

### Phase 5d: Metadaten-Sprünge aus dem Datenstrom nehmen
- Prüfbau-Modell neu, an den Rohwerten geeicht: ein Gerät, das Befehle nacheinander abarbeitet; Zeit je Befehl 0,54 ms + Größe / 253 MB/s, dazu 35 ms, wenn der Befehl nicht im Umkreis von 1 MiB um das Ende des vorigen beginnt. Kontrolle: Rohlesen 1 MiB qd1 im Modell ≈ 224 MB/s, 128 KiB ≈ 123 MB/s.
- Erst messen: Herkunft der ≤ 128 KiB-Lesungen (Offset gegen Lage von Katalog, Extents-Überlaufbaum, Attributbaum) und der 12 % Mehrlesung.
- Dann: Extents-Liste einer Datei beim ersten Lesen vollständig holen und je Datei zwischenspeichern (nurlesen: unveränderlich), damit beim Streamen keine Baumlesungen mehr anfallen. Datenlesungen auf Gerätebefehle ≥ 1 MiB in Dateireihenfolge bringen.
- Erfolg: im neuen Prüfbau ≥ 200 MB/s, an der Drobo ≥ 200 MB/s gesamt in der Leseliste, Schreibzähler 0.

### Phase 5e Ergebnis (2026-10-15T08:00:00+0200, Commits c38bbc964, 6c76efeec, 8a32aecf5)
- Am Abbild mit Katalog-Baumtiefe 4: Katalog-Lesungen kommen NICHT aus dem Lesepfad (dd über 1 GiB: katalog=34). Aufrufweg der Stichprobe: hfs_readdirattr_internal → cat_getentriesattr → BTIterateRecords → GetNode (Verzeichnisauflistung) plus Lookups, d. h. ein FREMDER Prozess, der das Volume parallel durchläuft. Idle-Mount ohne Fremdzugriff: katalog=0.
- Prüfbau TEST_DROBO mit `find -ls` parallel: B 39–41 MB/s; mit Baumfenster 4 MiB 72–74 MB/s; ohne Fremdzugriff 130–139 MB/s. Eichung 323/323, Härtetest 28/28 + gross 8/8.
- Folgerung: An der Drobo durchsucht während des Tests ein anderer Prozess das Volume (auch mit nobrowse, dort sogar mehr). lsof ohne sudo sieht Prozesse anderer Benutzer nicht (deshalb war es zuvor leer). Nächster Schritt: Prozess per `sudo fs_usage` während eines Laufs benennen.

### Phase 5f Drobo-Läufe (2026-10-15T08:30:00+0200)
- Knotencache 64 MiB (9fd1504cc): Leseliste 134,4 / 129,9 MB/s (vorher 99–128). katalog 2890/2735 Lesungen (vorher 12k–26k), anfragen=6634 eindeutig=2892. Fremder rekursiver Durchlauf ab Wurzel (ENUM dir=2 …, ~40k Einträge je Lauf), Verursacher nicht benannt (Spotlight meldet "unknown indexing state", Prozessstichprobe ohne Befund).
- Vergleich Kernel-ro-Mount, dieselbe Leseliste: 191,6 MB/s (16/16 OK). Ziel damit: Gleichstand mit dem Kernel; 200 MB/s erreicht auch der Kernel auf dieser Liste nicht (zerstückelte Dateien).
- Roh: 1 MiB in Reihenfolge 190–209 MB/s, in 14er-Fenstern gemischt 194–195 → Reihenfolge der parallelen Anfragen unerheblich.
- STATS-LESEN Lauf 8: lock_wait_ms=73654 in 33 s, max_wartend=13. Datenlesungen warten am libLock, den der fremde readdir für Katalogleseungen (Sprünge) hält.
### Phase 5g: Lagecache je Datei
- Beim ersten Lesen einer Datei (nurlesen) die vollständige Extent-Liste unter libLock holen, je Datei-ID zwischenspeichern; danach HFSVolume.read ohne libLock (nur Cache-Lookup + readDirect). Ziel: lock_wait ≈ 0 bei Fremddurchlauf, Drobo-Leseliste ≈ Kernel (≥ 185 MB/s).

### Phase 5g/5h Drobo-Läufe: Verursacher gefunden (2026-10-15T09:25:00+0200)
- Lagecache (b9010a09c), Mount unter ~/drobo_lesen_mnt: 133,5 MB/s, lock_wait 74 s → 12 s, katalog 3449.
- Leerlauf-Mount 90 s unter ~/drobo_lesen_mnt, ohne Lesen: Enum eintraege=766034, katalog=49438 (395 MB) → fremder rekursiver Durchlauf ab Einhängen.
- Gleicher Leerlauf unter /private/tmp/drobo_mnt_probe: eintraege=0, readdir=0, katalog=5. Verursacher: Spotlight-Indexierung des Benutzerordners (mds getattrlistbulk 23839 in sudo fs_usage), läuft in einen Mount unter $HOME hinein.
- Leseliste mit MNT=/private/tmp/drobo_lesen_mnt: **173,1 MB/s** (16/16, Wirt-SHA gleich, Schreibzähler 0, katalog=51). Kernel-ro dieselbe Liste 191,6 MB/s.
- drobo_lesen.sh: Vorgabe-MNT jetzt /private/tmp/drobo_lesen_mnt. Für den späteren Finder-Betrieb: Einhängeort außerhalb von $HOME (z. B. /Volumes über diskarbitration) und Verhalten von Spotlight dort eigens messen.
- Offen: Rest-Abstand 173 vs 192 (lock_wait noch 11 s ohne Fremdzugriff; 12 % Vorauslesen über 256 MiB hinaus betrifft beide gleich).

### Phase 5i Drobo-Lauf (2026-10-15T12:10:00+0200, Stand f7beff0a9)
- Leseliste 16/16, **183,7 MB/s** (Kernel-ro dieselbe Liste 191,6 → 96 %), Wirt-SHA gleich, Schreibzähler 0. Verlauf: 128 (Start) → 114 (B) → 134 (Knotencache) → 173 (Mount außerhalb $HOME) → 184 (Stücke nicht verschränken).
- STATS-LOCK: map_all=92/w7211/h1404 getattr=4519/w10047/h4 lookup=67/h1198. Restwartezeit stammt aus der Erstzuordnung (map_all) je Datei, die unter libLock Extents-Knoten liest.
- Phase 5 (Lesen) damit abgeschlossen: Rest-Abstand 4 % zum Kernel, kein offener Fehler. Nächste Phasen: Finder-Betrieb unter /Volumes inkl. Spotlight-Verhalten, dann Schreiben (eigenes Wort, Sicherung vorher, Journal-Frage).

### Phase 6 Schreibtest 1 an der Drobo (2026-10-15T15:40:00+0200, bb9207535)
- 21/21 zurückgelesen, max_cmd 524288, --nur-pruefen nachher OK (Zähler == Sätze, Gefahr 0, Leck 0). Zählergate hielt an: −272 Dateien/−1 Ordner/+825 MB frei. Katalogvergleich (CNID-Diff gegen Sicherung 14:52): nur /.Spotlight-V100/Store-V2 (374 weg, 104 neu), /.fseventsd neu, /.DS_Store weg; 0 Nutzereinträge geändert (L-bfafe2).
- fsck_hfs -n danach: "Missing thread record (id = 6014985)", "could not be verified completely" (rc 8). Ordner 6014985 ('5343', Eltern 5991127) samt Thread-Satz (3, 5991127, '5343') steht IDENTISCH in der Sicherung vom 2026-10-13 10:45 (vor allen VM-/Modul-Schreibtests) und heute; B-Baum-Suche nach (6014985,"") findet den Thread als letzten Satz von Blatt 258307, fLink/bLink zu 258311 stimmig. Befund also älter als die Schreibtests; Ursache der fsck-Meldung ungeklärt.
- Folge: keine weiteren Schreibtests, bis die fsck-Meldung verstanden ist.

### Phase 6 fsck-Klärung (2026-10-15T16:25:25+0200)
- fsck aus Apples Quellen (hfs-715.100.10, Prüfcode laut GitHub-Vergleich identisch mit 715.120.4) instrumentiert, nur O_RDONLY, Schreibwege blockiert: Katalogprüfung OHNE Befund (dirCount=dirThreads=538137, fileCount=fileThreads=2586931, missingThreadList leer; Thread 6014985 setzt gCIS.parentID vor Blatt 258311). Abbruch erst im Attribut-Baum: ENOMEM aus cache.c:1485 (LRUEvict, LRU leer) → Werkzeuggrenze, kein Volumebefund. "Missing thread record" des System-fsck ist mit der Quelle nicht reproduzierbar, Ursache offen.
- -1317 = cdUnrepairableErr (Scavenger.h:255).
- Wichtig: System-fsck_hfs öffnet das Gerät auch mit -n per O_RDWR|O_EXLOCK (fsck_hfs.c:513); -n setzt nur repairLevel=kNeverRepair. Künftige Prüfläufe nur mit dem O_RDONLY-Quellbau.
- Vorfall: Der Prüfagent hat beim Versuch, den System-fsck zu umhüllen, /dev/rdisk7s2 ~20 s O_RDWR geöffnet (lsof 3u) und den Prozess beendet; keine Schreibaufrufe (-n). Verstoß gegen den Auftrag, gemeldet.
- Nachtrag 2026-10-15T16:54:34+0200: Quell-fsck (O_RDONLY, lsof 3r) mit Diagnose-Verdrängung im Cache läuft vollständig: "The volume Drobo 2018a appears to be OK." (430 s; Extents, Katalog dir/threads 538137/538137, files/threads 2586931/2586931, Hierarchie, Attribute, Bitmap, Volume-Info). Der ENOMEM war ein Werkzeugfehler: Cache auf 3 GiB gedeckelt (cache.h:53, 32-Bit), LRU-Eintrag neuer Blöcke auskommentiert (cache.c:1272) → nie verdrängbar; aktivierte LRU stürzt ab (LRURemove cache.c:1517-1524). Volume damit geprüft OK; System-fsck-Meldung "Missing thread record" bleibt unerklärt und nicht reproduzierbar. Werkzeug + Diffs: /Volumes/daten/xcode/drobo/fsckbau.
