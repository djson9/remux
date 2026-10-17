#!/usr/bin/env python3
"""Build through the pinned GUI signing lane and publish only verified output."""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

from package import package

REPO = Path(__file__).resolve().parents[2]


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def release(build, publish):
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Expected a positive build number")
    if subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"], cwd=REPO, text=True).strip():
        raise ValueError("Release checkout has tracked changes")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()
    pin = (REPO / ".apple-signing-tools-version").read_text().strip()
    signing_tools = Path.home() / ".local/share/apple-signing-tools" / pin
    if subprocess.check_output(["git", "-C", str(signing_tools), "rev-parse", "HEAD"], text=True).strip() != pin:
        raise ValueError("Signing tools do not match the reviewed revision")
    if subprocess.check_output(["git", "-C", str(signing_tools), "status", "--porcelain", "--untracked-files=no"], text=True).strip():
        raise ValueError("Pinned signing tools have tracked changes")
    profile = os.environ["REMUX_PROFILE_UUID"]
    os.environ["DEVICE_UDID"]  # Required membership is independently checked by the lane.
    ruby = Path.home() / ".rbenv/versions/3.2.2/bin/ruby"
    output = Path(tempfile.mkdtemp(prefix="remux-ota-", dir="/tmp"))
    retained = Path.home() / ".local/share/remux/releases" / build
    retained.mkdir(parents=True, exist_ok=False)
    result = retained / "signing-result.json"
    # The caller prepares the generated project and pinned GhosttyKit first.
    run(ruby, signing_tools / "bin/apple-signing-lane", "run", "--manifest", REPO / "scripts/ios/signing.json",
        "--phase", "development", "--result", result, "--", REPO / "scripts/ios/build-signed.sh",
        build, output, revision, profile, cwd=REPO)
    receipt = json.loads(result.read_text())
    if receipt.get("status") != "succeeded":
        raise RuntimeError(f"Signing failed; inspect {result}")
    package_dir = retained / "package"
    package_dir.mkdir()
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", output / "Payload", package_dir / "Remux.ipa")
    shutil.copyfile(output / "Payload/Remux.app/Info.plist", package_dir / "Info.plist")
    shutil.copyfile(result, package_dir / "signing-result.json")
    base_url = os.environ["OTA_BASE_URL"]
    metadata = package(package_dir, base_url, revision)
    print(json.dumps(metadata), flush=True)
    if publish:
        host = os.environ["OTA_SSH_HOST"]
        if not re.fullmatch(r"[A-Za-z0-9_.@-]+", host):
            raise ValueError("Invalid OTA SSH host")
        remote = "/tmp/" + output.name
        ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host]
        run(*ssh, "mkdir -m 700 " + shlex.quote(remote))
        try:
            run("scp", "-q", "-o", "BatchMode=yes", "-r", package_dir, host + ":" + remote + "/package")
            run("scp", "-q", "-o", "BatchMode=yes", REPO / "scripts/ios/publish.py", host + ":" + remote + "/publish.py")
            run(*ssh, shlex.join(["python3", remote + "/publish.py", remote + "/package", "/mnt/b2/remux-ios-ota", base_url]))
        finally:
            run(*ssh, "rm -rf -- " + shlex.quote(remote))
    # Retain the signed package and receipt; remove only this run's large build tree.
    shutil.rmtree(output)
    print(f"Retained release: {retained}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("build")
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    release(args.build, args.publish)
