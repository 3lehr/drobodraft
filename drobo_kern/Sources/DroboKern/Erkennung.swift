import DiskArbitration
import Foundation

public struct ErkannteDrobo: Equatable {
    public var uuid: String          // Volume-UUID
    public var name: String          // Volumename
    public var bsd: String
    public var groesse: UInt64
    public var modell: String
}

/// Findet angeschlossene Volumes auf Geraeten mit dem SCSI-Hersteller `vendor` (Vorgabe "Drobo", Vergleich ohne Gross-/Kleinschreibung, Teilstring).
/// Nur Beschreibung ueber DiskArbitration; oeffnet kein Geraet. `vendor` ist austauschbar, damit der Test an einem Abbild laeuft.
public func erkenneDrobos(vendor: String = "Drobo") -> [ErkannteDrobo] {
    guard let sess = DASessionCreate(kCFAllocatorDefault), let namen = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return [] }
    var out: [ErkannteDrobo] = []
    for name in namen.sorted() where name.range(of: #"^disk[0-9]+(s[0-9]+)?$"#, options: .regularExpression) != nil {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, sess, name), let d = DADiskCopyDescription(disk) as? [String: Any],
              let cu = d[kDADiskDescriptionVolumeUUIDKey as String] else { continue }
        let v = (d[kDADiskDescriptionDeviceVendorKey as String] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !vendor.isEmpty, v.range(of: vendor, options: .caseInsensitive) != nil else { continue }
        // kein EFI-Systemvolume und keine fremden Dateisysteme (FAT/exFAT/NTFS); unausgehaengte HFS+-Volumes liefern oft keine Dateisystemart
        let inhalt = (d[kDADiskDescriptionMediaContentKey as String] as? String ?? "").uppercased()
        let art = (d[kDADiskDescriptionVolumeKindKey as String] as? String ?? "").lowercased()
        guard inhalt != "EFI", !["msdos", "exfat", "ntfs", "apfs"].contains(art) else { continue }
        let u = (CFUUIDCreateString(kCFAllocatorDefault, (cu as! CFUUID)) as String).uppercased()
        out.append(ErkannteDrobo(uuid: u, name: d[kDADiskDescriptionVolumeNameKey as String] as? String ?? "",
                                 bsd: name, groesse: (d[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0,
                                 modell: (d[kDADiskDescriptionDeviceModelKey as String] as? String ?? "").trimmingCharacters(in: .whitespaces)))
    }
    return out
}
