import ExtensionFoundation
import FSKit

@main
struct DroboHFSExtension: UnaryFileSystemExtension {
    var fileSystem: HFSFileSystem { HFSFileSystem() }
}
