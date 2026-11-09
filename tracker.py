"""Personal activity tracker (Windows). Samples the app under each monitor's centre,
writes usage_<date>.csv, syncs the day to Firestore, and lives in the tray.
Run with pythonw.exe so no console or taskbar button appears.
Only the Track mode of ActivityTracker.ps1 is ported.
"""
import csv
import ctypes
import datetime as dt
import json
import os
import sys
import threading
import urllib.request
from ctypes import wintypes
from pathlib import Path

import pystray
from PIL import Image, ImageDraw

INTERVAL = 10          # seconds between samples
IDLE_LIMIT = 300       # no keyboard/mouse for this long = idle (not counted)
OUT_DIR = Path(os.environ["USERPROFILE"]) / "ActivityLog"
FIELDS = ["Date", "Time", "App", "Seconds", "Monitor", "Focused"]
FS_URL = ("https://firestore.googleapis.com/v1/projects/tracker-b6337/databases/(default)"
          "/documents/activity/{machine}/days/{date}?key=AIzaSyA3ECe1AN5m1C4XO4LszBc6wj9xRkxmkmA")
# ponytail: whole-day overwrite every sample, no delta logic; rules must restrict writes or anyone with the key can write.

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
user32.SetProcessDPIAware()  # real pixel coords, so monitor centres map correctly on scaled displays

user32.GetForegroundWindow.restype = ctypes.c_void_p
user32.WindowFromPoint.argtypes = [wintypes.POINT]
user32.WindowFromPoint.restype = ctypes.c_void_p
user32.GetAncestor.argtypes = [ctypes.c_void_p, wintypes.UINT]
user32.GetAncestor.restype = ctypes.c_void_p
user32.IsIconic.argtypes = [ctypes.c_void_p]
kernel32.OpenProcess.restype = ctypes.c_void_p
kernel32.CloseHandle.argtypes = [ctypes.c_void_p]


class LASTINPUTINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.UINT), ("dwTime", wintypes.DWORD)]


MONPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, ctypes.c_void_p, ctypes.c_void_p,
                             ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)


def monitor_rects():
    rects = []

    def cb(hmon, hdc, lprc, lparam):
        r = lprc.contents
        rects.append((r.left, r.top, r.right, r.bottom))
        return True

    user32.EnumDisplayMonitors(None, None, MONPROC(cb), 0)
    return rects


def idle_seconds():
    li = LASTINPUTINFO(ctypes.sizeof(LASTINPUTINFO))
    user32.GetLastInputInfo(ctypes.byref(li))
    return ((kernel32.GetTickCount() - li.dwTime) & 0xFFFFFFFF) / 1000


def process_name(pid):
    h = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return None
    try:
        buf = ctypes.create_unicode_buffer(1024)
        size = wintypes.DWORD(1024)
        if kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
            return Path(buf.value).stem  # same as PowerShell ProcessName (no .exe)
        return None
    finally:
        kernel32.CloseHandle(h)


def sample_once(now):
    """One row per monitor whose centre window is visible and not minimized."""
    fg = user32.GetForegroundWindow()
    rows = []
    for idx, (l, t, r, b) in enumerate(monitor_rects(), start=1):
        h = user32.GetAncestor(user32.WindowFromPoint(wintypes.POINT((l + r) // 2, (t + b) // 2)), 2)  # GA_ROOT
        # minimized windows can't be focused, so this also covers "not focused and minimized"
        if not h or user32.IsIconic(h):
            continue
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(h, ctypes.byref(pid))
        app = process_name(pid.value)
        if not app:
            continue
        rows.append({"Date": now.strftime("%Y-%m-%d"), "Time": now.strftime("%H:%M:%S"),
                     "App": app, "Seconds": INTERVAL, "Monitor": idx, "Focused": h == fg})
    return rows


def append_rows(date, rows):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    f = OUT_DIR / f"usage_{date}.csv"
    new = not f.exists()
    with f.open("a", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, FIELDS, quoting=csv.QUOTE_ALL)
        if new:
            w.writeheader()
        w.writerows(rows)


def send_day(date):
    f = OUT_DIR / f"usage_{date}.csv"
    if not f.exists():
        return
    apps = {}
    with f.open(newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            apps[r["App"]] = apps.get(r["App"], 0) + int(r["Seconds"])
    machine = os.environ["COMPUTERNAME"]
    body = {"fields": {
        "machine": {"stringValue": machine},
        "date": {"stringValue": date},
        "updated": {"timestampValue": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
        "apps": {"mapValue": {"fields": {k: {"integerValue": str(v)} for k, v in apps.items()}}},
    }}
    req = urllib.request.Request(FS_URL.format(machine=machine, date=date), method="PATCH",
                                 data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=15).close()


def log(msg):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with (OUT_DIR / "tracker.log").open("a", encoding="utf-8") as fh:
        fh.write(f"{dt.datetime.now():%Y-%m-%d %H:%M:%S} {msg}\n")


stop = threading.Event()


def track_loop():
    while not stop.wait(INTERVAL):
        try:
            if idle_seconds() > IDLE_LIMIT:
                continue
            now = dt.datetime.now()
            rows = sample_once(now)
            if not rows:
                continue
            date = now.strftime("%Y-%m-%d")
            append_rows(date, rows)
            try:
                send_day(date)
            except Exception as e:  # Firebase down must not stop tracking
                log(f"Firebase: {e}")
        except Exception as e:
            log(f"sample error: {e}")


def make_icon_image():
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    ImageDraw.Draw(img).ellipse((4, 4, 60, 60), fill=(0, 120, 215, 255))
    return img


def on_exit(icon, item):
    stop.set()
    icon.stop()


if __name__ == "__main__":
    if "--once" in sys.argv:  # self-check: show what one sample sees, write nothing
        for r in sample_once(dt.datetime.now()):
            print(r)
    else:
        threading.Thread(target=track_loop, daemon=True).start()
        pystray.Icon("ActivityTracker", make_icon_image(), "Activity tracker",
                     menu=pystray.Menu(pystray.MenuItem("Exit", on_exit))).run()
