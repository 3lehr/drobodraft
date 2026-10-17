import Foundation

/// Neueinrichtung einer iSCSI-LUN (DroboPro, Testgeraet): GPT mit EINER HFS+-Partition (ohne Journal, Drobo-Linie).
/// HFS+ entsteht per newfs_hfs auf einer lokalen Sparse-Datei in Partitionsgroesse (nur Abbild, per hdiutil), danach gehen nur
/// Volume-Header, Ersatz-Header und alle laut Allocation-Bitmap belegten Bloecke per iSCSI auf die LUN, zuletzt die GPT. Danach Rueckleseprobe.
/// Nur LUN 1 (LUN 0 ist gesperrt), ohne `ausfuehren` Trockenlauf (schreibt nichts, legt kein Abbild an).
public struct FormatPlan {
    public var lun: Int, plattenBloecke: UInt64, partition: GPT.Partition, name: String
    public var text: String { "LUN \(lun): \(plattenBloecke) sectors; HFS+ partition LBA \(partition.ersterLBA)...\(partition.letzterLBA) (\(partition.bloecke * 512) bytes), volume name '\(name)', no journal" }
}

public func iscsiFormat(host: String, port: UInt16 = 3260, ziel: String? = nil, lun: Int, name: String, partitionBytes: UInt64? = nil, ausfuehren zuschreiben: Bool,
                        arbeitsordner: String, eingehaengt: (Int) -> Bool = { netzEinhaengung(lun: $0) != nil }, meldung: (String) -> Void) throws {
    // Jede LUN der DroboPro (Testgeraet, Betreiber 2026-10-17) darf formatiert werden - nie eine eingehaengte: der Kernel haelt dann Metadaten im Cache.
    guard lun >= 0 else { throw ISCSIFehler.verboten("iscsi-format: invalid LUN \(lun)") }
    guard !eingehaengt(lun) else { throw ISCSIFehler.verboten("iscsi-format: LUN \(lun) is mounted, unmount it first") }
    guard !name.isEmpty, !name.contains(":"), name.utf8.count <= 27 else { throw ISCSIFehler.verboten("volume name empty, longer than 27 bytes or containing ':'") }
    let d = try ISCSISitzung(host: host, port: port); let ziele = try d.ziele(); d.abmelden()
    guard let z = ziel ?? ziele.first?.name else { throw ISCSIFehler.protokoll("target offers no name") }
    let s = try ISCSISitzung(host: host, port: port, ziel: z, zeitgrenze: 60)
    defer { s.abmelden() }
    guard try s.lunListe().contains(lun) else { throw ISCSIFehler.protokoll("target has no LUN \(lun)") }
    let k = try s.kapazitaet(lun: lun)
    guard k.blockgroesse == 512, k.bloecke > 4096 else { throw ISCSIFehler.protokoll("unsupported LUN geometry \(k)") }
    let erster: UInt64 = 2048, letzterNutzbar = k.bloecke - 34
    var bloecke = (letzterNutzbar - erster + 1) / 8 * 8
    if let p = partitionBytes { bloecke = min(bloecke, p / 4096 * 8) }
    let plan = FormatPlan(lun: lun, plattenBloecke: k.bloecke, partition: GPT.Partition(ersterLBA: erster, letzterLBA: erster + bloecke - 1), name: name)
    let alt = try s.lesen(lun: lun, lba: 0, bloecke: 8)
    meldung("current first 8 sectors: allzero=\(alt.allSatisfy { $0 == 0 }) gpt=\(alt[512..<520].elementsEqual(Array("EFI PART".utf8)))")
    meldung("plan: " + plan.text)
    guard zuschreiben else { meldung("dry run, nothing written. Add --execute to write."); return }

    var st = statfs()
    guard statfs(arbeitsordner, &st) == 0 else { throw ISCSIFehler.verboten("work folder \(arbeitsordner) not accessible") }
    let frei = UInt64(st.f_bavail) * UInt64(st.f_bsize)
    guard frei >= 20 << 30 else { throw ISCSIFehler.verboten("work folder has only \(frei >> 20) MiB free, need at least 20 GiB; nothing created") }
    let dir = arbeitsordner + "/iscsi-format-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let pbytes = plan.partition.bloecke * 512
    // Sparsebundle (Einheit b = 512-B-Sektoren): Baender wachsen nur beim Schreiben (die Arbeitsplatte ist HFS+ und kennt keine Sparse-Dateien). Gelesen wird ueber das angehaengte Geraet.
    let (rc, out) = ausfuehren("/usr/bin/hdiutil", ["create", "-type", "SPARSEBUNDLE", "-size", "\(plan.partition.bloecke)b", "-layout", "NONE", dir + "/part"])
    guard rc == 0 else { throw ISCSIFehler.protokoll("hdiutil create failed: \(out)") }
    let dev = try anhaengenUndNewfs(dir + "/part.sparsebundle", name: name, meldung: meldung)
    defer { ausfuehren("/usr/bin/hdiutil", ["detach", dev, "-force"]) }
    let fd = open("/dev/r" + dev.dropFirst(5), O_RDONLY); guard fd >= 0 else { throw ISCSIFehler.protokoll("cannot open \(dev): \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    let laeufe = try belegteBereiche(fd: fd, partitionsBytes: pbytes)
    let summe = laeufe.reduce(UInt64(0)) { $0 + ($1.1 - $1.0) }
    meldung("HFS+ image ready: \(laeufe.count) used runs, \(summe) bytes to write")

    func lesenQuelle(_ von: UInt64, _ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n); let got = pread(fd, &b, n, off_t(von)); precondition(got == n, "short read of source image"); return b
    }
    let schritt: UInt64 = 8 << 20
    for (a, e) in laeufe {
        var p = a
        while p < e { let n = Int(min(schritt, e - p)); try s.schreiben(lun: lun, lba: erster + p / 512, daten: lesenQuelle(p, n)); p += UInt64(n) }
    }
    let gpt = GPT.bauen(plattenBloecke: k.bloecke, partition: plan.partition, plattenGUID: (0..<16).map { _ in UInt8.random(in: 0...255) },
                        partitionsGUID: (0..<16).map { _ in UInt8.random(in: 0...255) }, name: name)
    try s.schreiben(lun: lun, lba: k.bloecke - 33, daten: gpt.sicherung)     // zuerst die Sicherung, dann die Primaere: ein Abbruch dazwischen laesst keine gueltige Mischung
    try s.schreiben(lun: lun, lba: 0, daten: gpt.primaer)
    meldung("written, reading back ...")
    var geprueft: UInt64 = 0
    for (a, e) in laeufe {
        var p = a
        while p < e {
            let n = Int(min(schritt, e - p))
            guard try s.lesen(lun: lun, lba: erster + p / 512, bloecke: n / 512) == lesenQuelle(p, n) else { throw ISCSIFehler.protokoll("verify failed at partition offset \(p)") }
            p += UInt64(n)
        }
        geprueft += e - a
    }
    guard try s.lesen(lun: lun, lba: 0, bloecke: 34) == gpt.primaer, try s.lesen(lun: lun, lba: k.bloecke - 33, bloecke: 33) == gpt.sicherung else { throw ISCSIFehler.protokoll("verify failed (GPT)") }
    let teil = try GPT.ersteHFS { try s.lesen(lun: lun, lba: $0, bloecke: $1) }
    guard teil == plan.partition else { throw ISCSIFehler.protokoll("GPT read back: \(String(describing: teil))") }
    meldung("verified: \(geprueft) bytes of HFS+ metadata and both GPTs read back equal; partition \(plan.partition.ersterLBA)...\(plan.partition.letzterLBA)")
}

/// Haengt das Abbild an und formatiert mit newfs_hfs (ohne -J): nur Disk-Image-Geraete, sonst Abbruch (detach). Gibt das Geraet (/dev/diskN) angehaengt zurueck.
func anhaengenUndNewfs(_ img: String, name: String, meldung: (String) -> Void) throws -> String {
    let (rc, out) = ausfuehren("/usr/bin/hdiutil", ["attach", "-nomount", img])
    guard rc == 0, let dev = out.split(separator: "\n").first?.split(separator: " ").first.map(String.init), dev.hasPrefix("/dev/disk") else { throw ISCSIFehler.protokoll("hdiutil attach failed: \(out)") }
    var ok = false
    defer { if !ok { ausfuehren("/usr/bin/hdiutil", ["detach", dev, "-force"]) } }
    let (_, info) = ausfuehren("/usr/sbin/diskutil", ["info", dev])
    guard info.range(of: #"Virtual: +Yes"#, options: .regularExpression) != nil, info.range(of: #"Protocol: +Disk Image"#, options: .regularExpression) != nil else {
        throw ISCSIFehler.verboten("\(dev) is not a disk-image device, refusing newfs_hfs")
    }
    let (r2, o2) = ausfuehren("/sbin/newfs_hfs", ["-v", name, "/dev/r" + dev.dropFirst(5)])
    guard r2 == 0 else { throw ISCSIFehler.protokoll("newfs_hfs failed: \(o2)") }
    meldung("newfs_hfs ok on the local image (\(dev))")
    ok = true
    return dev
}

/// Belegte Bereiche (Byte von, bis; relativ zur Partition, aufsteigend, verschmolzen) laut Allocation-Bitmap, dazu Boot-/Header-Bytes und Ersatz-Header.
func belegteBereiche(fd: Int32, partitionsBytes: UInt64) throws -> [(UInt64, UInt64)] {
    // Roh-Geraet: nur sektorgenaue Lesungen (512 B), sonst EINVAL -> hier auf Sektoren erweitert, zu kurze/fehlgeschlagene Lesung bricht ab (nie stille Nullen).
    func lies(_ von: UInt64, _ n: Int) -> [UInt8] {
        let a = von / 512 * 512, l = Int((von + UInt64(n) + 511) / 512 * 512 - a)
        var b = [UInt8](repeating: 0, count: l); let got = pread(fd, &b, l, off_t(a))
        precondition(got == l, "read of the local HFS+ image failed (\(got), errno \(errno))")
        return Array(b[Int(von - a)..<Int(von - a) + n])
    }
    let vh = lies(1024, 512)
    guard vh[0] == 0x48, vh[1] == 0x2B || vh[1] == 0x58 else { throw ISCSIFehler.protokoll("image has no HFS+ volume header") }
    let bs = UInt64(be32(vh, 40)), total = UInt64(be32(vh, 44))
    guard bs >= 512, bs % 512 == 0, total > 0, total * bs <= partitionsBytes else { throw ISCSIFehler.protokoll("implausible HFS+ geometry \(bs) x \(total)") }
    let bitmapBytes = (total + 7) / 8
    var ex: [(UInt64, UInt64)] = []; var gedeckt: UInt64 = 0
    for i in 0..<8 { let (st, n) = (UInt64(be32(vh, 128 + 8 * i)), UInt64(be32(vh, 132 + 8 * i))); if n > 0 { ex.append((st, n)); gedeckt += n * bs } }
    guard gedeckt >= bitmapBytes else { throw ISCSIFehler.protokoll("allocation file has more than 8 extents; not supported") }
    var laeufe: [(UInt64, UInt64)] = [(0, 2048), (partitionsBytes - 2048, partitionsBytes)]
    var lauf: UInt64? = nil, block: UInt64 = 0
    func schliessen(_ ende: UInt64) { if let a = lauf { laeufe.append((a * bs, ende * bs)); lauf = nil } }
    var rest = bitmapBytes
    for (st, n) in ex {
        var off: UInt64 = 0
        while off < n * bs && rest > 0 {
            let m = Int(min(UInt64(1 << 20), min(n * bs - off, rest)))
            for byte in lies(st * bs + off, m) {
                if byte == 0 { schliessen(block) } else if byte == 0xFF { if lauf == nil { lauf = block } }
                else { for bit in 0..<8 { if byte & (0x80 >> UInt8(bit)) != 0 { if lauf == nil { lauf = block + UInt64(bit) } } else { schliessen(block + UInt64(bit)) } } }
                block += 8
            }
            off += UInt64(m); rest -= UInt64(m)
        }
    }
    schliessen(min(block, total))
    laeufe = laeufe.map { ($0.0, min($0.1, min(partitionsBytes, max(total * bs, $0.1)))) }.filter { $0.0 < $0.1 }.sorted { $0.0 < $1.0 }
    var aus: [(UInt64, UInt64)] = []
    for l in laeufe { if let l0 = aus.last, l.0 <= l0.1 { aus[aus.count - 1].1 = max(l0.1, l.1) } else { aus.append(l) } }
    return aus
}
