#!/usr/bin/env bash
# Runs the capture test on the connected emulator and checks the saved files.
set -euo pipefail

APP=io.github.awesomeframebuf.car_cam
OUT=device-output
mkdir -p "$OUT"

# Android 9 asks for storage access with a dialog no test can tap, so keep
# granting it until the app is installed.
(
  for _ in $(seq 1 600); do
    adb shell pm grant "$APP" android.permission.WRITE_EXTERNAL_STORAGE 2>/dev/null || true
    sleep 1
  done
) &
GRANT_PID=$!
trap 'kill "$GRANT_PID" 2>/dev/null || true' EXIT

flutter test integration_test/capture_test.dart -d emulator-5554

adb shell content query --uri content://media/external/video/media \
  --projection _display_name:duration:width:height:_size | tee "$OUT/videos.txt"
adb shell content query --uri content://media/external/images/media \
  --projection _display_name:width:height:_size | tee "$OUT/photos.txt"

adb pull "/sdcard/Movies/Car Cam" "$OUT/movies"
adb pull "/sdcard/Pictures/Car Cam" "$OUT/pictures"

video="$(find "$OUT/movies" -name '*.mp4' | head -n 1)"
photo="$(find "$OUT/pictures" -name '*.jpg' | head -n 1)"
test -n "$video" && test -n "$photo"

ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=codec_name,width,height,nb_read_frames:format=duration \
  -of default=noprint_wrappers=1 "$video" | tee "$OUT/ffprobe.txt"
grep -q 'codec_name=h264' "$OUT/ffprobe.txt"
frames="$(sed -n 's/^nb_read_frames=//p' "$OUT/ffprobe.txt")"
test "$frames" -gt 30
ffmpeg -v error -y -ss 1 -i "$video" -frames:v 1 "$OUT/video-frame.png"
file "$photo" | grep -q JPEG

# A real Android Wi-Fi settings screen for the connection guide.
adb shell am start -a android.settings.WIFI_SETTINGS
sleep 8
adb exec-out screencap -p > "$OUT/android-wifi-settings.png"
