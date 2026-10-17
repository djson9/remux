# Personal Remux fork

The fork is [djson9/remux](https://github.com/djson9/remux), based on
[h3nock/remux](https://github.com/h3nock/remux). The MIT license and upstream
history are preserved. `origin` points to the fork and `upstream` to the original.

The app is named **Remux Dev** and uses `com.davidjson.remux`, so it can coexist
with upstream Remux. The OTA installer uses the built app's display name.
`project.yml` remains the source of truth for the checked-in Xcode project.
Use XcodeGen 2.46.0 and Xcode 26.3 or a compatible newer toolchain.

## Build and release

CI runs on the existing Middesk infrastructure using repository-scoped
`middesk-linux` and `middesk-macos` runners. Mac builds use four compiler jobs.
Pull requests from other repositories do not run on these personal runners.
The existing upstream unit tests and UI-test compilation remain part of CI.

After successful main push CI, `iOS private OTA` builds the exact tested commit
and publishes it. A manual workflow dispatch on main can also release a build.
Releases are serialized. Build numbers combine the workflow run number and
attempt (`run number × 100 + attempt`), so a failed release can be retried.

The release calls the pinned shared Apple signing lane in a GUI launchd session.
The host must already have the approved Apple Development identity, compatible
profile, and protected signing policy. The lane verifies the app, nested code,
bundle identifier, entitlements, profile expiration, and device membership before
the release script packages or publishes anything. No provisioning or certificate
creation/revocation is performed.

The shared tools are installed as an immutable Git checkout at
`~/.local/share/apple-signing-tools/<SHA>`, matching
`.apple-signing-tools-version`. The host supplies Ruby 3.2.2 at its existing
rbenv path. The public repository contains no signing keys or credentials.

Repository variables configure the host:

| Variable | Meaning |
| --- | --- |
| `IOS_DEVELOPER_DIR` | Installed Xcode Developer directory |
| `IOS_DEVICE_UDID` | Registered phone required in the existing profile |
| `IOS_PROFILE_UUID` | Existing wildcard development profile UUID |
| `OTA_BASE_URL` | Private HTTPS installer origin |
| `OTA_SSH_HOST` | Existing Mac-to-VM deployment SSH account |

The installer is [Remux OTA](https://jays-vm.tailade3f5.ts.net:8473/latest/).
Open it in Safari while connected to Tailscale. The signed IPA and manifest live
under immutable build-number directories in `/mnt/b2/remux-ios-ota` on the VM.
The publisher checks the served IPA's SHA-256 before exposing the latest page.
The latest manifest also points to the immutable IPA, keeping upgrades coherent.
Private signing receipts and packages are retained under `~/.local/share/remux/releases/` on
the runner, and each published release includes its receipt and source metadata.

## Action Button recording

Open a session in Remux Dev once. On your iPhone, go to **Settings → Action
Button → Shortcut**, choose **Remux Dev**, then **Record in Composer**.
The shortcut opens the current session's composer and starts the existing
on-device dictation. A cold launch resumes the most recently used saved session.
Microphone and speech permissions are requested normally on first use.
If no session has been configured, the app asks you to open one first.

The same entry point is available at `remuxdev://record`. Repeated delivery
leaves an active recording running, and pending requests are cancelled when the
app enters the background. The normal on-screen stop and cancel controls remain
available. CI checks both current-session and cold-launch flows with the debug
dictation backend; the physical button assignment is made in iPhone Settings.

## Local validation

```sh
python3 -m unittest discover -s scripts/ios -p 'test_*.py'
bash -n scripts/ios/build-signed.sh
scripts/test_install_authorized_key.sh
scripts/fetch_ghosttykit.sh
xcodegen generate
xcodebuild build -project Remux.xcodeproj -scheme Remux \
  -configuration Release -destination 'generic/platform=iOS' \
  -jobs 4 CODE_SIGNING_ALLOWED=NO
```

The fork includes a small Swift 6 compatibility fix: prewarm tracing calls hop
directly to their MainActor method, avoiding an unnecessary closure capture of
the detached task's weak reference. Prewarm scheduling behavior is preserved.

Composer teardown uses a plain resource owner to cancel tasks and clean staged
attachments. This avoids the isolated-deinitializer runtime crash reproduced by
the synchronous composer tests on iOS 26.2. The matching Swift runtime issue is
[swiftlang/swift#88036](https://github.com/swiftlang/swift/issues/88036).
The existing synchronous tests remain enabled, alongside a staged-file cleanup
regression test. Upgrading Xcode alone would not fix older supported iOS runtimes.
