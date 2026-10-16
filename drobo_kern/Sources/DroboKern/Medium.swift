import DiskArbitration
import Foundation

public enum Treiber: Equatable { case kernel, hfsdrobo, andere(String) }

public struct Einhaengung: Equatable {
    public var ort: String
    public var nurlesen: Bool
    public var treiber: Treiber
}

public struct Medium: Equatable {
    public var bsd: String          // z. B. disk9s1
    public var uuid: String
    public var groesse: UInt64
    public var name: String = ""   // Volumename laut DiskArbitration
    public var geraet: String { "/dev/" + bsd }
    public var rohgeraet: String { "/dev/r" + bsd }
}

/// Mount-Tabelle (getfsstat): geraet -> Einhaengung. Kernel-HFS meldet "hfs"; Treiber-Zuordnung siehe Messung in den Tests.
public func einhaengungen() -> [String: Einhaengung] {
    let n = getfsstat(nil, 0, MNT_NOWAIT)
    guard n > 0 else { return [:] }
    let buf = UnsafeMutablePointer<statfs>.allocate(capacity: Int(n)); defer { buf.deallocate() }
    let m = getfsstat(buf, Int32(MemoryLayout<statfs>.stride) * n, MNT_NOWAIT)
    var out: [String: Einhaengung] = [:]
    for i in 0..<Int(max(m, 0)) {
        var s = buf[i]
        let von = withUnsafePointer(to: &s.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
        let auf = withUnsafePointer(to: &s.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
        let typ = withUnsafePointer(to: &s.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        let t: Treiber = typ == "hfs" ? .kernel : (typ == "hfsdrobo" ? .hfsdrobo : .andere(typ))
        out[von] = Einhaengung(ort: auf, nurlesen: s.f_flags & UInt32(MNT_RDONLY) != 0, treiber: t)
    }
    return out
}

/// Findet das Volume per Volume-UUID ueber DiskArbitration (nur Beschreibung, oeffnet kein Geraet).
public func finden(uuid: String) -> Medium? {
    guard let sess = DASessionCreate(kCFAllocatorDefault),
          let namen = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return nil }
    let want = uuid.uppercased()
    for name in namen.sorted() where name.range(of: #"^disk[0-9]+(s[0-9]+)?$"#, options: .regularExpression) != nil {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, sess, name),
              let d = DADiskCopyDescription(disk) as? [String: Any],
              let cu = d[kDADiskDescriptionVolumeUUIDKey as String] else { continue }
        let s = CFUUIDCreateString(kCFAllocatorDefault, (cu as! CFUUID)) as String
        if s.uppercased() == want {
            let size = (d[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0
            let vn = d[kDADiskDescriptionVolumeNameKey as String] as? String ?? ""
            return Medium(bsd: name, uuid: want, groesse: size, name: vn)
        }
    }
    return nil
}
