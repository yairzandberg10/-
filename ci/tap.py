"""Tap the first on-screen node whose text/content-desc contains the given string (uses uiautomator)."""
import re, subprocess, sys, time

def dump():
    for _ in range(4):
        subprocess.run(["adb", "shell", "uiautomator", "dump", "/sdcard/ui.xml"], capture_output=True)
        out = subprocess.run(["adb", "shell", "cat", "/sdcard/ui.xml"], capture_output=True, text=True).stdout
        if "<hierarchy" in out:
            return out
        time.sleep(1)
    return ""

want = sys.argv[1]
xml = dump()
for m in re.finditer(r'<node [^>]*>', xml):
    node = m.group(0)
    text = (re.search(r'text="([^"]*)"', node) or [None, ""])[1]
    desc = (re.search(r'content-desc="([^"]*)"', node) or [None, ""])[1]
    if want in text or want in desc:
        x1, y1, x2, y2 = map(int, re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node).groups())
        subprocess.run(["adb", "shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2)])
        print(f"tapped '{want}'")
        sys.exit(0)
print(f"NOT FOUND: '{want}'")
sys.exit(1)
