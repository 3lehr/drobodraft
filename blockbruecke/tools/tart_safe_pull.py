#!/usr/bin/env python3
"""Pull the BB-P02 VM only when its worst-case disk fits with a safety reserve."""
import importlib.util
import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import sys
import time
import contextlib
import io

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD = ROOT / "blockbruecke/build"
STORAGE_CONFIG = os.environ.get("DROBO_VM_STORAGE_CONFIG")
STORAGE_ROOT = BUILD
BACKING_ROOT = BUILD
BACKING_IMAGE = None
TART_HOME = STORAGE_ROOT / "tart-home"
TART = BUILD / "tools/tart.app/Contents/MacOS/tart"
CAFFEINATE = pathlib.Path("/usr/bin/caffeinate")
IMAGE = "ghcr.io/cirruslabs/macos-tahoe-base@sha256:4aaa751fa7538902d73c767f27a066fc87e83f183069da4e4b5022863abd4c77"
MAX_DISK_BYTES = 50_000_000_000
MIN_RESERVE_BYTES = 20 * 1024**3
EXTERNAL_BACKING_MIN_BYTES = 149 * 1024**3
MAX_CONTAINER_BYTES = 128 * 1024**3
STOP_FREE_BYTES = 28 * 1024**3
DEADLINE_SECONDS = 120 * 60
STALL_SECONDS = 90
LOG = STORAGE_ROOT / "tart-safe-pull.log"
RESUME_MARKER = STORAGE_ROOT / "tart-safe-pull.resume.json"
HDIUTIL = "/usr/bin/hdiutil"


def storage_config_paths(config):
    required = {"backing_image", "mountpoint", "tart_home"}
    if not isinstance(config, dict) or set(config) != required or not all(isinstance(p, str) for p in config.values()):
        raise ValueError("storage config must contain exactly backing_image, mountpoint, tart_home")
    paths = {key: pathlib.Path(config[key]).expanduser() for key in required}
    if any(not path.is_absolute() or ".." in path.parts for path in paths.values()):
        raise ValueError("storage config paths must be normalized absolute paths")
    if paths["tart_home"] != paths["mountpoint"] / "tart-home":
        raise ValueError("tart_home must be inside the configured APFS mount")
    return paths


def mounted_image_pairs(info_plist):
    info = plistlib.loads(info_plist)
    pairs = set()
    for image in info.get("images", []):
        image_path = image.get("image-path")
        if not image_path:
            continue
        for entity in image.get("system-entities", []):
            mountpoint = entity.get("mount-point")
            if mountpoint:
                pairs.add((pathlib.Path(image_path).resolve(), pathlib.Path(mountpoint).resolve()))
    return pairs


def find_mount(path):
    current = pathlib.Path(path)
    while current != current.parent:
        if current.is_mount():
            return current
        current = current.parent
    return None


def validate_storage_root():
    global STORAGE_ROOT, BACKING_ROOT, BACKING_IMAGE, TART_HOME, LOG, RESUME_MARKER
    if not STORAGE_CONFIG:
        STORAGE_ROOT = BUILD
        BACKING_ROOT = BUILD
        BACKING_IMAGE = None
        TART_HOME = BUILD / "tart-home"
        LOG = BUILD / "tart-safe-pull.log"
        RESUME_MARKER = BUILD / "tart-safe-pull.resume.json"
        return
    config_path = pathlib.Path(STORAGE_CONFIG).expanduser()
    if not config_path.is_absolute() or config_path.is_symlink() or not config_path.is_file():
        raise ValueError("DROBO_VM_STORAGE_CONFIG must be an absolute regular config file")
    config = json.loads(config_path.read_text())
    paths = storage_config_paths(config)
    image = paths["backing_image"]
    root = paths["mountpoint"]
    if (image.is_symlink() or not (image.is_file() or image.is_dir()) or root.is_symlink()
            or not root.is_dir() or not root.is_mount()):
        raise ValueError("backing image and mounted APFS storage root must exist without symlinks")
    image = image.resolve(strict=True)
    root = root.resolve(strict=True)
    backing_volume = find_mount(image.parent)
    host_volume = find_mount(root.parent)
    if (backing_volume is None or backing_volume.parent != pathlib.Path("/Volumes")
            or image.stat().st_dev != backing_volume.stat().st_dev):
        raise ValueError("backing image must reside on a mounted external volume")
    if host_volume is None or host_volume.parent != pathlib.Path("/Volumes"):
        raise ValueError("APFS mountpoint must be under a mounted volume")
    if root.stat().st_dev == root.parent.stat().st_dev:
        raise ValueError("configured storage root is not a mounted filesystem")
    if not container_size_is_safe(shutil.disk_usage(root).total):
        raise ValueError("mounted APFS container exceeds the 128 GiB budget")
    hdiutil = subprocess.run([HDIUTIL, "info", "-plist"], capture_output=True, check=False)
    if hdiutil.returncode != 0 or (image, root) not in mounted_image_pairs(hdiutil.stdout):
        raise ValueError("configured APFS mount is not attached from the configured backing image")
    STORAGE_ROOT = root
    BACKING_ROOT = backing_volume
    BACKING_IMAGE = image
    TART_HOME = root / "tart-home"
    LOG = root / "tart-safe-pull.log"
    RESUME_MARKER = root / "tart-safe-pull.resume.json"


def enough_space(free_bytes, backing_free_bytes=None, inner_required=None, backing_required=None):
    inner_required = MAX_DISK_BYTES + MIN_RESERVE_BYTES if inner_required is None else inner_required
    if backing_free_bytes is not None and backing_required is None:
        backing_required = EXTERNAL_BACKING_MIN_BYTES
    return (free_bytes >= inner_required
            and (backing_free_bytes is None or backing_free_bytes >= backing_required))


def container_size_is_safe(total_bytes):
    return total_bytes <= MAX_CONTAINER_BYTES


def must_stop(free_bytes, elapsed, now, last_progress, retry_seen, backing_free_bytes=None):
    return (free_bytes <= STOP_FREE_BYTES
            or (backing_free_bytes is not None and backing_free_bytes <= STOP_FREE_BYTES)
            or elapsed >= DEADLINE_SECONDS
            or (retry_seen and now - last_progress >= STALL_SECONDS))


def allocated_bytes(root):
    return sum(path.stat().st_blocks * 512 for path in root.rglob("*")
               if path.is_file() and not path.is_symlink())


def remaining_space_requirements(home_allocated_bytes, container_used_bytes):
    home_used = min(MAX_DISK_BYTES, max(0, home_allocated_bytes))
    container_used = min(MAX_CONTAINER_BYTES, max(0, container_used_bytes))
    inner_required = MAX_DISK_BYTES - home_used + MIN_RESERVE_BYTES
    backing_required = MAX_CONTAINER_BYTES - container_used + MIN_RESERVE_BYTES + 1024**3
    return inner_required, backing_required


def storage_space_state():
    inner = shutil.disk_usage(STORAGE_ROOT)
    home_allocated = allocated_bytes(TART_HOME)
    inner_required, _ = remaining_space_requirements(home_allocated, 0)
    backing = None
    backing_required = None
    if BACKING_IMAGE is not None:
        backing = shutil.disk_usage(BACKING_ROOT).free
        container_used = max(0, inner.total - inner.free)
        _, backing_required = remaining_space_requirements(home_allocated, container_used)
    return inner.free, backing, inner_required, backing_required


def pull_succeeded(exit_code, abort_reason):
    return exit_code == 0 and abort_reason is None


def process_stopped(exit_code):
    return exit_code is not None


def image_is_pinned(image):
    return "@sha256:" in image


def resume_binding_identity(storage_root, backing_image, tart_home):
    return {
        "storage_root": str(pathlib.Path(storage_root).resolve()),
        "backing_image": str(pathlib.Path(backing_image).resolve()) if backing_image is not None else None,
        "tart_home": str(pathlib.Path(tart_home).resolve()),
    }


def validate_resume_state(marker, home, image, binding):
    marker = pathlib.Path(marker)
    home = pathlib.Path(home)
    if marker.is_symlink() or (marker.exists() and not marker.is_file()):
        raise ValueError("resume marker must be a regular file")
    if not marker.exists():
        if any(home.iterdir()):
            raise ValueError("nonempty TART_HOME has no owned resume marker")
        return False
    try:
        saved = json.loads(marker.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("resume marker is unreadable") from error
    if saved != {"image": image, "binding": binding}:
        raise ValueError("resume marker does not match pinned image and storage binding")
    return True


def write_resume_marker(marker, image, binding):
    with pathlib.Path(marker).open("x") as stream:
        json.dump({"image": image, "binding": binding}, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def self_test():
    required = MAX_DISK_BYTES + MIN_RESERVE_BYTES
    image_pin_preflight_self_test()
    assert required == 71_474_836_480
    assert EXTERNAL_BACKING_MIN_BYTES == 149 * 1024**3
    assert MAX_CONTAINER_BYTES == 128 * 1024**3
    assert not container_size_is_safe(70_368_534_421_504)
    assert container_size_is_safe(128 * 1024**3)
    assert not enough_space(64 * 1024**3)
    assert enough_space(required)
    assert not enough_space(required - 1)
    assert not enough_space(required, EXTERNAL_BACKING_MIN_BYTES - 1)
    assert enough_space(required, EXTERNAL_BACKING_MIN_BYTES)
    assert TART_HOME.parent == STORAGE_ROOT
    assert LOG.parent == STORAGE_ROOT
    assert STORAGE_ROOT == BUILD
    assert BACKING_ROOT == BUILD
    storage_config_self_test()
    # Reproduce both former unsafe rules and require each invariant to reject it.
    assert not image_is_pinned("ghcr.io/cirruslabs/macos-tahoe-base:latest")
    assert not pull_succeeded(0, "free-space guard")  # legacy: rc == 0
    assert image_is_pinned(IMAGE)
    assert not pull_succeeded(0, "free-space guard")
    assert not pull_succeeded(0, "deadline")
    assert pull_succeeded(0, None)
    assert not pull_succeeded(1, None)
    assert process_stopped(0)
    assert not process_stopped(None)
    assert must_stop(STOP_FREE_BYTES, 0, 0, 0, False)
    assert must_stop(STOP_FREE_BYTES + 1, 0, 0, 0, False, STOP_FREE_BYTES)
    assert must_stop(STOP_FREE_BYTES + 1, DEADLINE_SECONDS, DEADLINE_SECONDS, 0, False)
    assert must_stop(STOP_FREE_BYTES + 1, 91, 91, 0, True)
    assert not must_stop(STOP_FREE_BYTES + 1, 10, 10, 0, False)
    storage_binding_self_test()
    resume_state_self_test()
    remaining_space_self_test()
    print("PASS mutation checks: :latest rejected; rc=0 after abort rejected")
    print(f"PASS storage binding: TART_HOME, log, and capacity root={STORAGE_ROOT}")
    print("PASS Tart pull guard selftest: capacity, reserve, deadline, stalled retry")


def image_pin_preflight_self_test():
    global IMAGE, validate_storage_root
    old_image, old_argv, old_validator = IMAGE, sys.argv, validate_storage_root
    IMAGE = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
    sys.argv = [old_argv[0]]
    validate_storage_root = lambda: (_ for _ in ()).throw(AssertionError("preflight continued"))
    output = io.StringIO()
    try:
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            assert main() == 2
        assert "pinned" in output.getvalue().lower()
    finally:
        IMAGE, sys.argv, validate_storage_root = old_image, old_argv, old_validator
    print("PASS runtime refuses unpinned image before storage or network side effects")


def storage_binding_self_test():
    # External capacity must independently block before Tart can start.
    import tempfile
    temp_context = tempfile.TemporaryDirectory(prefix="bb-storage-binding-")
    temp_root = pathlib.Path(temp_context.name)
    fake_inner = temp_root / "inner"
    fake_backing = temp_root / "backing"
    fake_image = fake_backing / "vm.sparsebundle"
    fake_home = fake_inner / "tart-home"
    fake_log = fake_inner / "tart-safe-pull.log"
    measured = []
    old_argv = sys.argv
    from types import SimpleNamespace
    module = None
    old_disk_usage = None
    old_popen = None

    try:
        fake_inner.mkdir()
        fake_backing.mkdir()
        spec = importlib.util.spec_from_file_location("_bb_storage_binding_test", __file__)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.STORAGE_CONFIG = "test-config"
        module.STORAGE_ROOT = fake_inner
        module.BACKING_ROOT = fake_backing
        module.BACKING_IMAGE = fake_image
        module.TART_HOME = fake_home
        module.LOG = fake_log
        module.RESUME_MARKER = fake_inner / "resume.json"
        module.validate_storage_root = lambda: None
        required = module.MAX_DISK_BYTES + module.MIN_RESERVE_BYTES
        backing_required = (module.MAX_CONTAINER_BYTES - (module.MAX_CONTAINER_BYTES - required)
                            + module.MIN_RESERVE_BYTES + 1024**3)
        physical_free = backing_required - 1
        def disk_usage(path):
            measured.append(path)
            return SimpleNamespace(free=required if path == fake_inner else physical_free,
                                   total=module.MAX_CONTAINER_BYTES if path == fake_inner else 2 * 1024**4)
        old_disk_usage = module.shutil.disk_usage
        old_popen = module.subprocess.Popen
        module.shutil.disk_usage = disk_usage
        fake_home.mkdir(parents=True, exist_ok=True)
        partial = fake_home / "owned-partial-layer"
        partial.write_bytes(b"verified-partial")
        module.write_resume_marker(
            module.RESUME_MARKER, module.IMAGE,
            module.resume_binding_identity(module.STORAGE_ROOT, module.BACKING_IMAGE, module.TART_HOME),
        )
        spawned = []
        module.TART = SimpleNamespace(is_file=lambda: True)
        module.subprocess.Popen = lambda *args, **kwargs: spawned.append(args)
        sys.argv = [old_argv[0]]
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            assert module.main() == 2
        assert "backing" in output.getvalue().lower()
        assert module.STORAGE_ROOT == fake_inner
        assert module.BACKING_IMAGE == fake_image
        assert module.TART_HOME == fake_home
        assert module.LOG == fake_log
        assert measured == [fake_inner, fake_backing]
        assert not spawned
        assert partial.is_file() and module.RESUME_MARKER.is_file()
    finally:
        if module is not None and old_disk_usage is not None:
            module.shutil.disk_usage = old_disk_usage
            module.subprocess.Popen = old_popen
        temp_context.cleanup()
        sys.argv = old_argv
    print("PASS storage binding measures APFS and backing capacity; low backing free blocks pull")


def storage_config_self_test():
    import tempfile
    with tempfile.TemporaryDirectory(prefix="bb-storage-config-") as temp:
        root = pathlib.Path(temp)
        image = root / "backing.sparsebundle"
        mountpoint = root / "apfs-mount"
        image.touch()
        mountpoint.mkdir()
        config = {
            "backing_image": str(image), "mountpoint": str(mountpoint),
            "tart_home": str(mountpoint / "tart-home"),
        }
        paths = storage_config_paths(config)
        assert paths["mountpoint"] == mountpoint
        payload = plistlib.dumps({"images": [{"image-path": str(image),
            "system-entities": [{"mount-point": str(mountpoint)}]}]})
        assert (image.resolve(), mountpoint.resolve()) in mounted_image_pairs(payload)
        assert (image.resolve(), (root / "wrong-mount").resolve()) not in mounted_image_pairs(payload)


def resume_state_self_test():
    import tempfile
    with tempfile.TemporaryDirectory(prefix="bb-resume-state-") as temp:
        root = pathlib.Path(temp)
        home = root / "tart-home"
        marker = root / "resume.json"
        home.mkdir()
        binding = resume_binding_identity(root, root / "backing.sparsebundle", home)
        assert not validate_resume_state(marker, home, IMAGE, binding)
        (home / "partial-disk").write_bytes(b"verified-task-partial")
        try:
            validate_resume_state(marker, home, IMAGE, binding)
            raise AssertionError("nonempty unmarked home must be rejected")
        except ValueError:
            pass
        write_resume_marker(marker, IMAGE, binding)
        assert validate_resume_state(marker, home, IMAGE, binding)
        try:
            validate_resume_state(marker, home, IMAGE, {**binding, "storage_root": "/other"})
            raise AssertionError("mismatched resource binding must be rejected")
        except ValueError:
            pass
    print("PASS resume marker owns partial state and rejects mismatched bindings")


def remaining_space_self_test():
    initial_inner, initial_backing = remaining_space_requirements(0, 0)
    assert initial_inner == MAX_DISK_BYTES + MIN_RESERVE_BYTES
    assert initial_backing == EXTERNAL_BACKING_MIN_BYTES
    inner, backing = remaining_space_requirements(20 * 1024**3, 20 * 1024**3)
    assert inner == MAX_DISK_BYTES - 20 * 1024**3 + MIN_RESERVE_BYTES
    assert backing == MAX_CONTAINER_BYTES - 20 * 1024**3 + MIN_RESERVE_BYTES + 1024**3
    inner, backing = remaining_space_requirements(70 * 1024**3, 200 * 1024**3)
    assert inner == MIN_RESERVE_BYTES
    assert backing == MIN_RESERVE_BYTES + 1024**3
    print("PASS resumed allocation reduces remaining inner and backing budgets")


def stop_process(process):
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
        try:
            return process.wait(timeout=45)
        except subprocess.TimeoutExpired:
            process.send_signal(signal.SIGTERM)
            try:
                return process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                return None
    return process.returncode


def clear_partial_home():
    binding = resume_binding_identity(STORAGE_ROOT, BACKING_IMAGE, TART_HOME)
    if not validate_resume_state(RESUME_MARKER, TART_HOME, IMAGE, binding):
        raise ValueError("refusing cleanup without this task's resume marker")
    shutil.rmtree(TART_HOME)
    TART_HOME.mkdir()
    RESUME_MARKER.unlink()


def wait_scoped_caffeinate(process):
    if process is None:
        return True
    try:
        process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            return False
    return process.poll() is not None


def main():
    if not image_is_pinned(IMAGE):
        print("FAIL image must be pinned by immutable digest", file=sys.stderr)
        return 2
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if sys.argv[1:]:
        print("usage: tart_safe_pull.py [--self-test]", file=sys.stderr)
        return 2

    try:
        validate_storage_root()
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"FAIL storage binding: {error}", file=sys.stderr)
        return 2

    if TART_HOME.is_symlink() or not TART_HOME.is_dir() or any(TART_HOME.iterdir()):
        # A matching resume marker permits only this task's retained partial image.
        if TART_HOME.is_symlink() or not TART_HOME.is_dir():
            print(f"FAIL isolated TART_HOME must be a real directory: {TART_HOME}", file=sys.stderr)
            return 2
    binding = resume_binding_identity(STORAGE_ROOT, BACKING_IMAGE, TART_HOME)
    try:
        resuming = validate_resume_state(RESUME_MARKER, TART_HOME, IMAGE, binding)
    except (OSError, ValueError) as error:
        print(f"FAIL resume state: {error}", file=sys.stderr)
        return 2
    if not resuming:
        try:
            write_resume_marker(RESUME_MARKER, IMAGE, binding)
        except OSError as error:
            print(f"FAIL creating resume marker: {error}", file=sys.stderr)
            return 2
    if LOG.is_symlink() or (LOG.exists() and not LOG.is_file()):
        print(f"FAIL pull log must be a regular file: {LOG}", file=sys.stderr)
        return 2
    if not TART.is_file():
        print(f"FAIL Tart binary missing: {TART}", file=sys.stderr)
        return 2
    if not CAFFEINATE.is_file():
        print(f"FAIL scoped caffeinate is missing: {CAFFEINATE}", file=sys.stderr)
        return 2

    free, backing_free, required_inner, required_backing = storage_space_state()
    print(f"preflight: storage-free={free} bytes; backing-free={backing_free}; "
          f"inner-required={required_inner}; backing-required={required_backing}; "
          f"resume={'yes' if resuming else 'no'}")
    if not enough_space(free, backing_free, required_inner, required_backing):
        reason = ("backing volume lacks remaining container growth plus reserve"
                  if backing_free is not None and backing_free < required_backing
                  else "mounted storage lacks remaining disk growth plus reserve")
        print(f"FAIL Tart pull refused before network: {reason}")
        return 2

    env = dict(os.environ, TART_HOME=str(TART_HOME), TART_NO_AUTO_PRUNE="1")
    started = time.monotonic()
    last_progress = started
    log_offset = LOG.stat().st_size if LOG.exists() else 0
    last_log_size = log_offset
    last_free = free
    last_backing_free = backing_free
    retry_seen = False
    abort_reason = None
    process = None
    caffeinate = None
    with LOG.open("ab") as log:
        try:
            process = subprocess.Popen(
                [str(TART), "pull", "--concurrency", "4", IMAGE],
                cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
            )
            caffeinate = subprocess.Popen(
                [str(CAFFEINATE), "-i", "-w", str(process.pid)],
                cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            print(f"pull started: pid={process.pid}; caffeinate-pid={caffeinate.pid}; "
                  f"deadline={DEADLINE_SECONDS}s; concurrency=4; stop-free=28 GiB")
            while process.poll() is None:
                if caffeinate.poll() is not None:
                    abort_reason = "scoped caffeinate exited"
                    break
                now = time.monotonic()
                free, backing_free, required_inner, required_backing = storage_space_state()
                log_size = LOG.stat().st_size
                if (log_size != last_log_size or free != last_free
                        or backing_free != last_backing_free):
                    last_progress = now
                last_log_size, last_free, last_backing_free = log_size, free, backing_free
                if log_size:
                    with LOG.open("rb") as progress_log:
                        progress_log.seek(max(log_offset, log_size - 32768))
                        retry_seen = b"attempting to re-try" in progress_log.read()
                elapsed = now - started
                if not enough_space(free, backing_free, required_inner, required_backing):
                    abort_reason = "remaining-capacity guard"
                    print(f"STOP {abort_reason}: storage-free={free}; backing-free={backing_free}; "
                          f"elapsed={elapsed:.0f}s")
                    break
                if must_stop(free, elapsed, now, last_progress, retry_seen, backing_free):
                    abort_reason = ("free-space guard" if free <= STOP_FREE_BYTES
                                    or (backing_free is not None and backing_free <= STOP_FREE_BYTES) else
                                    "deadline" if elapsed >= DEADLINE_SECONDS else "stalled retry")
                    print(f"STOP {abort_reason}: storage-free={free}; backing-free={backing_free}; "
                          f"elapsed={elapsed:.0f}s")
                    break
                time.sleep(1)
            rc = stop_process(process) if process is not None and process.poll() is None else process.returncode
            if not wait_scoped_caffeinate(caffeinate):
                print(f"FAIL scoped caffeinate did not stop; pid={caffeinate.pid}", file=sys.stderr)
                return 3
        except BaseException:
            if process is not None:
                rc = stop_process(process)
            if caffeinate is not None:
                wait_scoped_caffeinate(caffeinate)
            if abort_reason is not None and process is not None and process_stopped(rc):
                clear_partial_home()
            elif process is not None and not process_stopped(rc):
                print(f"FAIL Tart did not stop; leaving TART_HOME intact; pid={process.pid}", file=sys.stderr)
            raise

    if process is None:
        print("FAIL Tart process was not created", file=sys.stderr)
        return 3
    if not process_stopped(rc):
        print(f"FAIL Tart did not stop; leaving TART_HOME intact; pid={process.pid}; log={LOG}", file=sys.stderr)
        return 3
    if not pull_succeeded(rc, abort_reason):
        if abort_reason is not None:
            clear_partial_home()
            state = "owned partial TART_HOME removed"
        else:
            state = "matching resume state retained"
        print(f"FAIL Tart pull exit={rc}; reason={abort_reason or 'child failure'}; "
              f"{state}; log={LOG}")
        return rc or 1
    RESUME_MARKER.unlink()
    print(f"PASS Tart pull complete; log={LOG}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
