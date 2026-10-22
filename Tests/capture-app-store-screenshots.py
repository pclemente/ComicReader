#!/usr/bin/env python3
"""Capture five genuine iPhone, iPad, or iPhone Duo screenshots for ComicReader.

Use a dedicated, already booted simulator and a separate derived-data directory.
For example, from the repository root:

    python3 Tests/capture-app-store-screenshots.py \\
      --device SIMULATOR_UDID --family iphone \\
      --fixtures /tmp/ComicReader-Screenshot-Library-54 \\
      --derived-data /tmp/ComicReader-1.4.1-Screenshots \\
      --result /tmp/ComicReader-1.4.1-iphone-NEW-RUN.xcresult --build

For an iPhone Duo 1.5 capture:

    python3 Tests/capture-app-store-screenshots.py \\
      --device SIMULATOR_UDID --family duo \\
      --fixtures /tmp/ComicReader-Screenshot-Library-54 \\
      --derived-data /tmp/ComicReader-1.5-Duo-Screenshots \\
      --result /tmp/ComicReader-1.5-duo-NEW-RUN.xcresult \\
      --release-version 1.5 --build

The default destination is release/app-store/1.4.1/captures/<family>. Existing
captures and result bundles are never overwritten. To prepare a retake, provide
--output release/app-store/1.4.1/capture-runs/NEW-RUN/<family>, then visually
review the new set before promoting it. All writes under the historical 1.4
release directory are rejected. For a later release, pass --release-version;
the compiled app version must match it.

Use the approved public-domain library from prepare_screenshot_library.py in
the release directory. Fixtures are staged temporarily in the UI-test bundle,
never the application target. The helper enables an explicit test-only capture
marker and removes its staged resources even when the capture fails. Ordinary
UI test runs skip the screenshot journey without that marker and its fixtures.
If staging resources remain after an interrupted process, use a fresh dedicated
derived-data directory. --reuse-library avoids duplicate imports when the
dedicated simulator already contains the approved library in app Documents.

Captures exercise a local StoreKitTest purchase through the actual app UI;
they do not verify production purchases or live iCloud synchronization. Inspect
all five PNGs and capture-record.json before composing or uploading anything.
This script never changes application source, grants an entitlement directly,
resets a simulator, or restarts services.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RELEASE = "1.4.1"
HISTORICAL_RELEASE = ROOT / "release/app-store/1.4"
NAMES = ("01-library", "02-reader", "03-search", "04-lists", "05-icloud")
TEST = "ComicReaderUITests/ComicReaderUITests/testCaptureAppStoreScreenshots"


def run(command: list[str], *, timeout: int = 1800) -> None:
    print("Running:", " ".join(command), flush=True)
    subprocess.run(command, check=True, cwd=ROOT, timeout=timeout)


def protect_historical_release(path: Path) -> None:
    if path.resolve().is_relative_to(HISTORICAL_RELEASE.resolve()):
        raise SystemExit("The 1.4 release evidence is read-only; choose a 1.4.1 or later destination.")


@contextmanager
def staged_fixtures(test_bundle: Path, fixtures: list[Path], reuse_library: bool, family: str):
    fixture_target = test_bundle / "ScreenshotLibrary"
    if fixture_target.exists():
        raise SystemExit("Screenshot resources already exist in this test bundle; use a fresh dedicated derived-data directory.")
    fixture_target.mkdir()
    try:
        for fixture in fixtures:
            shutil.copy2(fixture, fixture_target / fixture.name)
        if reuse_library:
            (fixture_target / "reuse-library").write_text("Reuse the existing screenshot fixture library.\n")
        if family == "duo":
            (fixture_target / "capture-family-duo").write_text("Capture the iPhone Duo layout.\n")
        (fixture_target / "capture-request").write_text("Run the explicit App Store screenshot journey.\n")
        yield
    finally:
        shutil.rmtree(fixture_target)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", required=True, help="UDID of a dedicated, booted simulator")
    parser.add_argument("--family", choices=("iphone", "ipad", "duo"), required=True)
    parser.add_argument("--fixtures", type=Path, required=True, help="Approved CBZ demo-library directory")
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True, help="New .xcresult path")
    parser.add_argument("--release-version", default=DEFAULT_RELEASE, help="Expected app and release version (default: 1.4.1)")
    parser.add_argument("--output", type=Path, help="New capture directory (default: release/app-store/<release-version>/captures/<family>)")
    parser.add_argument("--build", action="store_true", help="Build the current app and UI tests first")
    parser.add_argument("--reuse-library", action="store_true", help="Use an already populated screenshot simulator without reimporting its comics")
    args = parser.parse_args()

    if not args.release_version or any(part in args.release_version for part in ("/", "\\", "..")):
        raise SystemExit("Use a release version such as 1.4.1, not a path.")
    args.output = (args.output or ROOT / "release/app-store" / args.release_version / "captures" / args.family).resolve()
    exported = args.result.resolve().with_suffix(".attachments")
    for destination in (args.output, args.result, exported, args.derived_data):
        protect_historical_release(destination)
    if args.result.exists():
        raise SystemExit("Choose a new result path; existing test results are preserved.")
    if exported.exists():
        raise SystemExit("Choose a new result path; existing attachment exports are preserved.")
    if any((args.output / name).exists() for name in (*[name + ".png" for name in NAMES], "capture-record.json")):
        raise SystemExit("Existing captures are preserved; choose a new --output directory for this run.")
    fixtures = sorted(args.fixtures.resolve().glob("*.cbz"))
    if len(fixtures) < 9:
        raise SystemExit("The approved nine-book screenshot library is required.")
    derived = args.derived_data.resolve()
    if args.build:
        run(["xcodebuild", "-project", "ComicFlow.xcodeproj", "-scheme", "ComicFlow",
             "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(derived),
             "-parallel-testing-enabled", "NO", "-jobs", "1", "CODE_SIGNING_ALLOWED=NO",
             "build-for-testing"])
    products = derived / "Build/Products"
    runs = list(products.glob("ComicFlow_iphonesimulator*.xctestrun"))
    if len(runs) != 1:
        raise SystemExit("Build the test target first, or pass --build with a clean derived-data directory.")
    test_bundle = products / "Debug-iphonesimulator/ComicReaderUITests-Runner.app/PlugIns/ComicReaderUITests.xctest"
    if not test_bundle.is_dir():
        raise SystemExit("The compiled UI-test bundle is missing.")
    app_info = plistlib.loads((products / "Debug-iphonesimulator/ComicFlow.app/Info.plist").read_bytes())
    if app_info["CFBundleShortVersionString"] != args.release_version:
        raise SystemExit("The compiled app version does not match --release-version; rebuild the intended release.")
    with staged_fixtures(test_bundle, fixtures, args.reuse_library, args.family):
        run(["xcrun", "simctl", "status_bar", args.device, "override", "--time", "9:41",
             "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
             "--batteryState", "charged", "--batteryLevel", "100"], timeout=45)
        run(["xcodebuild", "test-without-building", "-xctestrun", str(runs[0]),
             "-destination", f"platform=iOS Simulator,id={args.device}",
             "-resultBundlePath", str(args.result.resolve()), "-parallel-testing-enabled", "NO",
             "-maximum-concurrent-test-simulator-destinations", "1", "-testLanguage", "en",
             "-testRegion", "GB", "-collect-test-diagnostics", "never", f"-only-testing:{TEST}"])

    run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(args.result.resolve()),
         "--output-path", str(exported)], timeout=60)
    manifest = json.loads((exported / "manifest.json").read_text())
    attachments = [attachment for test in manifest
                   if test.get("testIdentifier", "").endswith("/testCaptureAppStoreScreenshots")
                   for attachment in test.get("attachments", [])]
    selected: dict[str, tuple[Path, dict]] = {}
    for name in NAMES:
        matches = [a for a in attachments if a.get("suggestedHumanReadableName", "").startswith(name + "_")]
        if len(matches) != 1:
            raise SystemExit(f"Expected one successful {name} attachment, found {len(matches)}; raw output is unchanged.")
        selected[name] = (exported / matches[0]["exportedFileName"], matches[0])

    args.output.mkdir(parents=True, exist_ok=True)
    records = []
    for name, (source, metadata) in selected.items():
        payload = source.read_bytes()
        if payload[:8] != b"\x89PNG\r\n\x1a\n":
            raise SystemExit(f"Unexpected non-PNG screenshot: {source}")
        width, height = struct.unpack(">II", payload[16:24])
        destination = args.output / (name + ".png")
        with destination.open("xb") as destination_file:
            destination_file.write(payload)
        records.append({"file": destination.name, "width": width, "height": height,
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "device": metadata.get("deviceName"), "timestamp": metadata.get("timestamp")})
    record = {"family": args.family, "device_id": args.device,
              "version": app_info["CFBundleShortVersionString"], "build": app_info["CFBundleVersion"],
              "result_bundle": str(args.result.resolve()), "test": TEST,
              "capture_method": "Unmodified XCUIScreen PNG attachments from the real application UI",
              "entitlement": "Local StoreKitTest non-consumable purchase through the app purchase UI",
              "fixtures": ("Existing approved public-domain demo library in the app's Documents folder"
                           if args.reuse_library else
                           "Approved public-domain demo comics imported through the normal document URL route"),
              "reuse_fixture_library": args.reuse_library,
              "production_purchase_or_cloud_verification": False,
              "visual_review_required": True, "screenshots": records}
    with (args.output / "capture-record.json").open("x") as record_file:
        record_file.write(json.dumps(record, indent=2) + "\n")
    print("Five raw captures exported. Inspect them visually before composing or uploading.")


if __name__ == "__main__":
    main()
