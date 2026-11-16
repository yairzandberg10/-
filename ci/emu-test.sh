#!/usr/bin/env bash
# Runs inside the emulator job. Produces release/shots/*.png and release/shots/report.txt
set -u
OUT=release/shots; mkdir -p $OUT; R=$OUT/report.txt; : > $R
log(){ echo "$*" | tee -a $R; }
shot(){ sleep "${2:-2}"; adb exec-out screencap -p > $OUT/$1.png; log "shot $1"; }
focus(){ adb shell dumpsys window | grep -E "mCurrentFocus" | head -1 | tr -d '\r'; }
tap(){ python3 ci/tap.py "$1" | tee -a $R; sleep 1.5; }

adb shell wm size 640x960; adb shell wm density 320
adb shell settings put global window_animation_scale 0; adb shell settings put global transition_animation_scale 0
adb install -r release/Ogen.apk | tee -a $R
adb install -r stub/build/outputs/apk/debug/stub-debug.apk | tee -a $R

adb shell am start -n com.ogen.app/.MainActivity; shot 01-home-not-enabled 3

adb shell settings put secure enabled_accessibility_services com.ogen.app/com.ogen.app.GuardService
adb shell settings put secure accessibility_enabled 1
sleep 4
adb shell am start -n com.ogen.app/.MainActivity --ei page 0; shot 02-home

# --- Instagram must be blocked even with no limit set (social block is on by default)
adb shell am start -n com.instagram.android/com.ogenstub.StubActivity; sleep 4
F=$(focus); log "after opening instagram stub: $F"
case "$F" in *com.ogen.app/com.ogen.app.BlockActivity*) log "PASS instagram blocked";; *) log "FAIL instagram NOT blocked";; esac
shot 03-instagram-blocked 0
adb shell input keyevent KEYCODE_HOME; sleep 1

# --- sub pages
for pg in 1:04-limit 2:05-lock 4:06-social 3:07-allow; do
  adb shell am start -n com.ogen.app/.MainActivity --ei page ${pg%%:*}; shot ${pg#*:}
done
tap "הוספת אפליקציה"; shot 08-picker
adb shell input keyevent KEYCODE_BACK; sleep 1

# --- set a daily limit
adb shell am start -n com.ogen.app/.MainActivity --ei page 1; sleep 2
tap "קבע מגבלה"; shot 09-limit-confirm 1
tap "אישור"; shot 10-home-with-limit

# --- 5 minute lock
adb shell am start -n com.ogen.app/.MainActivity --ei page 2; sleep 2
tap "5 דקות"; shot 11-lock-confirm 1
tap "נעל"; shot 12-home-locked

adb shell am start -n com.android.settings/.Settings; sleep 4
F=$(focus); log "settings during lock: $F"
case "$F" in *BlockActivity*) log "PASS settings blocked in lock";; *) log "FAIL settings open in lock";; esac
shot 13-settings-in-lock 0

adb shell am start -a android.intent.action.DIAL; sleep 4
F=$(focus); log "dialer during lock: $F"
case "$F" in *BlockActivity*) log "FAIL dialer blocked";; *) log "PASS dialer allowed";; esac
shot 14-dialer-in-lock 0

adb shell am start -n com.instagram.android/com.ogenstub.StubActivity; sleep 4
shot 15-block-locked 0
log "done"
