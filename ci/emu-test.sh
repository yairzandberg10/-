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

# --- normal Settings must stay usable when no lock is active
adb shell am start -n com.android.settings/.Settings; sleep 4
F=$(focus); log "settings (no lock): $F"
case "$F" in *BlockActivity*) log "FAIL settings blocked without lock";; *) log "PASS settings usable without lock";; esac
shot 03b-settings-open 0
adb shell am start -a android.settings.WIFI_SETTINGS; sleep 4
F=$(focus); case "$F" in *BlockActivity*) log "FAIL wifi settings blocked";; *) log "PASS wifi settings usable";; esac
adb shell am start -a android.settings.DATE_SETTINGS; sleep 4
F=$(focus); log "date settings: $F"
case "$F" in *BlockActivity*) log "PASS date settings blocked";; *) log "FAIL date settings open";; esac
adb shell am start -a android.settings.ACCESSIBILITY_SETTINGS; sleep 3
for k in 1 2 3; do adb shell input swipe 320 800 320 250 300; sleep 1.5; done
sleep 2
F=$(focus); log "accessibility settings: $F"
case "$F" in *BlockActivity*) log "PASS accessibility settings blocked";; *) log "FAIL accessibility settings open";; esac
adb shell am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:com.ogen.app; sleep 4
F=$(focus); log "ogen app info: $F"
case "$F" in *BlockActivity*) log "PASS ogen app info blocked";; *) log "FAIL ogen app info open";; esac
adb shell input keyevent KEYCODE_HOME; sleep 1

# --- sub pages
for pg in 1:04-limit 4:06-social 3:07-allow; do
  adb shell am start -n com.ogen.app/.MainActivity --ei page ${pg%%:*}; shot ${pg#*:}
done
tap "הוספת אפליקציה"; shot 08-picker
adb shell input keyevent KEYCODE_BACK; sleep 1

if git log -3 --format=%s | grep -q "\[quick\]"; then log "quick run: skipping the 16-minute usage test"; log "done"; exit 0; fi

# --- set 15 minutes of screen time (default 1:00, minus 3 x 15)
adb shell am start -n com.ogen.app/.MainActivity --ei page 1; sleep 2
tap "−"; tap "−"; tap "−"
shot 09-limit-15 0
tap "קבע זמן מסך"; shot 09b-limit-confirm 1
tap "אישור"; shot 10-home-with-limit

# --- use an ordinary app until the time runs out (counts only while in a real app)
adb shell svc power stayon true
adb shell monkey -p com.google.android.deskclock -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 420
adb shell am start -n com.ogen.app/.MainActivity --ei page 0; shot 11-home-half-used
adb shell monkey -p com.google.android.deskclock -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 540
F=$(focus); log "clock after 16 min of use: $F"
case "$F" in *BlockActivity*) log "PASS time ran out -> blocked";; *) log "FAIL not blocked after time ran out";; esac
shot 12-time-up 0

adb shell am start -n com.ogen.app/.MainActivity --ei page 0; shot 13-home-time-up

adb shell am start -n com.android.settings/.Settings; sleep 4
F=$(focus); case "$F" in *BlockActivity*) log "PASS settings blocked when time is up";; *) log "FAIL settings open when time is up";; esac

adb shell am start -a android.intent.action.DIAL; sleep 4
F=$(focus); log "dialer when time is up: $F"
case "$F" in *BlockActivity*) log "FAIL dialer blocked";; *) log "PASS dialer allowed";; esac
shot 14-dialer-time-up 0
log "done"
