"""Place local raw binaries beside the packages named in checksums.txt."""

import hashlib
import json
import shutil
from pathlib import Path


def main():
    dist = Path("dist")
    artifacts = json.loads((dist / "artifacts.json").read_text())
    binaries = [
        item
        for item in artifacts
        if item["type"] == "Binary" and item["name"] != Path(item["path"]).name
    ]
    packages = [item for item in artifacts if item["type"] == "Linux Package"]

    targets = {"x86_64-linux", "x86-linux", "aarch64-linux"}
    formats = {"deb", "rpm", "archlinux"}
    arches = {"amd64", "386", "arm64"}
    if {item["target"] for item in binaries} != targets or len(binaries) != 3:
        raise SystemExit("expected one raw binary for each Linux target")
    if {(item["goarch"], item["extra"]["Format"]) for item in packages} != {
        (arch, format_name) for arch in arches for format_name in formats
    } or len(packages) != 9:
        raise SystemExit("expected deb, rpm, and Arch packages for each Linux target")

    for item in binaries:
        source = Path(item["path"])
        destination = dist / item["name"]
        shutil.copy2(source, destination)
        shutil.copy2(Path(f"{source}.sig"), Path(f"{destination}.sig"))

    for item in packages:
        signature = Path(f"{item['path']}.sig")
        if not signature.is_file():
            raise SystemExit(f"missing package signature: {signature}")

    checksum = dist / "checksums.txt"
    if not Path(f"{checksum}.sig").is_file():
        raise SystemExit("missing checksum signature")
    for line in checksum.read_text().splitlines():
        expected, name = line.split("  ", 1)
        actual = hashlib.sha256((dist / name).read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit(f"checksum mismatch: {name}")


if __name__ == "__main__":
    main()
