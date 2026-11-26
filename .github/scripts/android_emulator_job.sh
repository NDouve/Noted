#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# The steps of ci.yml's `android-emulator` job that run on the booted emulator
# (run 2026-11-25-01, task 1). android-emulator-runner runs each line of its
# `script:` as a separate command, so the steps are here and the job's script is
# one line: `bash .github/scripts/android_emulator_job.sh`.
#
# Every line the job's log is read by starts with `NOTED_`:
#   NOTED_SDK=<n>                     the emulator's API level
#   NOTED_FIRST_LAUNCH_TEXT           the current release apk's first launch (diagnostic)
#   NOTED_LINK_PROBE ...              what `link` and `renameat2` do on this device
#   NOTED_PHASE_START|OK|FAILED|TIMEOUT <phase>
#   NOTED_FIRST_LAUNCH ok|error|timeout   from the Dart test (the real app's first launch)
#   NOTED_STEP_OK <step>              a step passed
#   NOTED_FAIL <why>                  the job fails
#
# Environment: API_LEVEL (the matrix leg), GH_TOKEN and GITHUB_RUN_ID (set by
# the job), OUT_DIR (where screenshots and logs go; uploaded as an artifact),
# DEBUG_APK and TEST_APK (the two apks the job built before the emulator started).

set -u

PKG=io.github.ndouve.noted
RUNNER="$PKG.test/androidx.test.runner.AndroidJUnitRunner"
OUT="${OUT_DIR:-android-emulator-out}"
RUN_ID="${GITHUB_RUN_ID:-local}"
mkdir -p "$OUT"
rc=0

fail() {
  echo "NOTED_FAIL $*"
  rc=1
}

flutter_log() {
  # What the app and the Dart tests printed (Flutter's print goes to tag `flutter`).
  adb logcat -d -s flutter:V 2>/dev/null | tr -d '\r'
}

# --- 1. Facts ------------------------------------------------------------------
SDK=$(adb shell getprop ro.build.version.sdk | tr -d '\r')
echo "NOTED_SDK=$SDK (matrix leg ${API_LEVEL:-?})"
echo "NOTED_DEVICE $(adb shell getprop ro.product.cpu.abi | tr -d '\r') $(adb shell getprop ro.build.version.release | tr -d '\r')"

# --- 2. The current release apk (diagnostic: what first launch does today) ------
release_apk_launch() {
  local rid
  rid=$(gh run list --workflow ci.yml --branch main --status success --limit 30 \
    --json databaseId,headSha --jq "[.[] | select(.headSha != \"${GITHUB_SHA:-}\")][0].databaseId" 2>&1)
  if ! [[ "$rid" =~ ^[0-9]+$ ]]; then
    echo "NOTED_RELEASE_APK no earlier successful main run found ($rid)"
    return 0
  fi
  if ! gh run download "$rid" -n Noted-android-apk -D "$OUT/release-apk" 2>&1; then
    echo "NOTED_RELEASE_APK run $rid has no Noted-android-apk (expired or not built)"
    return 0
  fi
  echo "NOTED_RELEASE_APK run $rid"
  adb uninstall "$PKG" > /dev/null 2>&1 || true
  adb install -r "$OUT/release-apk/app-release.apk" || { echo "NOTED_RELEASE_APK install failed"; return 0; }
  adb logcat -c
  adb shell am start -W -n "$PKG/.MainActivity"
  sleep 20
  adb shell uiautomator dump /sdcard/first-launch.xml > /dev/null 2>&1
  adb pull /sdcard/first-launch.xml "$OUT/first-launch-api$SDK.xml" > /dev/null 2>&1
  echo "NOTED_FIRST_LAUNCH_TEXT $(grep -o 'text="[^"]*"' "$OUT/first-launch-api$SDK.xml" 2>/dev/null | tr '\n' ' ')"
  flutter_log | sed 's/^/NOTED_FIRST_LAUNCH_LOG /' | tail -40
  adb exec-out screencap -p > "$OUT/first-launch-api$SDK.png"
  adb shell am force-stop "$PKG"
}
release_apk_launch || echo "NOTED_RELEASE_APK step failed (diagnostic only)"

# --- 3. Fresh install of the debug apk and the instrumentation apk ---------------
# The release apk is signed with another runner's debug key: uninstall first.
adb uninstall "$PKG" > /dev/null 2>&1 || true
adb uninstall "$PKG.test" > /dev/null 2>&1 || true
adb install -r -t "$DEBUG_APK" || { fail "install of $DEBUG_APK failed"; exit "$rc"; }
adb install -r -t "$TEST_APK" || { fail "install of $TEST_APK failed"; exit "$rc"; }
echo "NOTED_STEP_OK install"

# --- phases: one `am instrument` each, in its own process -----------------------
run_phase() {
  local p=$1 log="$OUT/phase-$p.log" code
  echo "NOTED_PHASE_START $p"
  adb logcat -c
  timeout 300 adb shell am instrument -w -e phase "$p" -e run "$RUN_ID" "$RUNNER" > "$log" 2>&1
  code=$?
  tr -d '\r' < "$log"
  flutter_log > "$OUT/logcat-$p.txt"
  grep 'NOTED_' "$OUT/logcat-$p.txt"
  if [ "$code" -eq 124 ]; then
    echo "NOTED_PHASE_TIMEOUT $p"
    adb shell am force-stop "$PKG"
    adb logcat -d | tail -300
    return 1
  fi
  # `am instrument` exits 0 even when the test failed: look for the summary.
  if ! grep -q 'OK (1 test)' "$log"; then
    echo "NOTED_PHASE_FAILED $p"
    adb logcat -d | tail -200
    return 1
  fi
  echo "NOTED_PHASE_OK $p"
}

# --- 4. Phase probe (never fails the job) ---------------------------------------
run_phase probe || echo "NOTED_PROBE did not finish (not fatal); the probe lines above say how far it got"
adb shell am force-stop "$PKG"

# --- 5. Phase write: the real app, first launch, a save --------------------------
if run_phase write; then
  echo "NOTED_STEP_OK write"
  adb exec-out screencap -p > "$OUT/after-write-api$SDK.png"
else
  fail "phase write failed"
fi

# --- 6. Stop the app ---------------------------------------------------------------
adb shell am force-stop "$PKG"

# --- 7. Phase check: after a stop, the saved page is there -----------------------
if [ "$rc" -eq 0 ]; then
  if run_phase check; then
    echo "NOTED_STEP_OK check"
    adb exec-out screencap -p > "$OUT/after-check-api$SDK.png"
  else
    fail "phase check failed"
  fi
else
  echo "NOTED_PHASE_SKIPPED check (write failed)"
fi
adb shell am force-stop "$PKG"

# --- 8. One engine: a second MainActivity must not start a second Flutter engine --
adb logcat -c
adb shell am start -W -n "$PKG/.MainActivity"
sleep 15
adb shell am start -W -n "$PKG/.MainActivity" --activity-multiple-task
sleep 10
records=$(adb shell dumpsys activity activities | tr -d '\r' | grep 'ActivityRecord{' | grep -c "$PKG/.MainActivity")
starts=$(flutter_log | grep -c NOTED_MAIN_START)
echo "NOTED_ONE_ENGINE activity_records=$records main_starts=$starts (both must be 1)"
adb shell dumpsys activity activities | tr -d '\r' | grep 'ActivityRecord{' | sed 's/^/NOTED_ONE_ENGINE_RECORD /'
adb exec-out screencap -p > "$OUT/one-engine-api$SDK.png"
if [ "$records" -eq 1 ] && [ "$starts" -eq 1 ]; then
  echo "NOTED_STEP_OK one-engine"
else
  fail "one engine: $records MainActivity records and $starts NOTED_MAIN_START lines (expected 1 and 1)"
fi
adb shell am force-stop "$PKG"

adb logcat -d > "$OUT/logcat-full-api$SDK.txt" 2>&1
exit "$rc"
