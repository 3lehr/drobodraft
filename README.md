# DroboDraft — frühe Alpha

Native macOS-App (SwiftUI) für die Drobo 5C ohne Kernel-Erweiterung: FSKit-Modul `hfsdrobo` (Apples livefiles_hfs, Schreibbefehle ≤ 512 KiB), privilegierter Hilfsdienst `drobohelper` (nur Geräteknoten-Freigabe und Einhängeordner), Kern `DroboKern` + CLI `drobo`.

Stand: 2026-10-16T08:01:13+0200 · Version 0.1.0 · **frühe Alpha, nicht für fremde Geräte gedacht.**

- `fskit_probe/` – App-Hülle, FSKit-Modul (`Module/`), Hilfsdienst (`Helper/`), Werkzeuge (`tools/`)
- `drobo_kern/` – Swift-Paket DroboKern + CLI
- `livefiles_shim/`, `vendor/hfs-715.100.10/` – Apples HFS-Code (APSL) mit Shim; Eingriffe in `livefiles_shim/INVENTAR.md`
- `dext_probe/` – verworfener DriverKit-Weg (Weg A), als Referenz
- `docs/` – Pläne und Protokoll-Recon

Herausgelöst am 2026-10-16T08:01:13+0200 aus hub-Worktree `drobo-nas` (`apps/drobo-nas/macos`, Historie per `git subtree split`). Linux-VM- und Python-Reparaturwerkzeuge bleiben in `drobo-nas`.

## Lizenz

Eigener Code: MIT (siehe `LICENSE`). Ausgenommen ist Apples HFS-Code unter `vendor/hfs-715.100.10/` samt der dort vorgenommenen Änderungen: Apple Public Source License 2.0 (`vendor/hfs-715.100.10/APPLE_LICENSE`), Änderungen dokumentiert in `livefiles_shim/INVENTAR.md`.

**Warnung:** frühe Alpha. Schreibzugriffe auf Datenträger ohne Backup auf eigenes Risiko; entwickelt und geprüft nur an einer Drobo 5C.
