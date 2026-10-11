#!/bin/bash
set -euo pipefail
CR_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CR_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/comicreader-cloud-tests.XXXXXX")"
trap 'rm -rf "$CR_TEST_DIR"' EXIT
xcrun swiftc -swift-version 5 \
  "$CR_REPO_ROOT/Classes/CRCloudSyncModel.swift" \
  "$CR_REPO_ROOT/Tests/CRCloudSyncModelHarness.swift" \
  -o "$CR_TEST_DIR/cloud-tests"
"$CR_TEST_DIR/cloud-tests"
xcrun swiftc -swift-version 5 -D CR_CLOUD_SYNC_TESTING \
  "$CR_REPO_ROOT/Classes/CRCloudSyncModel.swift" \
  "$CR_REPO_ROOT/Classes/CRCloudSyncManager.swift" \
  "$CR_REPO_ROOT/Tests/CRCloudSyncManagerHostHarness.swift" \
  -o "$CR_TEST_DIR/manager-tests"
"$CR_TEST_DIR/manager-tests"
