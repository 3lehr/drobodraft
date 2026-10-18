#!/usr/bin/env python3
"""Pull the BB-P02 VM only when its worst-case disk fits with a safety reserve."""
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD = ROOT / "blockbruecke/build"
TART_HOME = BUILD / "tart-home"
TART = BUILD / "tools/tart.app/Contents/MacOS/tart"
IMAGE = "ghcr.io/cirruslabs/macos-tahoe-base@sha256:4aaa751fa7538902d73c767f27a066fc87e83f183069da4e4b5022863abd4c77"
MAX_DISK_BYTES = 50_000_000_000
MIN_RESERVE_BYTES = 20 * 1024**3
STOP_FREE_BYTES = 28 * 1024**3
DEADLINE_SECONDS = 20 * 60
STALL_SECONDS = 90
LOG = BUILD / "tart-safe-pull.log"


def enough_space(free_bytes):
    return free_bytes >= MAX_DISK_BYTES + MIN_RESERVE_BYTES


def must_stop(free_bytes, elapsed, now, last_progress, retry_seen):
    return (free_bytes <= STOP_FREE_BYTES or elapsed >= DEADLINE_SECONDS
            or (retry_seen and now - last_progress >= STALL_SECONDS))


def pull_succeeded(exit_code, abort_reason):
    return exit_code == 0 and abort_reason is None


def process_stopped(exit_code):
    return exit_code is not None


def image_is_pinned(image):
    return "@sha256:" in image


def self_test():
    required = MAX_DISK_BYTES + MIN_RESERVE_BYTES
    assert required == 71_474_836_480
    assert not enough_space(64 * 1024**3)
    assert enough_space(required)
    assert not enough_space(required - 1)
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
    assert must_stop(STOP_FREE_BYTES + 1, DEADLINE_SECONDS, DEADLINE_SECONDS, 0, False)
    assert must_stop(STOP_FREE_BYTES + 1, 91, 91, 0, True)
    assert not must_stop(STOP_FREE_BYTES + 1, 10, 10, 0, False)
    print("PASS mutation checks: :latest rejected; rc=0 after abort rejected")
    print("PASS Tart pull guard selftest: capacity, reserve, deadline, stalled retry")


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
    shutil.rmtree(TART_HOME)
    TART_HOME.mkdir()


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if sys.argv[1:]:
        print("usage: tart_safe_pull.py [--self-test]", file=sys.stderr)
        return 2

    free = shutil.disk_usage(BUILD).free
    required = MAX_DISK_BYTES + MIN_RESERVE_BYTES
    print(f"preflight: free={free} bytes ({free / 1024**3:.2f} GiB); "
          f"required={required} bytes ({required / 1024**3:.2f} GiB)")
    if not enough_space(free):
        print("FAIL Tart pull refused before network: 50 GB disk plus 20 GiB reserve does not fit")
        return 2
    if not TART.is_file():
        print(f"FAIL Tart binary missing: {TART}", file=sys.stderr)
        return 2
    if TART_HOME.is_symlink() or not TART_HOME.is_dir() or any(TART_HOME.iterdir()):
        print(f"FAIL isolated TART_HOME must exist and be empty: {TART_HOME}", file=sys.stderr)
        return 2
    if LOG.exists():
        print(f"FAIL refusing to overwrite existing log: {LOG}", file=sys.stderr)
        return 2

    env = dict(os.environ, TART_HOME=str(TART_HOME))
    started = time.monotonic()
    last_progress = started
    last_log_size = 0
    last_free = free
    retry_seen = False
    abort_reason = None
    with LOG.open("xb") as log:
        process = subprocess.Popen(
            [str(TART), "pull", "--concurrency", "1", IMAGE],
            cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
        )
        print(f"pull started: pid={process.pid}; deadline={DEADLINE_SECONDS}s; stop-free=28 GiB")
        try:
            while process.poll() is None:
                now = time.monotonic()
                free = shutil.disk_usage(BUILD).free
                log_size = LOG.stat().st_size
                if log_size != last_log_size or free != last_free:
                    last_progress = now
                last_log_size, last_free = log_size, free
                if log_size:
                    with LOG.open("rb") as progress_log:
                        progress_log.seek(max(0, log_size - 32768))
                        retry_seen = b"attempting to re-try" in progress_log.read()
                elapsed = now - started
                if must_stop(free, elapsed, now, last_progress, retry_seen):
                    abort_reason = ("free-space guard" if free <= STOP_FREE_BYTES else
                                    "deadline" if elapsed >= DEADLINE_SECONDS else "stalled retry")
                    print(f"STOP {abort_reason}: free={free / 1024**3:.2f} GiB elapsed={elapsed:.0f}s")
                    break
                time.sleep(1)
            rc = stop_process(process) if process.poll() is None else process.returncode
        except BaseException:
            rc = stop_process(process)
            if process_stopped(rc):
                clear_partial_home()
            else:
                print(f"FAIL Tart did not stop; leaving TART_HOME intact; pid={process.pid}", file=sys.stderr)
            raise

    if not process_stopped(rc):
        print(f"FAIL Tart did not stop; leaving TART_HOME intact; pid={process.pid}; log={LOG}", file=sys.stderr)
        return 3
    if not pull_succeeded(rc, abort_reason):
        # TART_HOME was empty on entry; remove only this attempt's incomplete files.
        clear_partial_home()
        print(f"FAIL Tart pull exit={rc}; reason={abort_reason or 'child failure'}; "
              f"partial isolated TART_HOME removed; log={LOG}")
        return rc or 1
    print(f"PASS Tart pull complete; log={LOG}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
