import DiskArbitration
import Foundation

/// Sicheres Abziehen: merkt sich dauerhaft, dass ein Volume im Schreibzustand eingehaengt war, und setzt bei Verschwinden des Geraets
/// (DiskArbitration-Disappeared-Callback) den Merker "offenePruefung". Naechstes Einhaengen prueft zuerst (Kern.einhaengen).
public final class AbziehWaechter {
    public enum Ereignis { case angeschlossen(bsd: String), getrennt(bsd: String, imSchreiben: Bool) }
    let ablage: Datenablage
    let uuid: String
    let bei: (Ereignis) -> Void
    let queue = DispatchQueue(label: "de.begod.drobo.abziehen")
    var session: DASession?

    public init(uuid: String, ablage: Datenablage, bei: @escaping (Ereignis) -> Void) { self.uuid = uuid.uppercased(); self.ablage = ablage; self.bei = bei }

    /// Verschwinden eines Geraets bewerten (ohne DiskArbitration testbar): war es unser Volume im Schreibzustand und ist es nicht sauber ausgehaengt worden?
    func verschwunden(bsd: String) {
        let m = ablage.merker(uuid)
        guard m.bsd == bsd, !bsd.isEmpty else { return }
        let imSchreiben = m.rwAktiv
        if imSchreiben {
            ablage.merkerAendern(uuid) { $0.rwAktiv = false; $0.offenePruefung = "Laufwerk wurde im Schreibzustand getrennt" }
            ablage.protokoll("Warnung: Drobo \(uuid) wurde im Schreibzustand getrennt. Vor dem naechsten Einhaengen wird geprueft.")
        }
        bei(.getrennt(bsd: bsd, imSchreiben: imSchreiben))
    }

    public func start() {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return }
        session = s
        let me = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskDisappearedCallback(s, nil, { disk, ctx in
            guard let ctx = ctx, let n = DADiskGetBSDName(disk) else { return }
            Unmanaged<AbziehWaechter>.fromOpaque(ctx).takeUnretainedValue().verschwunden(bsd: String(cString: n))
        }, me)
        DARegisterDiskAppearedCallback(s, nil, { disk, ctx in
            guard let ctx = ctx, let n = DADiskGetBSDName(disk), let d = DADiskCopyDescription(disk) as? [String: Any],
                  let cu = d[kDADiskDescriptionVolumeUUIDKey as String] else { return }
            let w = Unmanaged<AbziehWaechter>.fromOpaque(ctx).takeUnretainedValue()
            if (CFUUIDCreateString(kCFAllocatorDefault, (cu as! CFUUID)) as String).uppercased() == w.uuid { w.bei(.angeschlossen(bsd: String(cString: n))) }
        }, me)
        DASessionSetDispatchQueue(s, queue)
    }

    public func stop() { if let s = session { DASessionSetDispatchQueue(s, nil); session = nil } }
}
