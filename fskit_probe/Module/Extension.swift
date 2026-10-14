import ExtensionFoundation
import FSKit

@main
struct DroboFSProbeExtension: UnaryFileSystemExtension {
    var fileSystem: ProbeFileSystem { ProbeFileSystem() }
}
