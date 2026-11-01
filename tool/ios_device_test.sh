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
xcrun simctl privacy "$UDID" grant photos-add "$BUNDLE"

flutter test integration_test/capture_test.dart -d "$UDID"

MEDIA="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Media/DCIM"
find "$MEDIA" -type f | tee "$OUT/files.txt"
find "$MEDIA" -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.jpg' -o -iname '*.jpeg' \) \
  -exec cp {} "$OUT/" \;
find "$OUT" -iname '*.mp4' -o -iname '*.mov' | grep -q .
