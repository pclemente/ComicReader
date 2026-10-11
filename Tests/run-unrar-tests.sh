#!/bin/sh

set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/comicreader-unrar-tests.XXXXXX")

cleanup() {
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

cat > "$temporary_root/TestPrefix.h" <<'EOF'
#import <Foundation/Foundation.h>
#define XLOG_ERROR(...) NSLog(__VA_ARGS__)
#define XLOG_DEBUG_CHECK(condition) NSCAssert((condition), @"UnRAR debug check failed")
EOF

sdk_path=$(xcrun --sdk macosx --show-sdk-path)
unrar_sources="
archive arcread cmddata consio crc dll encname errhnd extinfo extract
file filefn filcreat filestr find getbits global isnt list match options
pathfn rarvm rawread rdwrfn recvol resource rs savepos scantree smallfn
strfn strlist system timefn ulinks unicode unpack volume
"

for source_name in $unrar_sources; do
  xcrun --sdk macosx clang++ \
    -isysroot "$sdk_path" \
    -mmacosx-version-min=12.0 \
    -I"$repository_root/UnRAR-3.9.10" \
    -DNOCRYPT -DRARDLL -DUSE_FILE32API \
    -fexceptions -Wno-everything \
    -c "$repository_root/UnRAR-3.9.10/$source_name.cpp" \
    -o "$temporary_root/$source_name.o"
done

xcrun --sdk macosx clang \
  -x objective-c -fno-objc-arc \
  -isysroot "$sdk_path" \
  -mmacosx-version-min=12.0 \
  -I"$repository_root/Classes" \
  -I"$repository_root/UnRAR-3.9.10" \
  -include "$temporary_root/TestPrefix.h" \
  -c "$repository_root/Classes/UnRAR.m" \
  -o "$temporary_root/UnRAR.o"

xcrun --sdk macosx clang \
  -x objective-c -fno-objc-arc \
  -isysroot "$sdk_path" \
  -mmacosx-version-min=12.0 \
  -I"$repository_root/Classes" \
  -c "$script_directory/UnRARHostHarness.m" \
  -o "$temporary_root/UnRARHostHarness.o"

xcrun --sdk macosx clang++ \
  -isysroot "$sdk_path" \
  -mmacosx-version-min=12.0 \
  "$temporary_root"/*.o \
  -framework Foundation \
  -o "$temporary_root/unrar-host-tests"

symbol_report="$temporary_root/symbols.txt"
nm -a "$temporary_root/unrar-host-tests" > "$symbol_report"
strings -a "$temporary_root/unrar-host-tests" >> "$symbol_report"
if grep -Eiq 'CryptData|Rijndael|SHA1Transform|hash_(initial|process|final)|crypthead|RARSetPassword|SetCryptKeys|DecryptBlock' "$symbol_report"; then
  echo "FAIL: archive crypto symbols remain in the host harness" >&2
  exit 1
fi

TMPDIR="$temporary_root" "$temporary_root/unrar-host-tests"
echo "Bundled archive crypto symbol scan: PASS"
