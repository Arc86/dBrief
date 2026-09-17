"""Synthetic macOS arm64 diagnostic. The injected child intentionally crashes.

Run: python3 docs/diagnostics/executor-exception-probe/run.py
All compiler outputs/logs go to a newly created temporary directory.
No audio devices, recordings, preferences, or installed applications are used.
"""

from pathlib import Path
import platform
import resource
import signal
import subprocess
import tempfile


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This probe targets the affected macOS arm64 environment.")
    source = Path(__file__).resolve().parent
    output = Path(tempfile.mkdtemp(prefix="dbrief-executor-probe-"))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    print(f"Diagnostic outputs: {output}", flush=True)
    subprocess.run([
        "clang", "-fobjc-arc", "-c", str(source / "Driver.m"),
        "-o", str(output / "Driver.o"),
    ], check=True)
    subprocess.run([
        "swiftc", "-swift-version", "6", "-g", "-O", "-parse-as-library",
        "-module-cache-path", str(output / "module-cache"),
        "-import-objc-header", str(source / "Bridge.h"),
        str(source / "Probe.swift"), str(output / "Driver.o"),
        "-o", str(output / "probe"), "-framework", "Foundation",
    ], check=True)
    results = {}
    for mode in ("normal", "contained", "inject"):
        result = subprocess.run(
            [str(output / "probe"), mode], capture_output=True,
            text=True, timeout=10,
        )
        results[mode] = result
        transcript = f"{mode} exit: {result.returncode}\n{result.stdout}\n{result.stderr}"
        (output / f"{mode}-result.txt").write_text(transcript)
        print(transcript, flush=True)
    assert results["normal"].returncode == 0, "Normal control failed"
    assert results["contained"].returncode == 0, "Contained-exception control failed"
    assert results["inject"].returncode in (-signal.SIGSEGV, -signal.SIGBUS), (
        "Injected crash did not reproduce; inspect output before drawing conclusions"
    )
    assert "after stack reuse executor: 0x12345678 0x12345678" in results["inject"].stdout, (
        "Expected stale stack-backed executor state was not observed"
    )
    print("Reproduced stale executor state after an exception escapes a Swift task.")
    print("This demonstrates the mechanism, not the original Bluetooth exception.")


if __name__ == "__main__":
    main()
