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
                let got = try dev.read(into: UnsafeMutableRawBufferPointer(start: bounce, count: span), startingAt: a0, length: span)
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
