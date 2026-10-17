#!/usr/bin/env python3
"""Render versioned OTA metadata and a phone-friendly installer."""
import argparse
import datetime
import hashlib
import html
import json
import plistlib
import re
from pathlib import Path
from urllib.parse import quote, urlsplit


def package(directory, base_url, revision):
    directory = Path(directory)
    parsed = urlsplit(base_url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("OTA base URL must be an HTTPS URL without credentials, query, or fragment")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Expected a complete source revision")
    with (directory / "Info.plist").open("rb") as f:
        info = plistlib.load(f)
    build = str(info["CFBundleVersion"])
    if not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Expected a positive build number")
    if info["CFBundleIdentifier"] != "com.davidjson.remux":
        raise ValueError("Unexpected application identifier")
    display_name = info.get("CFBundleDisplayName", "Remux Dev")
    ipa = directory / "Remux.ipa"
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    release_url = f"{base_url.rstrip('/')}/{build}"
    metadata = {
        "displayName": display_name,
        "bundleIdentifier": info["CFBundleIdentifier"],
        "marketingVersion": info["CFBundleShortVersionString"],
        "buildNumber": build,
        "sourceRevision": revision,
        "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "sha256": digest,
        "ipaBytes": ipa.stat().st_size,
        "ipaUrl": release_url + "/Remux.ipa",
    }
    manifest = {"items": [{"assets": [{"kind": "software-package", "url": metadata["ipaUrl"]}], "metadata": {
        "bundle-identifier": metadata["bundleIdentifier"], "bundle-version": build,
        "kind": "software", "title": display_name
    }}]}
    (directory / "manifest.plist").write_bytes(plistlib.dumps(manifest))
    (directory / "release-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    install_url = "itms-services://?action=download-manifest&url=" + quote(release_url + "/manifest.plist", safe="")
    page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#111718"><title>Install {html.escape(display_name)}</title>
<style>
*{{box-sizing:border-box}}body{{margin:0;background:#111718;color:#e9f0e9;font:17px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;padding:8vh 24px}}
main{{max-width:520px;margin:auto}}.mark{{color:#9dec9c;font:600 25px ui-monospace,monospace;letter-spacing:-2px}}
.eyebrow{{color:#a3afa5;font-size:13px;text-transform:uppercase;letter-spacing:2px;margin-top:48px}}
h1{{font-size:56px;line-height:1.1;letter-spacing:-2px;margin:10px 0 22px}}p{{color:#b4c0b6}}a{{color:#9dec9c}}
.install{{display:block;background:#9dec9c;color:#112015;text-decoration:none;border-radius:14px;text-align:center;padding:16px;font-weight:650;margin:34px 0 20px}}
.details{{border-top:1px solid #2b3630;margin-top:36px;padding-top:20px;font-size:14px;color:#a3afa5}}code{{font:13px ui-monospace,monospace}}
footer{{margin-top:40px;font-size:13px;color:#7d8c82}}.hint{{font-size:14px}}
</style></head><body><main><div class="mark">[ {html.escape(display_name.lower())} ]</div>
<div class="eyebrow">Your private build</div><h1>Your terminal.<br>In your pocket.</h1>
<p>Connect to your servers and pick up your tmux sessions from your iPhone.</p>
<a class="install" href="{html.escape(install_url, quote=True)}">Install {html.escape(display_name)} on iPhone</a>
<p class="hint">Open this page in Safari with Tailscale connected. Confirm Install, then open {html.escape(display_name)} from your Home Screen. Developer Mode must be enabled.</p>
<div class="details">Version {html.escape(metadata['marketingVersion'])} · Build {build}<br>
Source <a href="https://github.com/djson9/remux/commit/{revision}"><code>{revision[:12]}</code></a><br>
Built {metadata['builtAt'][:10]} · <a href="{html.escape(metadata['ipaUrl'], quote=True)}">Download IPA</a></div>
<footer>Based on <a href="https://github.com/h3nock/remux">Remux</a> · MIT license</footer>
</main></body></html>'''
    (directory / "index.html").write_text(page)
    (directory / "Info.plist").unlink()
    return metadata


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("base_url")
    parser.add_argument("revision")
    args = parser.parse_args()
    print(json.dumps(package(args.directory, args.base_url, args.revision)))
