import Darwin
import FSKit
import Foundation
import os

private let log = hfsLog

// Gueltigkeits-Bits von UVFSFileAttributes.fa_validmask (livefiles_shim/UserFS/UserVFS.h)
private let vTYPE: UInt64 = 1 << 0, vMODE: UInt64 = 1 << 1, vUID: UInt64 = 1 << 3, vGID: UInt64 = 1 << 4
private let vFLAGS: UInt64 = 1 << 5, vSIZE: UInt64 = 1 << 6, vATIME: UInt64 = 1 << 10, vMTIME: UInt64 = 1 << 11, vBIRTH: UInt64 = 1 << 13
private let VOL_CAP_FMT_JOURNAL_: UInt64 = 0x8, VOL_CAP_FMT_JOURNAL_ACTIVE_: UInt64 = 0x10, VOL_CAP_FMT_CASE_SENSITIVE_: UInt64 = 0x80

typealias Node = UnsafeMutableRawPointer

final class HItem: FSItem {
    let node: Node
    var refs = 1
    var lastEnd: Int64 = 0, gesehen = false, seiten: [UInt64] = []     // Diagnose (Phase 5d), unter statLock; seiten = Bitmap der ausgelieferten 4-KiB-Seiten
    init(_ n: Node) { node = n }
}

private func withName<R>(_ n: FSFileName, _ f: (UnsafePointer<CChar>) -> R) -> R {
    var a = n.data.map { CChar(bitPattern: $0) }
    a.append(0)
    return a.withUnsafeBufferPointer { f($0.baseAddress!) }
}
private func check(_ r: Int32) throws { if r != 0 { throw posixError(r > 0 ? r : EIO) } }
/// Wie locked{}, zaehlt aber Wartende und Wartezeit am libLock (nur fuer HFSVolume.read; Phase-5-Messung).
private func timedLock<T>(_ b: DeviceBackend, _ f: () -> T) -> T {
    let t0 = DispatchTime.now().uptimeNanoseconds
    b.statLock.lock(); b.waiting += 1; b.maxWaiting = max(b.maxWaiting, b.waiting); b.statLock.unlock()
    libLock.lock(); defer { libLock.unlock() }
    let t1 = DispatchTime.now().uptimeNanoseconds
    b.statLock.lock(); b.waiting -= 1; b.waitNanos += t1 - t0; b.statLock.unlock()
    return f()
}
private func locked<T>(_ f: () throws -> T) rethrows -> T { libLock.lock(); defer { libLock.unlock() }; return try f() }

#if TEST_DROBO
private let droboBau = 1
#else
private let droboBau = 0
#endif
#if TEST_FEHLER
private let fehlerBau = 1
#else
private let fehlerBau = 0
#endif

final class HFSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, FSVolume.XattrOperations {
    let dev: FSBlockDeviceResource
    let backend: DeviceBackend
    let rootItem: HItem
    private(set) var mountedName: String
    private var items: [Node: HItem] = [:]
    private var closed = false
    private var userBytesWritten: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let readOnly: Bool
    private var roBlocked = 0
    /// Hebel B nur im Modus nurlesen; Messschalter: Datei direktweg_aus im Container des Moduls schaltet ihn ab (alter Weg zum Vergleich).
    private let directRead: Bool
    private func rofail() throws -> Never { roBlocked += 1; throw posixError(EROFS) }

    init(dev: FSBlockDeviceResource, backend: DeviceBackend, containerUUID: UUID, nurlesen: Bool = false) throws {
        let fd = backend.vfd
        let ro = !dev.isWritable || nurlesen
        if nurlesen {                                                        // Journal nicht leer: Mount ABLEHNEN (Replay wuerde schreiben)
            let d = lifs_journal_dirty(fd)
            if d != 0 { log.error("nurlesen abgelehnt: Journal nicht leer oder unlesbar (\(d))"); throw posixError(d < 0 ? -d : EBUSY) }
        }
        if !ro {
            let p = lifs_prepare_volume(fd)                                   // lastMountedVersion=HFSJ vor dem ersten Journal-Schreiben
            if p < 0 { throw posixError(-p) }
            log.notice("prepare: \(p) (1 = lastMountedVersion gesetzt)")
        }
        var r = HFS_fsOps.fsops_taste!(fd)
        if r != 0 { throw posixError(r > 0 ? r : EINVAL) }
        var root: Node? = nil
        r = HFS_fsOps.fsops_mount!(fd, 0, ro ? 1 : 0, nil, &root)
        if r != 0 || root == nil { throw posixError(r > 0 ? r : EIO) }
        var info = lifs_volinfo_t()
        _ = lifs_volinfo(root, &info)
        var gl: UInt32 = 0, gp: UInt32 = 0, go: UInt64 = 0
        lifs_geometry(root, &gl, &gp, &go)
        var rng: [(start: Int64, end: Int64, tag: Int)] = []
        for w in 0..<4 {
            var cap = 4096, nn: Int32 = 0
            var buf = [lifs_extent_t](repeating: lifs_extent_t(), count: cap)
            var r = lifs_special_extents(root, Int32(w), &buf, Int32(cap), &nn)
            if r == 0 && Int(nn) > cap { cap = Int(nn); buf = [lifs_extent_t](repeating: lifs_extent_t(), count: cap); r = lifs_special_extents(root, Int32(w), &buf, Int32(cap), &nn) }
            if r == 0 { for e in buf[0..<min(Int(nn), cap)] { rng.append((Int64(e.dev_off), Int64(e.dev_off + e.len), w)) } }
            log.notice("SONDERDATEI \(["bitmap", "extents", "katalog", "attribute"][w], privacy: .public) stuecke=\(nn) r=\(r)")
        }
        rng.sort { $0.start < $1.start }
        backend.ranges = rng
        log.notice("GEOM dev.blockSize=\(dev.blockSize) dev.physicalBlockSize=\(dev.physicalBlockSize) hfs_logical_block_size=\(gl) hfs_physical_block_size=\(gp) hfsPlusIOPosOffset=\(go) blockCount=\(dev.blockCount)")
        let name = withUnsafePointer(to: &info.name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        self.dev = dev; self.backend = backend; self.readOnly = ro
        self.directRead = ro && !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/direktweg_aus")
        self.rootItem = HItem(root!)
        self.mountedName = name.isEmpty ? "HFS+" : name
        self.items[root!] = rootItem
        super.init(volumeID: FSVolume.Identifier(uuid: containerUUID), volumeName: FSFileName(string: self.mountedName))
        // Journal-Commit nicht dem Zufall ueberlassen: alle 5 s Sync (nur wenn beschreibbar)
        if !ro {
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in
                guard let s = self, !s.closed else { return }
                locked { _ = HFS_fsOps.fsops_sync!(s.rootItem.node) }
            }
            t.resume(); timer = t
        }
    }

    // MARK: PathConf / Faehigkeiten
    var maximumLinkCount: Int { 65535 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 128 * 1024 }
    var maximumFileSizeInBits: Int { 64 }

    #if !TEST_MOUNT_RW
    @available(macOS 26.4, *)
    var requestedMountOptions: FSVolume.MountOptions { get { readOnly ? [.readOnly] : [] } set {} }
    #endif   // TEST_MOUNT_RW: nur Pruefbau (eich_fskit.sh freigabe-modul), damit Schreibzugriffe die EROFS-Sperren des Moduls erreichen

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        var info = lifs_volinfo_t()
        locked { _ = lifs_volinfo(rootItem.node, &info) }
        let c = FSVolume.SupportedCapabilities()
        c.supportsPersistentObjectIDs = true
        c.supportsSymbolicLinks = true
        c.supportsHardLinks = true
        c.supportsJournal = info.caps_format & VOL_CAP_FMT_JOURNAL_ != 0
        c.supportsActiveJournal = info.caps_format & VOL_CAP_FMT_JOURNAL_ACTIVE_ != 0
        c.supports2TBFiles = true
        c.supportsHiddenFiles = true
        c.supports64BitObjectIDs = false
        c.caseFormat = info.caps_format & VOL_CAP_FMT_CASE_SENSITIVE_ != 0 ? .sensitive : .insensitiveCasePreserving
        return c
    }

    var volumeStatistics: FSStatFSResult {
        var info = lifs_volinfo_t()
        locked { _ = lifs_volinfo(rootItem.node, &info) }
        let s = FSStatFSResult(fileSystemTypeName: "hfsdrobo")
        let bs = info.blocksize == 0 ? 4096 : info.blocksize
        s.blockSize = Int(bs); s.ioSize = 1 << 20
        s.totalBlocks = info.total; s.freeBlocks = info.free_; s.availableBlocks = info.avail
        s.usedBlocks = info.total - min(info.total, info.free_)
        s.totalFiles = info.total; s.freeFiles = info.free_
        return s
    }

    // MARK: Lebenszyklus
    func activate(options: FSTaskOptions) async throws -> FSItem { rootItem }

    func mount(options: FSTaskOptions) async throws { log.notice("mount \(self.mountedName, privacy: .public)") }

    func synchronize(flags: FSSyncFlags) async throws {
        if readOnly { return }
        try locked { () -> Int32 in HFS_fsOps.fsops_sync!(rootItem.node) }.check()
    }

    func unmount() async {
        guard !readOnly else { return }
        locked { _ = HFS_fsOps.fsops_sync!(rootItem.node) }
    }

    func deactivate(options: FSDeactivateOptions) async throws {
        if closed { return }
        closed = true
        timer?.cancel()
        let r: Int32 = locked {
            let r: Int32
            if readOnly { r = HFS_fsOps.fsops_unmount!(rootItem.node, UVFSUnmountHint(rawValue: 0)) }
            else { r = lifs_unmount_clean(rootItem.node) }        // Journal vollstaendig einspielen (start==end)
            return r
        }
        let st = lifs_dev_stats
        log.notice("STATS unmount=\(r) nutz_geschrieben=\(self.userBytesWritten) dev_writes=\(st.writes) dev_bytes=\(st.bytes) max_cmd=\(st.max_cmd) max_call=\(st.max_call) chunked=\(st.chunked_calls) syncs=\(st.syncs) ro=\(self.readOnly ? 1 : 0) ro_blockiert=\(self.roBlocked) dev_schreibversuche=\(self.backend.writeAttempts) swift_dev_writes=\(self.backend.devWrites) swift_max=\(self.backend.devMax)")
        let be = backend
        be.statLock.lock()                                   // Direktweg-Lesungen koennen noch zaehlen: Werte konsistent kopieren
        let c = (be.rdCalls, be.rdBytes, be.rdHist, be.rdNanos, be.volReads, be.maxWaiting, be.waitNanos, be.directReads, be.fallbackReads, be.decmpfsReads, be.maxInflight)
        let ops = (be.opGetattr, be.opLookup, be.opReaddir, be.opReclaim)
        let kl = be.klein, kk = be.kleinKB, vr = (be.volReadBytes, be.volNonSeq, be.volDoppeltBytes, be.volDateien)
        be.statLock.unlock()
        log.notice("STATS-LESEN dev_reads=\(c.0) dev_read_bytes=\(c.1) hist_le128k=\(c.2[0]) hist_le512k=\(c.2[1]) hist_le1m=\(c.2[2]) dev_read_ms=\(c.3 / 1_000_000) vol_reads=\(c.4) max_wartend=\(c.5) lock_wait_ms=\(c.6 / 1_000_000) direkt_reads=\(c.7) fallback_reads=\(c.8) decmpfs_reads=\(c.9) max_dev_read_parallel=\(c.10) direktweg=\(self.directRead ? 1 : 0) drobo_bau=\(droboBau) fehler_bau=\(fehlerBau)")
        log.notice("STATS-KLEIN le128k nach Bereich: bitmap=\(kl[0])/\(kk[0])KiB extents=\(kl[1])/\(kk[1])KiB katalog=\(kl[2])/\(kk[2])KiB attribute=\(kl[3])/\(kk[3])KiB sonst=\(kl[4])/\(kk[4])KiB | FSKit-Ebene: vol_read_bytes=\(vr.0) vol_nonseq=\(vr.1) vol_doppelt_bytes=\(vr.2) vol_dateien=\(vr.3) | Baumfenster: treffer=\(be.fensterTreffer) lesungen=\(be.fensterLesungen) an=\(be.fensterAn ? 1 : 0) | Operationen: getattr=\(ops.0) lookup=\(ops.1) readdir=\(ops.2) reclaim=\(ops.3)")
        backend.unregister()
        try check(r)
    }

    // MARK: Items
    private func wrap(_ n: Node) -> HItem {
        if let it = items[n] { it.refs += 1; return it }
        let it = HItem(n); items[n] = it; return it
    }
    private func item(_ i: FSItem) throws -> HItem { guard let h = i as? HItem else { throw posixError(EINVAL) }; return h }

    private func convert(_ u: UVFSFileAttributes) -> FSItem.Attributes {
        let a = FSItem.Attributes()
        let t: FSItem.ItemType, ifmt: UInt32
        switch Int(u.fa_type) {
        case UVFS_FA_TYPE_DIR: t = .directory; ifmt = UInt32(S_IFDIR)
        case UVFS_FA_TYPE_SYMLINK: t = .symlink; ifmt = UInt32(S_IFLNK)
        default: t = .file; ifmt = UInt32(S_IFREG)
        }
        a.type = t
        a.mode = ifmt | (u.fa_mode & 0o7777)
        a.linkCount = u.fa_nlink
        a.uid = u.fa_uid; a.gid = u.fa_gid; a.flags = u.fa_bsd_flags
        a.size = u.fa_size; a.allocSize = u.fa_allocsize
        a.fileID = FSItem.Identifier(rawValue: u.fa_fileid) ?? .invalid
        a.parentID = FSItem.Identifier(rawValue: u.fa_parentid) ?? .invalid
        a.accessTime = u.fa_atime; a.modifyTime = u.fa_mtime; a.changeTime = u.fa_ctime; a.birthTime = u.fa_birthtime
        return a
    }

    func attributes(_ req: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        backend.opZaehlen(0)
        let it = try self.item(item)
        var u = UVFSFileAttributes()
        try locked { HFS_fsOps.fsops_getattr!(it.node, &u) }.check()
        return convert(u)
    }

    func setAttributes(_ new: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        if readOnly { try rofail() }
        let it = try self.item(item)
        var u = UVFSFileAttributes()
        var consumed: FSItem.Attribute = []
        if new.isValid(.mode) { u.fa_validmask |= vMODE; u.fa_mode = new.mode & 0o7777; consumed.insert(.mode) }
        if new.isValid(.uid) { u.fa_validmask |= vUID; u.fa_uid = new.uid; consumed.insert(.uid) }
        if new.isValid(.gid) { u.fa_validmask |= vGID; u.fa_gid = new.gid; consumed.insert(.gid) }
        if new.isValid(.flags) { u.fa_validmask |= vFLAGS; u.fa_bsd_flags = new.flags; consumed.insert(.flags) }
        if new.isValid(.size) { u.fa_validmask |= vSIZE; u.fa_size = new.size; consumed.insert(.size) }
        if new.isValid(.accessTime) { u.fa_validmask |= vATIME; u.fa_atime = new.accessTime; consumed.insert(.accessTime) }
        if new.isValid(.modifyTime) { u.fa_validmask |= vMTIME; u.fa_mtime = new.modifyTime; consumed.insert(.modifyTime) }
        if new.isValid(.birthTime) { u.fa_validmask |= vBIRTH; u.fa_birthtime = new.birthTime; consumed.insert(.birthTime) }
        var out = UVFSFileAttributes()
        if u.fa_validmask != 0 { try locked { HFS_fsOps.fsops_setattr!(it.node, &u, &out) }.check() }
        else { try locked { HFS_fsOps.fsops_getattr!(it.node, &out) }.check() }
        new.consumedAttributes = consumed
        return convert(out)
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        backend.opZaehlen(1)
        let d = try item(directory)
        return try locked { () throws -> (FSItem, FSFileName) in
            var out: Node? = nil
            let r = withName(name) { HFS_fsOps.fsops_lookup!(d.node, $0, &out) }
            try check(r)
            guard let n = out else { throw posixError(ENOENT) }
            return (wrap(n), name)
        }
    }

    func reclaimItem(_ item: FSItem) async throws {
        backend.opZaehlen(3)
        let it = try self.item(item)
        locked {
            if it === rootItem { return }                      // Wurzel gehoert dem Mount (LFHFS_Unmount)
            items[it.node] = nil
            for _ in 0..<it.refs { _ = HFS_fsOps.fsops_reclaim!(it.node, 0) }
            it.refs = 0
        }
    }

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        let it = try self.item(item)
        var buf = [UInt8](repeating: 0, count: 4096)
        var act = 0
        var a = UVFSFileAttributes()
        try locked { buf.withUnsafeMutableBytes { HFS_fsOps.fsops_readlink!(it.node, $0.baseAddress, 4096, &act, &a) } }.check()
        return FSFileName(data: Data(buf[0..<act]))
    }

    private func setAttrs(_ a: FSItem.SetAttributesRequest, dir: Bool) -> UVFSFileAttributes {
        var u = UVFSFileAttributes()
        u.fa_validmask = vMODE
        u.fa_mode = a.isValid(.mode) ? a.mode & 0o7777 : (dir ? 0o755 : 0o644)
        if a.isValid(.uid) { u.fa_validmask |= vUID; u.fa_uid = a.uid }
        if a.isValid(.gid) { u.fa_validmask |= vGID; u.fa_gid = a.gid }
        var c: FSItem.Attribute = [.mode]
        if a.isValid(.uid) { c.insert(.uid) }
        if a.isValid(.gid) { c.insert(.gid) }
        a.consumedAttributes = c
        return u
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        if readOnly { try rofail() }
        let d = try item(directory)
        guard type == .file || type == .directory else { throw posixError(ENOTSUP) }
        var u = setAttrs(attributes, dir: type == .directory)
        return try locked { () throws -> (FSItem, FSFileName) in
            var out: Node? = nil
            let r = withName(name) { type == .directory ? HFS_fsOps.fsops_mkdir!(d.node, $0, &u, &out) : HFS_fsOps.fsops_create!(d.node, $0, &u, &out) }
            try check(r)
            guard let n = out else { throw posixError(EIO) }
            return (wrap(n), name)
        }
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        if readOnly { try rofail() }
        let d = try item(directory)
        var u = setAttrs(attributes, dir: false)
        return try locked { () throws -> (FSItem, FSFileName) in
            var out: Node? = nil
            let r = withName(name) { nm in withName(contents) { HFS_fsOps.fsops_symlink!(d.node, nm, $0, &u, &out) } }
            try check(r)
            guard let n = out else { throw posixError(EIO) }
            return (wrap(n), name)
        }
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        if readOnly { try rofail() }
        let src = try self.item(item), d = try self.item(directory)
        var af = UVFSFileAttributes(), ad = UVFSFileAttributes()
        try locked { withName(name) { HFS_fsOps.fsops_link!(src.node, d.node, $0, &af, &ad) } }.check()
        return name
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        if readOnly { try rofail() }
        let it = try self.item(item), d = try self.item(directory)
        var a = UVFSFileAttributes()
        try locked { () -> Int32 in
            _ = HFS_fsOps.fsops_getattr!(it.node, &a)
            return withName(name) { Int(a.fa_type) == UVFS_FA_TYPE_DIR ? HFS_fsOps.fsops_rmdir!(d.node, $0, nil) : HFS_fsOps.fsops_remove!(d.node, $0, it.node) }
        }.check()
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?) async throws -> FSFileName {
        if readOnly { try rofail() }
        let it = try self.item(item), sd = try self.item(sourceDirectory), dd = try self.item(destinationDirectory)
        let over = try overItem.map { try self.item($0) }
        try locked { withName(sourceName) { s in withName(destinationName) { d in
            HFS_fsOps.fsops_rename!(sd.node, it.node, s, dd.node, over?.node, d, 0) } } }.check()
        return destinationName
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        backend.opZaehlen(2)
        let d = try item(directory)
        let wantAttrs = attributes != nil
        var cur = UInt64(cookie.rawValue)
        var ver = UInt64(verifier.rawValue)
        let chunk = UnsafeMutablePointer<lifs_dirent_t>.allocate(capacity: 32)
        defer { chunk.deallocate() }
        while true {
            var n: Int32 = 0
            let r = locked { lifs_readdir_chunk(d.node, cur, &ver, wantAttrs ? 1 : 0, chunk, 32, &n) }
            if r == -1 { break }                                  // UVFS_READDIR_EOF_REACHED
            if r != 0 { throw posixError(r > 0 ? r : EIO) }
            if n == 0 { break }
            for i in 0..<Int(n) {
                let e = chunk[i]
                let nameData = withUnsafeBytes(of: e.name) { Data($0.prefix(Int(e.namelen))) }
                let type: FSItem.ItemType = Int(e.type) == UVFS_FA_TYPE_DIR ? .directory : (Int(e.type) == UVFS_FA_TYPE_SYMLINK ? .symlink : .file)
                let ok = packer.packEntry(name: FSFileName(data: nameData), itemType: type,
                                          itemID: FSItem.Identifier(rawValue: e.fileid) ?? .invalid,
                                          nextCookie: FSDirectoryCookie(rawValue: e.nextcookie),
                                          attributes: wantAttrs ? convert(e.attrs) : nil)
                if !ok { return FSDirectoryVerifier(rawValue: ver == 0 ? 1 : ver) }
                cur = e.nextcookie
            }
            if cur == UInt64.max { break }
        }
        return FSDirectoryVerifier(rawValue: ver == 0 ? 1 : ver)
    }

    // MARK: Lesen / Schreiben
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        let it = try self.item(item)
        let n = try readCore(it, offset, min(length, buffer.length), buffer)
        let b = backend, end = Int64(offset) + Int64(n)                // Diagnose: ausgelieferte Bytes, Reihenfolge, Doppellesungen
        b.statLock.lock()
        if !it.gesehen { it.gesehen = true; b.volDateien += 1 }
        if Int64(offset) != it.lastEnd { b.volNonSeq += 1 }
        if n > 0 && end <= 1 << 36 {                                      // Seiten, die schon einmal ausgeliefert wurden (nicht: nur spaeter einlaufende Lesungen)
            let p0 = Int(Int64(offset) >> 12), p1 = Int((end - 1) >> 12)
            if it.seiten.count <= p1 >> 6 { it.seiten += [UInt64](repeating: 0, count: (p1 >> 6) + 1 - it.seiten.count) }
            for p in p0...p1 { let w = p >> 6, m = UInt64(1) << UInt64(p & 63); if it.seiten[w] & m != 0 { b.volDoppeltBytes += 4096 } else { it.seiten[w] |= m } }
        }
        it.lastEnd = end; b.volReadBytes += UInt64(n)
        b.statLock.unlock()
        return n
    }

    private func readCore(_ it: HItem, _ offset: off_t, _ want: Int, _ buffer: FSMutableFileDataBuffer) throws -> Int {
        var act = 0
        let b = backend
        b.statLock.lock(); b.volReads += 1; b.statLock.unlock()
        // Hebel B (nur nurlesen): unter libLock nur die Zuordnung Datei -> Geraet, das Lesen selbst ausserhalb, parallel. Alles andere: alter Weg.
        if directRead {
            var ext = [lifs_extent_t](repeating: lifs_extent_t(), count: 16)
            var n: Int32 = 0, total: UInt64 = 0
            let node = it.node
            let rc: Int32 = timedLock(b) { lifs_map_read(node, UInt64(offset), UInt64(want), &ext, 16, &n, &total) }
            if rc == 0 {
                if total > 0 {
                    try buffer.withUnsafeMutableBytes { raw in
                        var pos = 0
                        for e in ext[0..<Int(n)] { try b.readDirect(raw.baseAddress! + pos, Int(e.len), Int64(e.dev_off)); pos += Int(e.len) }
                    }
                }
                b.statLock.lock(); b.directReads += 1; b.statLock.unlock()
                return Int(total)
            }
            if rc == 2 { return try readCompressed(node, offset, want, buffer) }
        }
        b.statLock.lock(); b.fallbackReads += 1; b.statLock.unlock()
        var comp = false
        let r: Int32 = timedLock(b) {
            if lifs_is_compressed(it.node) != 0 { comp = true; return 0 }                   // nie ueber die (leere) Datengabel: liefert 0 Bytes ohne Fehler
            return buffer.withUnsafeMutableBytes { HFS_fsOps.fsops_read!(it.node, UInt64(offset), want, $0.baseAddress, &act) }
        }
        if comp { return try readCompressed(it.node, offset, want, buffer) }
        try check(r)
        if act < want {                                                                      // Kurzlesung ist nur am Dateiende zulaessig; sonst wuerde FSKit den ungefuellten Puffer ausliefern
            var u = UVFSFileAttributes()
            _ = locked { HFS_fsOps.fsops_getattr!(it.node, &u) }
            if UInt64(offset) + UInt64(act) < u.fa_size { log.error("Kurzlesung off=\(offset) want=\(want) act=\(act) size=\(u.fa_size)"); throw posixError(EIO) }
        }
        return act
    }

    /// Komprimierte Datei (decmpfs Typ 7/8), siehe Decmpfs.swift. Fehler -> EIO, keine Bytes.
    private func readCompressed(_ node: Node, _ offset: off_t, _ want: Int, _ buffer: FSMutableFileDataBuffer) throws -> Int {
        let b = backend
        b.statLock.lock(); b.decmpfsReads += 1; b.statLock.unlock()
        return try locked { try buffer.withUnsafeMutableBytes { try Decmpfs.read(node: node, offset: UInt64(offset), want: want, dst: $0.baseAddress!) } }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        if readOnly { try rofail() }
        let it = try self.item(item)
        var act = 0
        let r: Int32 = locked { contents.withUnsafeBytes { HFS_fsOps.fsops_write!(it.node, UInt64(offset), contents.count, $0.baseAddress, &act) } }
        try check(r)
        userBytesWritten += UInt64(act)
        return act
    }

    // MARK: xattr
    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
        let it = try self.item(item)
        return try locked { () throws -> Data in
            var size = 0
            var r = withName(name) { HFS_fsOps.fsops_getxattr!(it.node, $0, nil, 0, &size) }
            try check(r)
            var buf = [UInt8](repeating: 0, count: max(size, 1))
            var act = 0
            r = withName(name) { nm in buf.withUnsafeMutableBytes { HFS_fsOps.fsops_getxattr!(it.node, nm, $0.baseAddress, size, &act) } }
            try check(r)
            return Data(buf[0..<min(act, size)])
        }
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy) async throws {
        if readOnly { try rofail() }
        let it = try self.item(item)
        let how: UVFSXattrHow
        switch policy {
        case .alwaysSet: how = UVFSXattrHowSet
        case .mustCreate: how = UVFSXattrHowCreate
        case .mustReplace: how = UVFSXattrHowReplace
        case .delete: how = UVFSXattrHowRemove
        @unknown default: throw posixError(EINVAL)
        }
        let v = value ?? Data()
        try locked { withName(name) { nm in v.withUnsafeBytes { HFS_fsOps.fsops_setxattr!(it.node, nm, $0.baseAddress, v.count, how) } } }.check()
    }

    func xattrs(of item: FSItem) async throws -> [FSFileName] {
        let it = try self.item(item)
        return try locked { () throws -> [FSFileName] in
            var size = 0
            try check(HFS_fsOps.fsops_listxattr!(it.node, nil, 0, &size))
            if size == 0 { return [] }
            var buf = [UInt8](repeating: 0, count: size)
            var act = 0
            try check(buf.withUnsafeMutableBytes { HFS_fsOps.fsops_listxattr!(it.node, $0.baseAddress, size, &act) })
            return buf[0..<min(act, size)].split(separator: 0, omittingEmptySubsequences: true).map { FSFileName(data: Data($0)) }
        }
    }
}

private extension Int32 { func check() throws { if self != 0 { throw posixError(self > 0 ? self : EIO) } } }
