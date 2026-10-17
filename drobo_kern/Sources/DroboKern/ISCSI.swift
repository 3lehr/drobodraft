import Foundation
import CryptoKit
import IOKit

/// Fehler des iSCSI-Clients. Nie ein Haengen: jede Wartezeit ist durch `zeitgrenze` begrenzt und endet hier.
public enum ISCSIFehler: Error, CustomStringConvertible {
    case verbindung(String)
    case zeitueberschreitung(String)
    case protokoll(String)
    case login(String)
    case belegt                                 // Login-Ablehnung 2/2: ein anderer Initiator (Rechner) haelt die DroboPro (Single-Initiator)
    case verboten(String)                       // Allowlist-Gate: der Befehl wurde NICHT gesendet
    case scsi(status: UInt8, sense: [UInt8])    // Ziel antwortete mit Status != GOOD

    public var description: String {
        switch self {
        case .verbindung(let s): return "iSCSI connection: \(s)"
        case .zeitueberschreitung(let s): return "iSCSI timeout: \(s)"
        case .protokoll(let s): return "iSCSI protocol: \(s)"
        case .login(let s): return "iSCSI login: \(s)"
        case .belegt: return "iSCSI login: target is in use by another initiator"
        case .verboten(let s): return "iSCSI command refused before sending: \(s)"
        case .scsi(let st, let sense):
            let k = sense.count > 13 ? String(format: " key %02x asc %02x/%02x", sense[2] & 0x0f, sense[12], sense[13]) : ""
            return String(format: "SCSI status 0x%02x", st) + k
        }
    }
}

/// Roher TCP-Draht mit Zeitgrenze je Wartevorgang (poll). Eine Verbindung, kein Zustand ausser dem Deskriptor.
final class TCPDraht {
    private var fd: Int32 = -1
    var zeitgrenze: TimeInterval
    init(host: String, port: UInt16, zeitgrenze: TimeInterval) throws {
        self.zeitgrenze = zeitgrenze
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { throw ISCSIFehler.verbindung("cannot resolve host") }
        defer { freeaddrinfo(res) }
        fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { throw ISCSIFehler.verbindung("socket: \(String(cString: strerror(errno)))") }
        var an: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &an, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &an, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else { let e = String(cString: strerror(errno)); schliessen(); throw ISCSIFehler.verbindung("connect: \(e)") }
            do { try warte(POLLOUT) } catch {
                schliessen()
                // Verbindungsaufbau ohne Antwort = Host/Netz weg, NICHT "Drobo haengt" (das ist eine Zeitueberschreitung nach dem Login)
                if case .zeitueberschreitung = error as? ISCSIFehler { throw ISCSIFehler.verbindung("connect: no answer within \(zeitgrenze) s") }
                throw error
            }
            var so: Int32 = 0; var l = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &so, &l)
            if so != 0 { schliessen(); throw ISCSIFehler.verbindung("connect: \(String(cString: strerror(so)))") }
        }
    }
    deinit { schliessen() }
    func schliessen() { if fd >= 0 { close(fd); fd = -1 } }

    private func warte(_ ev: Int32) throws {
        guard fd >= 0 else { throw ISCSIFehler.verbindung("closed") }
        var p = pollfd(fd: fd, events: Int16(ev), revents: 0)
        while true {
            let r = poll(&p, 1, Int32(zeitgrenze * 1000))
            if r > 0 { return }
            if r == 0 { throw ISCSIFehler.zeitueberschreitung("no data within \(zeitgrenze) s") }
            if errno != EINTR { throw ISCSIFehler.verbindung("poll: \(String(cString: strerror(errno)))") }
        }
    }
    func senden(_ d: [UInt8]) throws {
        var off = 0
        while off < d.count {
            try warte(POLLOUT)
            let n = d[off...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw ISCSIFehler.verbindung("send: \(String(cString: strerror(errno)))") }
            off += n
        }
    }
    func lesen(_ n: Int) throws -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n); var off = 0
        while off < n {
            try warte(POLLIN)
            let r = b[off...].withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if r == 0 { throw ISCSIFehler.verbindung("closed by target") }
            if r < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw ISCSIFehler.verbindung("recv: \(String(cString: strerror(errno)))") }
            off += r
        }
        return b
    }
}

struct PDU {
    var bhs: [UInt8]
    var daten: [UInt8]
    var op: UInt8 { bhs[0] & 0x3F }
    func u32(_ o: Int) -> UInt32 { bhs[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
}

func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) { for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> UInt32(24 - 8 * i)) } }
func put64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) { for i in 0..<8 { b[o + i] = UInt8(truncatingIfNeeded: v >> UInt64(56 - 8 * i)) } }

func pdu(_ op: UInt8, _ flags: UInt8, daten: [UInt8] = [], _ f: (inout [UInt8]) -> Void) -> [UInt8] {
    var h = [UInt8](repeating: 0, count: 48); h[0] = op; h[1] = flags
    h[5] = UInt8(daten.count >> 16 & 0xff); h[6] = UInt8(daten.count >> 8 & 0xff); h[7] = UInt8(daten.count & 0xff)
    f(&h)
    return h + daten + [UInt8](repeating: 0, count: -daten.count & 3)
}

func schluessel(_ d: [UInt8]) -> [String: String] {
    var r: [String: String] = [:]
    for teil in d.split(separator: 0) { let s = String(decoding: teil, as: UTF8.self); if let i = s.firstIndex(of: "=") { r[String(s[..<i])] = String(s[s.index(after: i)...]) } }
    return r
}

/// iSCSI-Sitzung (eine Verbindung, keine Digests, kein CHAP, ErrorRecoveryLevel 0). Befehle in `ISCSIBefehle.swift`.
/// ponytail: ein Befehl zur Zeit (Sperre um den ganzen Austausch); parallele Befehle bei Bedarf ueber MaxCmdSN-Fenster. Nach jedem Fehler
/// ausser SCSI-Status ist die Sitzung tot (Antworten koennten spaeter eintreffen) und jeder weitere Aufruf wirft.
public final class ISCSISitzung {
    public static let maxDatenmenge = 524288          // WRITE und READ je Befehl; deckt sich mit MaxBurstLength der DroboPro
    let draht: TCPDraht
    let sperre = NSLock()
    var cmdSN: UInt32 = 1
    var expStatSN: UInt32 = 0
    var itt: UInt32 = 0x100
    var tsih: [UInt8] = [0, 0]
    var zielSegment = 8192                            // MaxRecvDataSegmentLength des Ziels (Standardwert, bis das Login ihn nennt)
    var maxBurst = ISCSISitzung.maxDatenmenge
    var firstBurst = ISCSISitzung.maxDatenmenge
    /// Ziel hat ImmediateData=Yes ausgehandelt. Ohne das wird NIE geschrieben (siehe Messbefund bei `befehl`).
    var immediateAusgehandelt = false
    /// Nur waehrend `lunGroesseSetzen` an: sonst weist `befehl` jeden EA-Befehl ab.
    var lunGroesseFreigabe = false
    public private(set) var login: [String: String] = [:]   // Schluessel der letzten Login-Antwort (Diagnose)
    var tot: ISCSIFehler?
    var blockgroessen: [Int: Int] = [:]
    let discovery: Bool
    /// Feste ISID je Mac und Zweck. Messbefund DroboPro 2026-10-17: Login mit gleichem Initiator-Namen und gleicher ISID wird angenommen (ersetzt die alte Sitzung),
    /// ein anderer Name wird mit Status 2/2 abgelehnt (Single-Initiator). Eine zufaellige ISID je Login liess jede abgebrochene Sitzung als Leiche stehen.
    public let isid: [UInt8]
    public static let maschine: String = {
        let e = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if e != IO_OBJECT_NULL { IOObjectRelease(e) } }
        if e != IO_OBJECT_NULL, let u = IORegistryEntryCreateCFProperty(e, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String { return u }
        return ProcessInfo.processInfo.hostName
    }()
    /// Initiator-Name je Mac eindeutig und stabil: 16 Hex-Zeichen aus SHA-256 der Hardware-UUID (keine Rohausgabe). Ein fester Name fuer alle Macs
    /// liesse mit festen ISIDs zwei Macs ihre Sitzung gegenseitig ersetzen.
    public static func initiatorName(maschine: String) -> String {
        "iqn.2026-10.local.drobodraft:" + SHA256.hash(data: Data("initiator|\(maschine)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    /// Rein: 0x80 + 5 Byte SHA-256("maschine|zweck"). Gleicher Zweck -> gleiche ISID, anderer Zweck -> andere.
    public static func isid(maschine: String, zweck: String) -> [UInt8] { [0x80] + Array(SHA256.hash(data: Data("\(maschine)|\(zweck)".utf8)).prefix(5)) }

    /// `ziel == nil` -> Discovery-Sitzung (nur `ziele()`), sonst Normal-Sitzung auf dieses Ziel.
    public init(host: String, port: UInt16 = 3260, ziel: String? = nil, zeitgrenze: TimeInterval = 10, initiator: String = ISCSISitzung.initiatorName(maschine: ISCSISitzung.maschine), zweck: String = "status") throws {
        draht = try TCPDraht(host: host, port: port, zeitgrenze: zeitgrenze)
        discovery = ziel == nil
        isid = Self.isid(maschine: Self.maschine, zweck: ziel == nil ? "discovery" : zweck)
        do { try anmelden(initiator: initiator, ziel: ziel) } catch { draht.schliessen(); throw error }
    }

    func empfangen() throws -> PDU {
        let h = try draht.lesen(48)
        let ahs = Int(h[4]) * 4, n = Int(h[5]) << 16 | Int(h[6]) << 8 | Int(h[7])
        let rest = try draht.lesen(ahs + n + (-n & 3))
        return PDU(bhs: h, daten: Array(rest[ahs..<ahs + n]))
    }

    /// Login in Schritten wie an der DroboPro gemessen: Sicherheitsphase braucht zwei Runden (erste Antwort ohne T), dann Operational.
    private func anmelden(initiator: String, ziel: String?) throws {
        var keys = ["InitiatorName=" + initiator, "SessionType=" + (ziel == nil ? "Discovery" : "Normal"), "AuthMethod=None"]
        if let z = ziel { keys.insert("TargetName=" + z, at: 2) }
        var flags: UInt8 = 0x81
        for _ in 0..<8 {
            let daten = Array(keys.map { $0 + "\0" }.joined().utf8)
            let ids = isid, ts = tsih, st = expStatSN
            try draht.senden(pdu(0x43, flags, daten: daten) { h in
                h[8..<14] = ids[...]; h[14..<16] = ts[...]; put32(&h, 16, 1); h[21] = 1; put32(&h, 24, 1); put32(&h, 28, st)
            })
            let r = try empfangen()
            guard r.op == 0x23 else { throw ISCSIFehler.login("unexpected opcode \(r.op)") }
            if r.bhs[36] == 2 && r.bhs[37] == 2 { throw ISCSIFehler.belegt }
            if r.bhs[36] != 0 { throw ISCSIFehler.login("rejected \(r.bhs[36])/\(r.bhs[37])") }
            tsih = Array(r.bhs[14..<16]); expStatSN = r.u32(24) &+ 1
            for (k, v) in schluessel(r.daten) { login[k] = v }
            let transit = r.bhs[1] & 0x80 != 0, nsg = r.bhs[1] & 3
            if transit && nsg == 3 {
                if let s = login["MaxRecvDataSegmentLength"].flatMap(Int.init) { zielSegment = max(s, 512) }
                if let b = login["MaxBurstLength"].flatMap(Int.init) { maxBurst = min(maxBurst, b) }
                if let f = login["FirstBurstLength"].flatMap(Int.init) { firstBurst = min(firstBurst, f) }
                immediateAusgehandelt = ziel != nil && login["ImmediateData"] == "Yes"
                if login["InitialR2T"] == "No" { throw ISCSIFehler.login("target negotiated InitialR2T=No; this client only supports R2T") }
                return
            }
            if transit && nsg == 1 {
                flags = 0x87
                // Messbefund DroboPro 2026-10-16: mit ImmediateData=No (FirstBurstLength=65536, MaxOutstandingR2T=1) sendet das Ziel auf einen WRITE KEIN R2T,
                // trennt nach ~4 s und startet neu (3x reproduziert, 4 KiB WRITE(16) und WRITE(10)). Mit ImmediateData=Yes, FirstBurstLength=MaxBurstLength=524288,
                // MaxOutstandingR2T=8 und dem ersten Datenteil im Command-PDU laufen 4 KiB...32 MiB ohne Neustart. Welche Einstellung entscheidet, ist ungetrennt.
                keys = ["HeaderDigest=None", "DataDigest=None", "MaxRecvDataSegmentLength=262144"]
                if ziel != nil { keys += ["InitialR2T=Yes", "ImmediateData=Yes", "MaxBurstLength=524288", "FirstBurstLength=524288", "MaxOutstandingR2T=8", "ErrorRecoveryLevel=0"] }
            } else { keys = [] }
        }
        throw ISCSIFehler.login("no full-feature phase after 8 rounds")
    }

    /// Discovery: alle Ziele (Name, Adresse) per SendTargets=All.
    public func ziele() throws -> [(name: String, adresse: String)] {
        guard discovery else { throw ISCSIFehler.protokoll("ziele() needs a discovery session") }
        return try gesichert {
            let id = naechsteITT(); let c = cmdSN, st = expStatSN
            try draht.senden(pdu(0x04, 0x80, daten: Array("SendTargets=All\0".utf8)) { h in put32(&h, 16, id); put32(&h, 20, 0xffff_ffff); put32(&h, 24, c); put32(&h, 28, st) })
            cmdSN &+= 1
            let r = try empfangen()
            guard r.op == 0x24 else { throw ISCSIFehler.protokoll("unexpected opcode \(r.op) after SendTargets") }
            expStatSN = r.u32(24) &+ 1
            var out: [(name: String, adresse: String)] = []
            for teil in r.daten.split(separator: 0) {
                let s = String(decoding: teil, as: UTF8.self)
                if s.hasPrefix("TargetName=") { out.append((String(s.dropFirst(11)), "")) }
                else if s.hasPrefix("TargetAddress="), !out.isEmpty { out[out.count - 1].adresse = String(s.dropFirst(14)) }
            }
            return out
        }
    }

    func naechsteITT() -> UInt32 { itt &+= 1; return itt }

    /// Ein Austausch unter Sperre; jeder Fehler ausser SCSI-Status und Gate-Ablehnung macht die Sitzung tot.
    func gesichert<T>(_ block: () throws -> T) throws -> T {
        sperre.lock(); defer { sperre.unlock() }
        if let t = tot { throw t }
        do { return try block() }
        catch let f as ISCSIFehler {
            switch f { case .scsi, .verboten: break; default: tot = f; logoutUndSchliessen() }   // Logout auch nach Zeitueberschreitung/Fehler: keine Leiche am Ziel
            throw f
        }
    }

    /// Logout mit eigener kurzer Zeitgrenze, dann Verbindung zu. Fehler egal. Sperre muss gehalten werden. Eine verspaetete Antwort auf den letzten Befehl wird uebersprungen.
    static let logoutZeitgrenze: TimeInterval = 2
    private func logoutUndSchliessen() {
        draht.zeitgrenze = Self.logoutZeitgrenze
        let id = naechsteITT(), c = cmdSN, st = expStatSN
        if (try? draht.senden(pdu(0x46, 0x80) { h in put32(&h, 16, id); put32(&h, 24, c); put32(&h, 28, st) })) != nil {
            for _ in 0..<4 { guard let r = try? empfangen(), r.op != 0x26 else { break } }
        }
        draht.schliessen()
    }

    /// Logout und Verbindung schliessen; Fehler beim Logout sind egal (Verbindung ist danach zu).
    public func abmelden() {
        sperre.lock(); defer { sperre.unlock() }
        if tot == nil { logoutUndSchliessen() }
        tot = .verbindung("logged out")
    }
}
