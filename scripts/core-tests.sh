#!/usr/bin/env bash
# Runs the Foundation-only unit tests (YouTube parsing, stream picking, lyrics parsing) on a Mac with just
# the Command Line Tools. CI runs the same tests with real XCTest (KnightMusicTests target).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/core-tests
mkdir -p "$OUT"
# Sources that only import Foundation. Anything touching GRDB/UIKit stays out of this list.
SOURCES=(
  KnightMusic/Core/YouTube/YouTubeID.swift
  KnightMusic/Core/YouTube/InnertubeJSON.swift
  KnightMusic/Core/YouTube/YouTubeModels.swift
  KnightMusic/Core/YouTube/YouTubeParser.swift
  KnightMusic/Core/YouTube/YouTubeStreamPicker.swift
  KnightMusic/Core/YouTube/YouTubeStream.swift
  KnightMusic/Core/Lyrics/LyricsDocument.swift
  KnightMusic/Core/Lyrics/TtmlParser.swift
  KnightMusic/Core/Lyrics/LrcParser.swift
  KnightMusic/Core/Lyrics/LyricsMatcher.swift
)
# *AppTests.swift need app types (GRDB, Nuke) and only run in CI.
TESTS=()
for f in KnightMusicTests/*.swift; do [[ "$f" == *AppTests.swift ]] || TESTS+=("$f"); done
swiftc -parse-as-library -emit-library -emit-module -module-name XCTest \
  -o "$OUT/libXCTest.dylib" -emit-module-path "$OUT/XCTest.swiftmodule" scripts/core-tests/XCTestShim.swift
{
  echo "import Foundation"
  echo "import XCTest"
  echo "@main struct CoreTestsMain { static func main() {"
  echo "  var ran = 0; var failed = 0"
  for f in "${TESTS[@]}"; do
    cls=$(grep -oE 'class [A-Za-z0-9_]+: XCTestCase' "$f" | awk '{print $2}' | tr -d ':' || true)
    [ -z "$cls" ] && continue
    for t in $(grep -oE 'func test[A-Za-z0-9_]+\(\)' "$f" | sed -E 's/func (test[A-Za-z0-9_]+)\(\)/\1/'); do
      echo "  do { let before = XCTShim.failures.count; ran += 1; do { try $cls().$t() } catch { XCTShim.failures.append(\"$cls.$t threw \\(error)\") }; if XCTShim.failures.count > before { failed += 1; print(\"✗ $cls.$t\") } else { print(\"✓ $cls.$t\") } }"
    done
  done
  echo "  for f in XCTShim.failures { print(\"  \" + f) }"
  echo "  print(\"\\(ran) tests, \\(failed) failed\"); exit(failed == 0 ? 0 : 1)"
  echo "} }"
} > "$OUT/runner.swift"
swiftc -parse-as-library -I "$OUT" -L "$OUT" -lXCTest -Xlinker -rpath -Xlinker "$PWD/$OUT" \
  "${SOURCES[@]}" "${TESTS[@]}" "$OUT/runner.swift" -o "$OUT/run" 2>&1 | grep -v "warning:" || true
[ -x "$OUT/run" ] || exit 1
KM_FIXTURES="$PWD/KnightMusicTests/Fixtures" "$OUT/run"
