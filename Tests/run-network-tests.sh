#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/comicreader-network-tests.XXXXXX")

cleanup() {
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

derived_data="$temporary_root/DerivedData"
frameworks="$derived_data/Build/Products/Debug"
harness="$temporary_root/network-path-harness"

xcodebuild -quiet \
  -project "$repository_root/GCDWebServer/GCDWebServer.xcodeproj" \
  -scheme "GCDWebServers (Mac)" \
  -configuration Debug \
  -derivedDataPath "$derived_data" \
  MACOSX_DEPLOYMENT_TARGET=12.0 \
  CODE_SIGNING_ALLOWED=NO \
  build

xcrun clang \
  -fobjc-arc \
  -fmodules \
  -mmacosx-version-min=12.0 \
  -F"$frameworks" \
  -framework Foundation \
  -framework GCDWebServers \
  "$script_directory/NetworkPathHarness.m" \
  -o "$harness"

TMPDIR="$temporary_root" DYLD_FRAMEWORK_PATH="$frameworks" "$harness"
