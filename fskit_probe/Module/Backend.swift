import Darwin
import FSKit
import Foundation
import os

private let log = Logger(subsystem: "de.begod.drobofsprobe", category: "dev")

/// Verbindet Apples I/O-Aufrufe (pread/pwrite/ioctl, umgeleitet auf lifs_devio.c) mit FSBlockDeviceResource.
/// Alle Schreibzugriffe kommen ueber lifs_dev_pwrite und sind damit auf 524288 B gekappt; hier gilt zusaetzlich: nie unter Offset 1024
/// (Marker/Boot-Bytes), nie ueber das Geraeteende, nie > 524288 B je dev.write.
final class DeviceBackend {
    let dev: FSBlockDeviceResource
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
    var directReads = 0, fallbackReads = 0
    /// Zweite Sperre (Modus nurlesen): dev.write wird NIE erreicht, jeder Versuch zaehlt und scheitert mit EROFS.
    let forcedReadOnly: Bool

    init(dev: FSBlockDeviceResource, forcedReadOnly: Bool = false) {
        self.dev = dev
        self.forcedReadOnly = forcedReadOnly
        self.phys = Int(max(512, dev.physicalBlockSize))
        self.bytes = dev.blockCount * dev.blockSize
        bounce = UnsafeMutableRawPointer.allocate(byteCount: Self.bounceSize, alignment: 4096)
    }
    deinit { bounce.deallocate() }

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

    /// EINZIGE Stelle fuer Lesebefehle ans Geraet (Zaehler; Pruefbau TEST_LATENZ: feste Verzoegerung je dev.read wie bei einem langsamen Geraet).
    private func devRead(_ p: UnsafeMutableRawPointer, _ a0: Int64, _ span: Int) throws -> Int {
        statLock.lock(); inflight += 1; maxInflight = max(maxInflight, inflight); statLock.unlock()
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            let dt = DispatchTime.now().uptimeNanoseconds - t0
            statLock.lock(); inflight -= 1; rdNanos += dt; rdCalls += 1; rdBytes += UInt64(span)
            rdHist[span <= 131072 ? 0 : span <= 524288 ? 1 : 2] += 1; statLock.unlock()
        }
        #if TEST_LATENZ
        usleep(8000)
        #endif
        return try dev.read(into: UnsafeMutableRawBufferPointer(start: p, count: span), startingAt: a0, length: span)
    }

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
