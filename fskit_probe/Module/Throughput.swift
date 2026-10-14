import Darwin
import FSKit
import Foundation

// Phase 0a: Rohdurchsatz ueber FSBlockDeviceResource in 512-KiB-Stuecken.
// Das ist die EINZIGE Stelle, die auf das Geraet schreibt (Invariante: nur ab Offset 1 MiB, nie > 512 KiB).
enum Throughput {
    static let chunk = 512 * 1024
    static let base: off_t = 1 << 20
    static let marker = Array("DROBOFSPROBE".utf8)
    /// Einzig erlaubte Geraetegroesse: das 4-GiB-Testabbild aus tools/run_probe.sh. Jede andere Groesse (Drobo, CF-Karte,
    /// 5-GiB-Abbild) bekommt KEINE Messung, auch mit Marker -- der Marker allein ist ein Byte-Muster, das auch ein
    /// Fremdmedium tragen kann.
    static let erlaubteGroesse = 4 << 30

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Marker "DROBOFSPROBE" an Offset 0 des ersten Sektors.
    static func hasMarker(_ dev: FSBlockDeviceResource) throws -> Bool {
        let n = Int(max(512, dev.physicalBlockSize))
        let buf = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 4096)
        defer { buf.deallocate() }
        let got = try dev.read(into: UnsafeMutableRawBufferPointer(start: buf, count: n), startingAt: 0, length: n)
        guard got >= marker.count else { return false }
        return memcmp(buf, marker, marker.count) == 0
    }

    /// Schreibt NUR, wenn Groesse == erlaubteGroesse UND der Marker unmittelbar davor erneut gelesen wurde.
    static func run(_ dev: FSBlockDeviceResource, totalBytes: Int = 2 << 30) -> String {
        var out = "bsd=\(dev.bsdName) blockSize=\(dev.blockSize) physBlockSize=\(dev.physicalBlockSize) blockCount=\(dev.blockCount) writable=\(dev.isWritable)\n"
        let devBytes = Int(dev.blockCount * dev.blockSize)
        guard devBytes == erlaubteGroesse else { return out + "ABBRUCH: Geraetegroesse \(devBytes) != \(erlaubteGroesse) (4 GiB) -- keine Messung, nichts geschrieben\n" }
        guard (try? hasMarker(dev)) == true else { return out + "ABBRUCH: Marker vor der Messung nicht (mehr) lesbar -- keine Messung, nichts geschrieben\n" }
        let total = min(totalBytes, devBytes - Int(base)) / chunk * chunk
        let n = total / chunk
        guard dev.isWritable, n > 0 else { return out + "ABBRUCH: nicht beschreibbar oder zu klein\n" }
        let w = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        let r = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { w.deallocate(); r.deallocate() }
        memset(w, 0xA5, chunk)

        var wNs: UInt64 = 0, rNs: UInt64 = 0, bad = 0
        out += "chunk=\(chunk) chunks=\(n) bytes=\(total) offset=\(base)\n"
        do {
            for i in 0..<n {
                w.storeBytes(of: UInt64(i), as: UInt64.self)
                let t0 = now()
                let put = try dev.write(from: UnsafeRawBufferPointer(start: w, count: chunk), startingAt: base + off_t(i * chunk), length: chunk)
                wNs += now() - t0
                if put != chunk { out += "FEHLER write chunk \(i): \(put) von \(chunk)\n"; bad += 1; break }
            }
            memset(w, 0xA5, chunk)
            for i in 0..<n {
                let t0 = now()
                let got = try dev.read(into: UnsafeMutableRawBufferPointer(start: r, count: chunk), startingAt: base + off_t(i * chunk), length: chunk)
                rNs += now() - t0
                // Pruefung ausserhalb der Zeitmessung: Zaehler + Muster
                if got != chunk || r.load(as: UInt64.self) != UInt64(i) || memcmp(r + 8, w + 8, chunk - 8) != 0 { bad += 1 }
            }
        } catch {
            out += "FEHLER: \(error) (\(error as NSError).code)\n"
            bad += 1
        }
        func mbps(_ ns: UInt64) -> String { ns == 0 ? "n/a" : String(format: "%.1f", Double(total) / 1e6 / (Double(ns) / 1e9)) }
        out += "write_MBps=\(mbps(wNs)) read_MBps=\(mbps(rNs)) write_s=\(Double(wNs) / 1e9) read_s=\(Double(rNs) / 1e9) verify_bad=\(bad)\n"
        return out
    }
}
