import FSKit
import Foundation
import os

private let log = Logger(subsystem: "de.begod.drobofsprobe", category: "fs")
private func posix(_ e: Int32) -> Error { fs_errorForPOSIXError(e) }

final class ProbeFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, FSManageableResourceMaintenanceOperations {
    // feste Kennung: nur dieses Modul, nur Marker-Medien
    static let containerID = FSContainerIdentifier(uuid: UUID(uuidString: "D20B0F5E-0A0A-4A0A-8A0A-D20B0F5E0A0A")!)

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let dev = resource as? FSBlockDeviceResource else { return replyHandler(.notRecognized, nil) }
        do {
            let ok = try Throughput.hasMarker(dev)
            log.notice("probe \(dev.bsdName, privacy: .public) marker=\(ok)")
            replyHandler(ok ? .usable(name: "DROBOFSPROBE", containerID: Self.containerID) : .notRecognized, nil)
        } catch {
            log.error("probe \(dev.bsdName, privacy: .public) Fehler \(String(describing: error), privacy: .public)")
            replyHandler(nil, error)
        }
    }

    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let dev = resource as? FSBlockDeviceResource, (try? Throughput.hasMarker(dev)) == true else {
            log.error("load: kein Marker -> abgelehnt")
            return replyHandler(nil, posix(EINVAL))
        }
        containerStatus = .ready
        log.notice("load \(dev.bsdName, privacy: .public) opts=\(options.taskOptions, privacy: .public)")
        replyHandler(ProbeVolume(dev: dev), nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {}

    // Block-Dateisysteme muessen eine Pruefung bestehen, bevor gemountet wird.
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        task.didComplete(error: nil)
        return Progress(totalUnitCount: 1)
    }
    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress { throw posix(ENOTSUP) }
}

final class ProbeItem: FSItem {
    let id: FSItem.Identifier
    init(_ id: FSItem.Identifier) { self.id = id }
    var isDir: Bool { id == .rootDirectory }
}

final class ProbeVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {
    static let fileName = "messung.txt"
    let dev: FSBlockDeviceResource
    let root = ProbeItem(.rootDirectory)
    let file = ProbeItem(FSItem.Identifier(rawValue: 3)!)
    var content = Data("noch nicht gemessen\n".utf8)

    init(dev: FSBlockDeviceResource) {
        self.dev = dev
        super.init(volumeID: FSVolume.Identifier(uuid: ProbeFileSystem.containerID.uuid), volumeName: FSFileName(string: "DROBOFSPROBE"))
    }

    // MARK: PathConf / Capabilities
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.caseFormat = .sensitive
        return c
    }
    var volumeStatistics: FSStatFSResult {
        let s = FSStatFSResult(fileSystemTypeName: "drobofsprobe")
        s.blockSize = 4096; s.ioSize = Throughput.chunk
        s.totalBlocks = 1; s.availableBlocks = 0; s.freeBlocks = 0; s.usedBlocks = 1
        s.totalBytes = 4096; s.availableBytes = 0; s.freeBytes = 0; s.usedBytes = 4096
        s.totalFiles = 2; s.freeFiles = 0
        return s
    }

    // MARK: Lebenszyklus
    func activate(options: FSTaskOptions) async throws -> FSItem { root }
    func deactivate(options: FSDeactivateOptions) async throws {}
    func unmount() async {}
    func synchronize(flags: FSSyncFlags) async throws {}

    func mount(options: FSTaskOptions) async throws {
        guard (try? Throughput.hasMarker(dev)) == true else {
            log.error("mount: kein Marker -> abgelehnt")
            throw posix(EINVAL)
        }
        log.notice("mount: Durchsatzmessung startet")
        let text = Throughput.run(dev)
        content = Data(text.utf8)
        for l in text.split(separator: "\n") { log.notice("messung: \(String(l), privacy: .public)") }
    }

    // MARK: Items
    func attributes(_ req: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        guard let it = item as? ProbeItem else { throw posix(EINVAL) }
        let a = FSItem.Attributes()
        let t = timespec(tv_sec: Int(Date().timeIntervalSince1970), tv_nsec: 0)
        a.fileID = it.id
        a.parentID = it.isDir ? .parentOfRoot : .rootDirectory
        a.type = it.isDir ? .directory : .file
        a.mode = it.isDir ? 0o040755 : 0o100644
        a.linkCount = it.isDir ? 2 : 1
        a.uid = 501; a.gid = 20
        a.size = it.isDir ? 4096 : UInt64(content.count)
        a.allocSize = a.size
        a.modifyTime = t; a.changeTime = t; a.accessTime = t; a.birthTime = t
        return a
    }
    func setAttributes(_ new: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        try await attributes(FSItem.GetAttributesRequest(), of: item)
    }
    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        guard name.string == Self.fileName else { throw posix(ENOENT) }
        return (file, name)
    }
    func reclaimItem(_ item: FSItem) async throws {}
    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName { throw posix(EINVAL) }
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) { throw posix(EROFS) }
    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) { throw posix(EROFS) }
    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName { throw posix(EROFS) }
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws { throw posix(EROFS) }
    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?) async throws -> FSFileName { throw posix(EROFS) }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        if cookie == .initial {
            let a = try await self.attributes(FSItem.GetAttributesRequest(), of: file)
            _ = packer.packEntry(name: FSFileName(string: Self.fileName), itemType: .file, itemID: file.id, nextCookie: FSDirectoryCookie(1), attributes: attributes == nil ? nil : a)
        }
        return FSDirectoryVerifier(1)
    }

    // MARK: Lesen (Schreiben nicht unterstuetzt)
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        guard (item as? ProbeItem)?.isDir == false else { throw posix(EISDIR) }
        let start = Int(offset)
        guard start < content.count else { return 0 }
        let n = min(length, content.count - start, buffer.length)
        buffer.withUnsafeMutableBytes { p in
            content.withUnsafeBytes { src in p.baseAddress!.copyMemory(from: src.baseAddress! + start, byteCount: n) }
        }
        return n
    }
    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int { throw posix(EROFS) }
}
