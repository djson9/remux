#!/usr/bin/env python3
"""Publish an already verified package on the VM, exposing the installer last."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import time
from pathlib import Path
from urllib.request import urlopen


def flush():
    time.sleep(6)
    for _ in range(90):
        status = subprocess.check_output(["systemctl", "show", "b2-mount.service", "--property=StatusText", "--value"], text=True)
        if "to upload 0, uploading 0" in status:
            return
        time.sleep(2)
    raise RuntimeError("B2 writeback did not finish")


def publish(package, destination, base_url):
    package, destination = Path(package), Path(destination)
    if str(destination) != "/mnt/b2/remux-ios-ota":
        raise ValueError("Unexpected OTA destination")
    subprocess.run(["systemctl", "is-active", "--quiet", "b2-mount.service"], check=True)
    subprocess.run(["mountpoint", "-q", "/mnt/b2"], check=True)
    metadata = json.loads((package / "release-metadata.json").read_text())
    build = metadata["buildNumber"]
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Invalid build number")
    if metadata["ipaUrl"] != f"{base_url.rstrip('/')}/{build}/Remux.ipa":
        raise ValueError("Unexpected IPA URL")
    if hashlib.sha256((package / "Remux.ipa").read_bytes()).hexdigest() != metadata["sha256"]:
        raise ValueError("IPA checksum mismatch")
    version = destination / build
    if version.exists():
        existing = version / "release-metadata.json"
        if not existing.exists() or json.loads(existing.read_text()) != metadata:
            raise ValueError("Release already exists with different metadata")
    version.mkdir(parents=True, exist_ok=True)
    for name in ("Remux.ipa", "manifest.plist", "release-metadata.json", "signing-result.json", "index.html"):
        shutil.copyfile(package / name, version / name)
        flush()
    # Verify the bytes delivered to the phone before changing the latest page.
    with urlopen(metadata["ipaUrl"], timeout=120) as response:
        served_digest = hashlib.sha256(response.read()).hexdigest()
    if served_digest != metadata["sha256"]:
        raise ValueError("Served IPA checksum mismatch")
    latest = destination / "latest"
    latest.mkdir(exist_ok=True)
    for name in ("manifest.plist", "release-metadata.json", "index.html"):
        shutil.copyfile(package / name, latest / name)
        flush()
    shutil.copyfile(package / "index.html", destination / "index.html")
    flush()
    with urlopen(base_url.rstrip('/') + "/latest/release-metadata.json", timeout=60) as response:
        if json.load(response) != metadata:
            raise ValueError("Published latest metadata mismatch")
    print(json.dumps({"published": True, "build": build, "sha256": served_digest, "installPage": base_url.rstrip('/') + "/latest/"}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("package")
    parser.add_argument("destination")
    parser.add_argument("base_url")
    args = parser.parse_args()
    publish(args.package, args.destination, args.base_url)
