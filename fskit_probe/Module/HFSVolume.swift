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
    init(_ n: Node) { node = n }
}

private func withName<R>(_ n: FSFileName, _ f: (UnsafePointer<CChar>) -> R) -> R {
    var a = n.data.map { CChar(bitPattern: $0) }
    a.append(0)
    return a.withUnsafeBufferPointer { f($0.baseAddress!) }
}
private func check(_ r: Int32) throws { if r != 0 { throw posixError(r > 0 ? r : EIO) } }
private func locked<T>(_ f: () throws -> T) rethrows -> T { libLock.lock(); defer { libLock.unlock() }; return try f() }

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

    init(dev: FSBlockDeviceResource, backend: DeviceBackend, containerUUID: UUID) throws {
        let fd = backend.vfd
        let ro = !dev.isWritable
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
        let name = withUnsafePointer(to: &info.name) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        self.dev = dev; self.backend = backend; self.readOnly = ro
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
        log.notice("STATS unmount=\(r) nutz_geschrieben=\(self.userBytesWritten) dev_writes=\(st.writes) dev_bytes=\(st.bytes) max_cmd=\(st.max_cmd) max_call=\(st.max_call) chunked=\(st.chunked_calls) syncs=\(st.syncs) swift_dev_writes=\(self.backend.devWrites) swift_max=\(self.backend.devMax)")
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
        let it = try self.item(item)
        var u = UVFSFileAttributes()
        try locked { HFS_fsOps.fsops_getattr!(it.node, &u) }.check()
        return convert(u)
    }

    func setAttributes(_ new: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
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
        let src = try self.item(item), d = try self.item(directory)
        var af = UVFSFileAttributes(), ad = UVFSFileAttributes()
        try locked { withName(name) { HFS_fsOps.fsops_link!(src.node, d.node, $0, &af, &ad) } }.check()
        return name
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        let it = try self.item(item), d = try self.item(directory)
        var a = UVFSFileAttributes()
        try locked { () -> Int32 in
            _ = HFS_fsOps.fsops_getattr!(it.node, &a)
            return withName(name) { Int(a.fa_type) == UVFS_FA_TYPE_DIR ? HFS_fsOps.fsops_rmdir!(d.node, $0, nil) : HFS_fsOps.fsops_remove!(d.node, $0, it.node) }
        }.check()
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?) async throws -> FSFileName {
        let it = try self.item(item), sd = try self.item(sourceDirectory), dd = try self.item(destinationDirectory)
        let over = try overItem.map { try self.item($0) }
        try locked { withName(sourceName) { s in withName(destinationName) { d in
            HFS_fsOps.fsops_rename!(sd.node, it.node, s, dd.node, over?.node, d, 0) } } }.check()
        return destinationName
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
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
        let want = min(length, buffer.length)
        var act = 0
        let r: Int32 = locked { buffer.withUnsafeMutableBytes { HFS_fsOps.fsops_read!(it.node, UInt64(offset), want, $0.baseAddress, &act) } }
        try check(r)
        return act
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
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
