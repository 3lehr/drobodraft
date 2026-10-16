import Darwin
import FSKit
import Foundation
import os

private let log = Logger(subsystem: modulLogSubsystem, category: "dev")

/// Verbindet Apples I/O-Aufrufe (pread/pwrite/ioctl, umgeleitet auf lifs_devio.c) mit dem Geraet (FSBlockDeviceResource oder iSCSI-Partition, siehe Geraet.swift).
/// Alle Schreibzugriffe kommen ueber lifs_dev_pwrite und sind damit auf 524288 B gekappt; hier gilt zusaetzlich: nie unter Offset 1024
/// (Marker/Boot-Bytes), nie ueber das Geraeteende, nie > 524288 B je dev.write.
final class DeviceBackend {
    let dev: Geraet
    let phys: Int
    let bytes: UInt64
    private let bounce: UnsafeMutableRawPointer
    private static let bounceSize = (1 << 20) + 16384
    private let lock = NSLock()
    var vfd: Int32 = -1
    var devWrites = 0, devMax = 0, writeAttempts = 0
    /// Phase-5-Messung (nur Lesen, Zaehler ohne Wirkung auf den Ablauf): dev.read-Aufrufe, Bytes, Histogramm (<=128K, <=512K, <=1M), Zeit in dev.read,
    /// gleichzeitig laufende dev.read (jetzt/max). Alles unter statLock, weil der Direktweg ausserhalb des libLock liest.
    var rdCalls = 0, rdBytes: UInt64 = 0, rdNanos: UInt64 = 0
    var rdHist = [0, 0, 0]
    var inflight = 0, maxInflight = 0
    /// HFSVolume.read-Aufrufe am libLock: Anzahl, gleichzeitig wartend (jetzt/max), Summe Wartezeit; Direktweg-/Rueckfall-Lesungen (Hebel B).
    let statLock = NSLock()
    var volReads = 0, waiting = 0, maxWaiting = 0, waitNanos: UInt64 = 0
    /// Phase 5i: Lesungen aus MEHREREN Geraetestuecken (zerstueckelte Datei) halten diesen Lock fuer alle ihre Stuecke, damit sich die Stuecke paralleler Lesungen am Geraet
    /// nicht verschraenken (jeder Wechsel zwischen Lesungen waere auf einem seriellen Geraet ein Sprung, ~35 ms).
    let stueckeLock = NSLock()
    var directReads = 0, fallbackReads = 0, decmpfsReads = 0, lageTreffer = 0, lageNeu = 0
    /// Phase 5d Diagnose: Lage der Sonderdateien (sortiert nach Start; tag 0 Bitmap, 1 Extents-Ueberlauf, 2 Katalog, 3 Attribute); Lesungen <= 128 KiB werden danach
    /// gezaehlt (klein[tag] = Anzahl, kleinKB[tag] = KiB; tag 4 = ausserhalb aller Sonderdateien: Daten, Journal, Volume-Header ...). Nach dem Mount unveraenderlich.
    var ranges: [(start: Int64, end: Int64, tag: Int)] = []
    var klein = [Int](repeating: 0, count: 5), kleinKB = [Int](repeating: 0, count: 5)
    /// FSKit-Ebene (HFSVolume.read): ausgelieferte Bytes, nicht fortlaufende Lesungen, erneut ausgelieferte Bytes, Zahl verschiedener Dateien.
    /// FSKit-Operationen (Zahl der Aufrufe): getattr, lookup, readdir, reclaim - zeigt Fremdzugriffe (Crawler) neben den Lesungen.
    var enumChunks = 0, enumFortsetzungen = 0, enumEintraege = 0, enumGeloggt = 0
    var opGetattr = 0, opLookup = 0, opReaddir = 0, opReclaim = 0
    func opZaehlen(_ k: Int) { statLock.lock(); switch k { case 0: opGetattr += 1; case 1: opLookup += 1; case 2: opReaddir += 1; default: opReclaim += 1 }; statLock.unlock() }
    var volReadBytes: UInt64 = 0, volNonSeq = 0, volDoppeltBytes: UInt64 = 0, volDateien = 0
    /// Diagnose (Phase 5e): Datei stack_katalog im Modulcontainer -> die ersten 40 Katalog-Lesungen <= 128 KiB loggen ihren Aufrufweg (STACK-KATALOG).
    let stackProbe = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/stack_katalog")
    var stackGeloggt = 0
    func rangeIdx(_ off: Int64) -> Int {
        var lo = 0, hi = ranges.count
        while lo < hi { let m = (lo + hi) / 2; if ranges[m].start <= off { lo = m + 1 } else { hi = m } }
        return lo > 0 && off < ranges[lo - 1].end ? lo - 1 : -1
    }
    func tagFor(_ off: Int64) -> Int { let i = rangeIdx(off); return i >= 0 ? ranges[i].tag : 4 }

    /// Phase 5f: Knotencache (nur nurlesen; Extents-Ueberlauf, Katalog, Attribute). Reads <= 32 KiB in diesen Bereichen (ein B-Baum-Knoten, bei der Drobo 8 KiB)
    /// werden knotengenau zwischengespeichert, LRU nach Stempel. Grund: livefiles' eigener Buffer-Cache fasst nur 128-140 Eintraege (1-1,5 MiB); die Drobo
    /// bezahlt jede Wiederholungslesung mit einem Sprung (~35 ms). Im Modus nurlesen aendert sich der Baum nie, der Cache bleibt gueltig.
    /// ponytail: 64 MiB = 8192 Knoten gegen 2,7 GB Drobo-Katalog (2,4 %); Suchen der aeltesten Stempel ist linear (8192), erst bei Messung ersetzen.
    static let knotenCacheBytes = 64 << 20
    private struct KSlot { var off: Int64; var len: Int; var buf: UnsafeMutableRawPointer; var stamp: UInt64 }
    private var kSlots: [KSlot] = [], kIndex: [Int64: Int] = [:], kBytes = 0, kStempel: UInt64 = 0
    private var kEindeutig = Set<Int64>()
    var knotenAnfragen = 0, knotenTreffer = 0, knotenEindeutigZahl = 0
    /// Messschalter: Datei knotencache_aus im Modulcontainer schaltet den Cache ab (Vergleich).
    let knotenCacheAn = !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/knotencache_aus")
    /// Zaehlt Anfragen/eindeutige Offsets (Obergrenze 1 Mio Offsets) und bedient aus dem Cache. nil = nicht zustaendig / Miss mit Fehler: normaler Weg.
    private func knotenLesen(_ out: UnsafeMutableRawPointer, _ n: Int, _ off: Int64) -> Int? {
        let i = rangeIdx(off)
        guard i >= 0, ranges[i].tag >= 1, ranges[i].tag <= 3, off + Int64(n) <= ranges[i].end else { return nil }
        statLock.lock()
        knotenAnfragen += 1
        if kEindeutig.count < 1_000_000 { kEindeutig.insert(off) }
        knotenEindeutigZahl = kEindeutig.count
        statLock.unlock()
        guard knotenCacheAn, off % Int64(phys) == 0, n % phys == 0 else { return nil }
        kStempel += 1
        if let k = kIndex[off], kSlots[k].len >= n {
            kSlots[k].stamp = kStempel; memcpy(out, kSlots[k].buf, n)
            statLock.lock(); knotenTreffer += 1; statLock.unlock()
            return n
        }
        let tmp = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 4096)
        guard let got = try? devRead(tmp, off, n), got >= n else { tmp.deallocate(); return nil }
        while kBytes + n > Self.knotenCacheBytes, !kSlots.isEmpty {                     // aeltesten Stempel verdraengen (Swap mit dem letzten Platz)
            var m = 0
            for q in 1..<kSlots.count where kSlots[q].stamp < kSlots[m].stamp { m = q }
            kIndex[kSlots[m].off] = nil; kBytes -= kSlots[m].len; kSlots[m].buf.deallocate()
            let last = kSlots.removeLast()
            if m < kSlots.count { kSlots[m] = last; kIndex[last.off] = m }
        }
        if let old = kIndex[off] { kBytes -= kSlots[old].len; kSlots[old].buf.deallocate(); kSlots[old] = KSlot(off: off, len: n, buf: tmp, stamp: kStempel) }
        else { kIndex[off] = kSlots.count; kSlots.append(KSlot(off: off, len: n, buf: tmp, stamp: kStempel)) }
        kBytes += n
        memcpy(out, tmp, n)
        return n
    }
    #if TEST_FEHLER
    /// Pruefbau (analog TEST_DROBO): Datei fehler.txt im Container "N modus" laesst die N-te GROSSE (> 128 KiB) Lesung ans Geraet scheitern
    /// (modus wirf = Fehler EIO) oder verkuerzt sie auf die Haelfte (modus kurz). Ohne Datei kein Eingriff.
    private var fehlerN = 0, fehlerWirf = false, grosseLesungen = 0
    private func fehlerLesen() {
        guard let t = try? String(contentsOfFile: NSHomeDirectory() + "/fehler.txt", encoding: .utf8) else { log.notice("FEHLER-PRUEFBAU: keine fehler.txt"); return }
        let f = t.split(whereSeparator: { $0 == " " || $0 == "\n" })
        if f.count >= 2, let n = Int(f[0]) { fehlerN = n; fehlerWirf = f[1] == "wirf" }
        log.notice("FEHLER-PRUEFBAU: N=\(self.fehlerN) wirf=\(self.fehlerWirf)")
    }
    #endif
    /// Zweite Sperre (Modus nurlesen): dev.write wird NIE erreicht, jeder Versuch zaehlt und scheitert mit EROFS.
    let forcedReadOnly: Bool

    init(dev: Geraet, forcedReadOnly: Bool = false) {
        self.dev = dev
        self.forcedReadOnly = forcedReadOnly
        self.phys = Int(max(512, dev.physicalBlockSize))
        self.bytes = dev.blockCount * dev.blockSize
        bounce = UnsafeMutableRawPointer.allocate(byteCount: Self.bounceSize, alignment: 4096)
        #if TEST_FEHLER
        fehlerLesen()
        #endif
    }
    deinit { bounce.deallocate(); for w in kSlots { w.buf.deallocate() } }

    func register() -> Bool {
        var b = lifs_backend_t()
        b.ctx = Unmanaged.passUnretained(self).toOpaque()
        b.pread = { ctx, buf, n, off in Unmanaged<DeviceBackend>.fromOpaque(ctx!).takeUnretainedValue().read(buf!, n, Int64(off)) }
        b.pwrite = { ctx, buf, n, off in Unmanaged<DeviceBackend>.fromOpaque(ctx!).takeUnretainedValue().write(buf!, n, Int64(off)) }
        b.flush = { ctx in Unmanaged<DeviceBackend>.fromOpaque(ctx!).takeUnretainedValue().flush() }
        b.block_size = UInt32(dev.blockSize)
        b.phys_block_size = UInt32(phys)
        b.block_count = dev.blockCount
        b.writable = (dev.isWritable && !forcedReadOnly) ? 1 : 0
        vfd = lifs_dev_register(&b)
        return vfd >= 0
    }
    func unregister() { if vfd >= 0 { lifs_dev_unregister(vfd); vfd = -1 } }

    private func fail(_ e: Int32) -> Int { errno = e; return -1 }

    /// EINZIGE Stelle fuer Lesebefehle ans Geraet (Zaehler; Pruefbau TEST_DROBO: serielles Geraetemodell DroboModell).
    private func devRead(_ p: UnsafeMutableRawPointer, _ a0: Int64, _ span: Int) throws -> Int {
        statLock.lock(); inflight += 1; maxInflight = max(maxInflight, inflight); statLock.unlock()
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            let dt = DispatchTime.now().uptimeNanoseconds - t0
            statLock.lock(); inflight -= 1; rdNanos += dt; rdCalls += 1; rdBytes += UInt64(span)
            rdHist[span <= 131072 ? 0 : span <= 524288 ? 1 : 2] += 1
            if span <= 131072 {
                let t = tagFor(a0); klein[t] += 1; kleinKB[t] += span / 1024
                if t == 2 && stackProbe && stackGeloggt < 40 {
                    stackGeloggt += 1
                    let fr = Thread.callStackSymbols.prefix(40).map { $0.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).dropFirst(3).first.map(String.init) ?? $0 }
                    log.notice("STACK-KATALOG off=\(a0) span=\(span): \(fr.joined(separator: " < "), privacy: .public)")
                }
            }
            statLock.unlock()
        }
        #if TEST_DROBO
        return try droboLesen(p, a0, span)
        #endif
        #if TEST_FEHLER
        var kurz = false
        if span > 131072 && fehlerN > 0 {
            statLock.lock(); grosseLesungen += 1; let treffer = grosseLesungen == fehlerN; statLock.unlock()
            if treffer { log.notice("FEHLER-PRUEFBAU: Treffer bei grosser Lesung \(self.grosseLesungen)"); if fehlerWirf { throw posixError(EIO) } else { kurz = true } }
        }
        let got = try dev.read(into: UnsafeMutableRawBufferPointer(start: p, count: span), startingAt: a0, length: span)
        return kurz ? got / 2 : got
        #else
        return try dev.read(into: UnsafeMutableRawBufferPointer(start: p, count: span), startingAt: a0, length: span)
        #endif
    }

    #if TEST_DROBO
    /// Pruefbau TEST_DROBO: EIN globaler Mutex (ein Geraet, strikt seriell), Modellzeit je Befehl abzueglich der echten Lesezeit.
    private static let droboLock = NSLock()
    private static var droboEnde: Int64 = 0
    private func droboLesen(_ p: UnsafeMutableRawPointer, _ a0: Int64, _ span: Int) throws -> Int {
        Self.droboLock.lock(); defer { Self.droboLock.unlock() }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let soll = DroboModell.dauer(start: a0, bytes: span, vorigesEnde: Self.droboEnde)
        Self.droboEnde = a0 + Int64(span)
        let got = try dev.read(into: UnsafeMutableRawBufferPointer(start: p, count: span), startingAt: a0, length: span)
        let rest = soll - Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        if rest > 0 { usleep(UInt32(rest * 1e6)) }
        return got
    }
    #endif

    /// Hebel B: Lesen OHNE gemeinsame Sperre und OHNE gemeinsamen Bounce-Puffer (Puffer je Aufruf), mehrere Aufrufe gleichzeitig moeglich.
    /// devOff/n kommen aus lifs_map_read (liegen im Volume). Ausrichtung auf phys und <= 1 MiB je dev.read wie read(). Fehler/Kurzlesung -> EIO.
    func readDirect(_ dst: UnsafeMutableRawPointer, _ n: Int, _ devOff: Int64) throws {
        guard devOff >= 0, UInt64(devOff) + UInt64(n) <= bytes else { throw posixError(EIO) }
        let tmp = UnsafeMutableRawPointer.allocate(byteCount: min(n + 2 * phys, Self.bounceSize), alignment: 4096)
        defer { tmp.deallocate() }
        var done = 0
        while done < n {
            let pos = devOff + Int64(done)
            let a0 = pos - pos % Int64(phys)
            let head = Int(pos - a0)
            let chunk = min(n - done, (1 << 20) - head)
            let span = (head + chunk + phys - 1) / phys * phys
            let got: Int
            do { got = try devRead(tmp, a0, span) } catch { log.error("readDirect \(devOff) \(n): \(String(describing: error), privacy: .public)"); throw posixError(EIO) }
            if got < head + chunk { throw posixError(EIO) }
            memcpy(dst + done, tmp + head, chunk)
            done += chunk
        }
    }

    func read(_ buf: UnsafeMutableRawPointer, _ n: Int, _ off: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        if off < 0 || UInt64(off) >= bytes { return 0 }
        let want = Int(min(UInt64(n), bytes - UInt64(off)))
        if forcedReadOnly && want == n && n <= 32768, let r = knotenLesen(buf, n, off) { return r }
        var done = 0
        do {
            while done < want {
                let pos = Int64(off) + Int64(done)
                let a0 = pos - pos % Int64(phys)
                let head = Int(pos - a0)
                let chunk = min(want - done, (1 << 20) - head)
                let span = (head + chunk + phys - 1) / phys * phys
                let got = try devRead(bounce, a0, span)
                if got <= head { break }
                let use = min(chunk, got - head)
                memcpy(buf + done, bounce + head, use)
                done += use
                if got < span { break }
            }
        } catch {
            log.error("read \(off) \(n): \(String(describing: error), privacy: .public)")
            return done > 0 ? done : fail(EIO)
        }
        return done
    }

    func write(_ buf: UnsafeRawPointer, _ n: Int, _ off: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        if forcedReadOnly { writeAttempts += 1; log.error("SCHREIBVERSUCH im Modus nurlesen off=\(off) n=\(n) -> EROFS"); return fail(EROFS) }
        guard dev.isWritable else { return fail(EROFS) }
        guard n <= 524288, off >= 1024, UInt64(off) + UInt64(n) <= bytes else {
            log.error("write abgelehnt off=\(off) n=\(n)")
            return fail(EINVAL)
        }
        let a0 = Int64(off) - Int64(off) % Int64(phys)
        let head = Int(off - a0)
        let span = (head + n + phys - 1) / phys * phys
        do {
            if head != 0 || span != n {                      // Randsektoren erhalten: lesen-aendern-schreiben
                let got = try dev.read(into: UnsafeMutableRawBufferPointer(start: bounce, count: span), startingAt: a0, length: span)
                if got < span { memset(bounce + got, 0, span - got) }
            }
            memcpy(bounce + head, buf, n)
            var done = 0
            while done < span {                              // nie > 524288 je dev.write (span kann n um 2 Sektoren uebersteigen)
                let c = min(span - done, 524288)
                let put = try dev.write(from: UnsafeRawBufferPointer(start: bounce + done, count: c), startingAt: a0 + Int64(done), length: c)
                devWrites += 1; devMax = max(devMax, c)
                if put != c { return fail(EIO) }
                done += c
            }
        } catch {
            log.error("write \(off) \(n): \(String(describing: error), privacy: .public)")
            return fail(EIO)
        }
        return n
    }

    func flush() -> Int32 {
        // FSBlockDeviceResource kennt keinen Cache-Flush zum Medium; metadataFlush leert nur den Metadaten-Puffer (GRENZE, siehe Plan).
        do { try dev.metadataFlush(); return 0 } catch { return 0 }
    }
}
