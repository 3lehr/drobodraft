import FSKit
import Foundation
import os

let hfsLog = Logger(subsystem: "de.begod.drobofsprobe", category: "fs")
func posixError(_ e: Int32) -> Error { fs_errorForPOSIXError(e) }

/// Eine globale Sperre um alle Aufrufe in Apples Bibliothek (sie ist fuer eine serielle Aufrufwelt gebaut; FSKit ruft parallel).
let libLock = NSRecursiveLock()
private var libInitDone = false

final class HFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, FSManageableResourceMaintenanceOperations {
    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let dev = resource as? FSBlockDeviceResource else { return replyHandler(.notRecognized, nil) }
        do {
            let head = try Gate.readHead(dev, 4096)
            if let why = Gate.refusal(dev, head: head) {
                hfsLog.notice("probe \(dev.bsdName, privacy: .public): abgelehnt (\(why, privacy: .public))")
                return replyHandler(.notRecognized, nil)
            }
            guard Gate.isHFSPlus(head) else {
                hfsLog.notice("probe \(dev.bsdName, privacy: .public): Marker, aber kein HFS+")
                return replyHandler(.notRecognized, nil)
            }
            hfsLog.notice("probe \(dev.bsdName, privacy: .public): HFS+ im Testabbild, angenommen")
            replyHandler(.usable(name: "HFS+", containerID: FSContainerIdentifier(uuid: Gate.containerUUID(head))), nil)
        } catch {
            hfsLog.error("probe \(dev.bsdName, privacy: .public) Fehler \(String(describing: error), privacy: .public)")
            replyHandler(nil, error)
        }
    }

    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let dev = resource as? FSBlockDeviceResource, let head = try? Gate.readHead(dev, 4096),
              Gate.refusal(dev, head: head) == nil, Gate.isHFSPlus(head) else {
            hfsLog.error("load: Sperre -> abgelehnt")
            return replyHandler(nil, posixError(EINVAL))
        }
        libLock.lock(); defer { libLock.unlock() }
        if !libInitDone {
            let r = HFS_fsOps.fsops_init!()
            if r != 0 { return replyHandler(nil, posixError(r)) }
            libInitDone = true
        }
        let backend = DeviceBackend(dev: dev)
        guard backend.register() else { return replyHandler(nil, posixError(EMFILE)) }
        do {
            let vol = try HFSVolume(dev: dev, backend: backend, containerUUID: Gate.containerUUID(head))
            containerStatus = .ready
            hfsLog.notice("load \(dev.bsdName, privacy: .public) opts=\(options.taskOptions, privacy: .public) name=\(vol.mountedName, privacy: .public)")
            replyHandler(vol, nil)
        } catch {
            backend.unregister()
            hfsLog.error("load Mount-Fehler \(String(describing: error), privacy: .public)")
            replyHandler(nil, error)
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {}

    // fsck_hfs wird nie gestartet (Spawn gesperrt, Pflicht 3); das Journal wird beim Mount eingespielt.
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        task.didComplete(error: nil)
        return Progress(totalUnitCount: 1)
    }
    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress { throw posixError(ENOTSUP) }
}
