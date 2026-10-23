# Mac browser UI validation — 23 October 2026

The native macOS UI runner and the isolated Catalyst app both compile with
Xcode 27.1. The browser end-to-end test has **not passed**. Two runs stopped at
the first assertion for the test publisher's signed-in page. Neither run reached
purchase, restore, destination selection, import, duplicate detection or opening
the downloaded comic. These results establish incomplete coverage, not a
confirmed production-app defect.

The first run could not bind the loopback server because Xcode's generated UI
runner sandbox omitted `com.apple.security.network.server`. Adding that
permission fixed the bind failure. The fixture now also requires the listener
to report `.ready`, so a failed listener cannot supply a port to the app.
The fixture separately passed a native URLSession check for login, cookie
retention, an authenticated redirect and a valid PDF transfer.

The retry's screenshot and accessibility hierarchy identify the immediate
navigation failure: native XCTest typing omitted both colon characters from
the fixture URL. The address became
`https://http//localhost61144/.../login`, and the app displayed the expected
hostname-not-found error. This run never contacted the intended publisher.
The test helper now pastes only its known fixture URL, checks the complete field
value before pressing Return, and restores the previous clipboard contents
unless something else changed the clipboard in the meantime. Clipboard data is
never logged or attached. This correction was type-checked but has not been run
through the UI. Native text entry and successful StoreKitTest configuration
still need to be verified in the complete journey.

Both UI runs reported StoreKitTest configuration errors:

```text
Error saving configuration file: SKServiceErrorDomain Code=2
  underlying SKInternalErrorDomain Code=4
```

Clearing test transactions and setting test options reported the same error.
Creating an `SKTestSession` object therefore does not establish that StoreKit
Test was configured successfully on this runner. The native purchase and restore
journey remains unverified. Do not reinterpret these runs as passes or change
production purchase handling to accommodate a test-service failure.

Local evidence:

- `/tmp/ComicReader-1.6-mac-browser-ui.xcresult` and matching `.log`: first run.
- `/tmp/ComicReader-1.6-mac-browser-ui2.xcresult` and matching `.log`: retry.
- `/tmp/ComicReader-1.6-mac-browser-ui2-attachments`: exported retry attachments.
- `/tmp/ComicReader-picker-focused/Logs/Test/Test-ComicFlow-2026.10.23_12-58-25-+0200.xcresult`:
  five selected Catalyst regressions passed at 12:59:30 with zero failures. The
  selection covered direct-picker intent and temporary-copy cleanup, preserving
  an unexpected source URL, invalid-copy cleanup, the standard File/Open
  command, and review requests while the news banner is visible.
- `/tmp/ComicReader-mac-ui-catalyst-probe/Build/Products/Debug-maccatalyst/ComicFlow.app`:
  isolated Catalyst host produced by the subsequent native `build-for-testing`.
- `/tmp/ComicReader-mac-signed-investigation/ComicFlow.app`: retained copy of
  the unsuccessful developer-signed host for signature diagnosis only.

The relevant retry files are `19797852-9D9D-447F-BC5E-FD22B52E273E.png`
(screenshot) and `28DDDF4E-F874-433A-97BA-208A8BDD5D0A.txt` (accessibility
hierarchy). The screenshot includes desktop context and is a local diagnostic,
not an App Store or repository image.

The retry finished at 11:53:49 Europe/Madrid. Test teardown terminated its app.
No further native UI retries were run during this validation pass.

## Isolated diagnostic reproduction

The test must use `com.pabloclementeperez.ComicFlow.MacUITestHost`, with a
sandboxed application and no iCloud entitlement. This gives it a separate
library, preferences and website data. Do not run an unsigned application:
without its sandbox, its Documents directory could be the user's own directory.
Release keeps the production bundle identifier and `ComicFlow-Mac.entitlements`.

The isolated app launched successfully in 3.9 seconds after ad-hoc signing with
exactly the five entries in `ComicFlow-MacUITestHost.entitlements`. The attempted
developer-signed host is not a valid substitute for a provisioned archive. Its
generated `.xcent` had no application or team identifier entitlements and the
app had no embedded provisioning profile. A first manual re-sign kept only the
five source entitlements and also removed the hardened-runtime flag; that
combination left the process blocked in `_libsecinit_appsandbox` before `main`.
A second re-sign restored hardened runtime but added application and team
identifiers that Xcode had not generated; launchd rejected it with
`RBSRequestErrorDomain Code=5`, underlying POSIX error 163. No AMFI detail was
available in the readable unified log. Production archives use Xcode automatic
signing and the real app's provisioning profile.

From the repository root, build the Catalyst app and native runner together:

```sh
xcodebuild -project ComicFlow.xcodeproj -scheme ComicReader-Mac-UI \
  -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -derivedDataPath /tmp/ComicReader-mac-ui-catalyst-probe -jobs 2 \
  CR_APP_BUNDLE_IDENTIFIER=com.pabloclementeperez.ComicFlow.MacUITestHost \
  CR_MAC_ENTITLEMENTS=ComicFlow-MacUITestHost.entitlements \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=CEQU933V6W \
  CODE_SIGN_IDENTITY=CC33BCB38A8D303DCF0809C78D1BD1C20D9341D3 \
  PROVISIONING_PROFILE_SPECIFIER= build-for-testing
```

This toolchain generates the wrong native path for the Catalyst app in the
`.xctestrun` file. It also omits incoming-network permission from the native
runner. Xcode also injects temporary test exceptions into the host signature.
The following diagnostic preparation restores the known-working ad-hoc host
with the five no-iCloud entitlements, corrects the generated path, and signs the
native runner with the development identity after adding only its fixture
permission. It must be repeated after rebuilding the runner. The ad-hoc host
has no TeamIdentifier, so the StoreKit service preflight can fail even though
manual browser and document-picker validation works.

```sh
python3 - <<'PY'
import plistlib
import subprocess
from pathlib import Path

root = Path('/tmp/ComicReader-mac-ui-catalyst-probe/Build/Products')
app = root / 'Debug-maccatalyst/ComicFlow.app'
runner = root / 'Debug/ComicReaderMacUITests-Runner.app'
identifier = 'com.pabloclementeperez.ComicFlow.MacUITestHost'
runner_signing_identity = 'CC33BCB38A8D303DCF0809C78D1BD1C20D9341D3'

def signed_entitlements(path):
    result = subprocess.run(
        ['codesign', '-d', '--entitlements', '-', '--xml', str(path)],
        capture_output=True, check=True)
    return plistlib.loads(result.stdout)

info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == identifier
app_entitlements = plistlib.loads(
    Path('ComicFlow-MacUITestHost.entitlements').read_bytes())
app_entitlement_file = Path('/tmp/ComicReader-MacUITestHost-adhoc.entitlements')
app_entitlement_file.write_bytes(plistlib.dumps(app_entitlements))
subprocess.run([
    'codesign', '--force', '--sign', '-', '--options', '0',
    '--entitlements', str(app_entitlement_file), '--timestamp=none', str(app)
], check=True)
app_entitlements = signed_entitlements(app)
assert app_entitlements['com.apple.security.app-sandbox'] is True
assert app_entitlements['com.apple.security.get-task-allow'] is True
assert not any('icloud' in key.lower() or 'ubiquity' in key.lower() or
               'temporary-exception' in key.lower()
               for key in app_entitlements)

runner_entitlements = signed_entitlements(runner)
runner_entitlements['com.apple.security.network.server'] = True
entitlement_file = Path('/tmp/ComicReader-MacUIRunner-network.entitlements')
entitlement_file.write_bytes(plistlib.dumps(runner_entitlements))
for product in [runner / 'Contents/PlugIns/ComicReaderMacUITests.xctest', runner]:
    subprocess.run(['codesign', '--force', '--sign', runner_signing_identity, '--entitlements',
                    str(entitlement_file), '--timestamp=none', str(product)],
                   check=True)

for product in [app, runner / 'Contents/PlugIns/ComicReaderMacUITests.xctest', runner]:
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(product)],
                   check=True)

test_file = root / 'ComicReader-Mac-UI_macosx27.0-arm64.xctestrun'
data = plistlib.loads(test_file.read_bytes())
target = data['ComicReaderMacUITests']
assert target['EnvironmentVariables']['CR_UI_MAC_FIXTURE_IMPORT'] == '1'
assert target['EnvironmentVariables']['CR_UI_MAC_HOST_BUNDLE_IDENTIFIER'] == identifier
target['UITargetAppPath'] = '__TESTROOT__/Debug-maccatalyst/ComicFlow.app'
test_file.write_bytes(plistlib.dumps(data))
PY
```

Run the native runner against that verified app. Use a fresh result-bundle path
and reserve the visible Mac desktop while the test operates its controls:

```sh
xcodebuild test-without-building \
  -xctestrun /tmp/ComicReader-mac-ui-catalyst-probe/Build/Products/ComicReader-Mac-UI_macosx27.0-arm64.xctestrun \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:ComicReaderMacUITests/CRMacWebBrowserUITests/testPurchaseRestoreAndAuthenticatedWebsiteImport \
  -resultBundlePath /tmp/ComicReader-mac-browser-diagnostic.xcresult
```

This reproduces the current diagnostic setup; it does not resolve the recorded
StoreKitTest service error or imply that the complete journey will pass.
