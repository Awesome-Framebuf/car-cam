#!/usr/bin/env bash
# Runs the capture test on a simulator and collects the saved files.
set -euo pipefail

OUT=device-output
mkdir -p "$OUT"
BUNDLE="$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER = \(.*\);/\1/p' ios/Runner.xcodeproj/project.pbxproj | grep -v Tests | head -n 1)"

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime, entries in sorted(devices.items(), reverse=True):
    if "iOS" in runtime:
        for d in entries:
            if d["name"].startswith("iPhone"):
                print(d["udid"])
                sys.exit()
')"
test -n "$UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID"
echo "Granting photo access to $BUNDLE"
xcrun simctl privacy "$UDID" grant photos-add "$BUNDLE"
xcrun simctl privacy "$UDID" grant photos "$BUNDLE"

# Shows what's on screen if the test gets stuck, such as on a permission dialog.
(
  for minute in 3 6 9; do
    sleep 180
    xcrun simctl io "$UDID" screenshot "$OUT/stuck-$minute-min.png" || true
  done
) &
SHOT_PID=$!
trap 'kill "$SHOT_PID" 2>/dev/null || true' EXIT

status=0
flutter test integration_test/capture_test.dart -d "$UDID" -v > "$OUT/flutter-test.log" 2>&1 &
TEST_PID=$!
( sleep 720; kill "$TEST_PID" 2>/dev/null || true ) &
WATCHDOG_PID=$!
wait "$TEST_PID" || status=$?
kill "$WATCHDOG_PID" 2>/dev/null || true
tail -n 60 "$OUT/flutter-test.log"
xcrun simctl spawn "$UDID" log show --last 15m --style compact \
  --predicate 'subsystem == "com.apple.TCC" OR process == "Runner"' \
  > "$OUT/simulator.log" 2>&1 || true
test "$status" -eq 0

# Screenshots of the running app against a simulated car.
kill "$SHOT_PID" 2>/dev/null || true
mkdir -p "$OUT/shots"
(
  while true; do
    xcrun simctl io "$UDID" screenshot "$OUT/shots/$(date +%s).png" >/dev/null 2>&1 || true
    sleep 4
  done
) &
SHOT_PID=$!
flutter test integration_test/screens_test.dart -d "$UDID"
kill "$SHOT_PID" 2>/dev/null || true

MEDIA="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Media/DCIM"
find "$MEDIA" -type f | tee "$OUT/files.txt"
find "$MEDIA" -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.jpg' -o -iname '*.jpeg' \) \
  -exec cp {} "$OUT/" \;
find "$OUT" -iname '*.mp4' -o -iname '*.mov' | grep -q .
