# DroboDraft

**Use a Drobo 5C on a current Mac — read and write — without a kernel extension.**

> ⚠️ **Early alpha.** Developed and tested on a single Drobo 5C (USB, HFS+, 64 TB) with macOS 26.5.1 on Apple Silicon. Writing to a disk without a backup is at your own risk.

![DroboDraft overview window](docs/screens/overview.png)

## The problem

Drobo devices are no longer supported; the Drobo Dashboard and its drivers no longer work on current macOS. A Drobo 5C still shows up as a USB disk and can usually be *read*. **Writing** hangs or disconnects the device: macOS sends write commands of 1 MiB over USB 3, but the Drobo 5C only handles commands up to 512 KiB, and there is no supported way to lower that limit for a USB disk without a kernel extension.

## What DroboDraft does

- **Mounts the Drobo through its own file system module** (FSKit, runs in user space) that never sends a write command larger than 512 KiB. Reading runs at about 180 MB/s (macOS itself: about 190 MB/s on the same files).
- **Read-only by default.** Mounting for writing is a separate, confirmed action.
- **Backs up the file system metadata before every write session** (catalog, extents, attributes, allocation map, volume headers — about 3 GB for a 64 TB volume) and **checks the volume after unmounting**.
- **Safe unplug:** warns if the Drobo disappears while mounted for writing and checks it on the next connect.
- **Copies folders off the Drobo** to another disk, verified with SHA-256, incremental.
- Menu bar item, notifications, read speed test, Shortcuts actions, more than one Drobo.
- No Drobo Dashboard, no kernel extension, no reduced security settings.

Not yet available: drive bay status, protection level and real free space (the Drobo reports a virtual 64 TB size). The user interface is currently German only.

## Requirements

- macOS 26 or later (tested on 26.5.1), Apple Silicon (tested on M4 Pro)
- Drobo 5C connected via USB with an **HFS+** volume
- Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An Apple Developer account: the module and the helper must be signed with your own team — set `DEVELOPMENT_TEAM` in `fskit_probe/project.yml`

## Install

1. Build and install the app to `/Applications` (build files go to `$DD`, default `/Volumes/daten/xcode/drobo` — set `DD` to a folder of your choice):
   ```bash
   cd fskit_probe && DD=~/DroboDraftBuild bash tools/install_module.sh
   ```
2. **Enable the file system module:** System Settings → General → Login Items & Extensions → *File System Extensions* → enable the DroboDraft module. If the switch does not stay on, restart the Mac and check again.
3. **Allow the helper:** open DroboDraft once, then in System Settings → General → Login Items & Extensions → *Allow in the Background* enable *drobohelper*.
4. **Give the helper Full Disk Access:** System Settings → Privacy & Security → Full Disk Access → **+** → press ⌘⇧G and enter `/Applications/DroboFSProbe.app/Contents/MacOS/drobohelper`. Without it, macOS does not let a background helper hand over a USB disk's device to you.

The app bundle is still named `DroboFSProbe.app`; it shows up as *DroboDraft*.

## Use

Open **DroboDraft**, pick your Drobo and click **Einhängen (nur lesen)** (mount read-only) or **Zum Schreiben einhängen** (mount for writing). Mounting for writing first creates and verifies the metadata backup; choose its location in Settings (⌘,) before the first write session — the built-in default `/Volumes/daten/DroboSicherungen` will not exist on your Mac, and the system disk is refused. Always unmount from DroboDraft, not from the Finder, so the volume is checked right away.

Command line equivalent (build with `cd drobo_kern && swift build -c release`; the helper only accepts the CLI when it is signed with your team, see `fskit_probe/tools/sign_cli.sh`):

```bash
drobo status              # connection, mount state, module and helper
drobo einhaengen          # mount read-only (add --schreiben to mount for writing)
drobo aushaengen          # unmount and check
drobo sichern             # metadata backup only
```

If you mount for writing, consider excluding the Drobo from Spotlight (System Settings → Spotlight); otherwise Spotlight writes its own index files to the Drobo.

## How it works

```
Finder / apps
     │  file operations
     ▼
FSKit module "hfsdrobo"   Apple's livefiles HFS+ code, every device write ≤ 512 KiB
     │  block reads and writes
     ▼
/dev/diskNsM              Drobo 5C via USB
```

- **Module** (`fskit_probe/Module`): FSKit file system extension built on Apple's open source `livefiles_hfs` (hfs-715.100.10). A single code path writes to the device and caps every command at 512 KiB. The read path is tuned for slow devices (per-file extent cache, B-tree node cache).
- **Helper** (`fskit_probe/Helper`): a small privileged service. It only hands the Drobo's device node to the logged-in user and back, and creates and removes the mount folder under `/Volumes`. It accepts calls only from DroboDraft's own signed binaries and only for volumes you allowed.
- **Core** (`drobo_kern`): Swift package with all logic (find, check, mount, back up, verify, copy) and the `drobo` command line tool; tests run against disk images.

## Safety notes

- Keep your own backup of anything you cannot lose. The metadata backup protects the file system structure, not your files, and only for the write session it was taken before.
- Do not run `fsck_hfs` with repair options on the Drobo unless you know what you are doing. Even `fsck_hfs -n` opens the device for writing.
- Only the Drobo 5C has been tested. Other models may behave differently.

## License

MIT for this project's code ([LICENSE](LICENSE)). Apple's HFS code in `vendor/hfs-715.100.10/` is under the Apple Public Source License 2.0 ([APPLE_LICENSE](vendor/hfs-715.100.10/APPLE_LICENSE)); changes to it are listed in `livefiles_shim/INVENTAR.md`.

DroboDraft is not affiliated with Drobo, StorCentric or Apple. Development notes (German) are in `docs/`.
