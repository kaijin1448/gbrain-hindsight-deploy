#!/usr/bin/env python3
# fix-gbrain-config.py — guard/fix ~/.gbrain/config.json against DLP (绿盾) transparent-encryption corruption.
# Modes:
#   --check     (default) report whether config.json is plaintext JSON or DLP-encrypted/corrupted
#   --snapshot  refresh the golden plaintext copy from the current healthy config.json
#   --fix       restore config.json from the golden copy (or newest usable backup), then verify via gbrain
# Notes:
#   - Always run with the trusted python on your machine (e.g. the python that your DLP trusts);
#     do NOT rewrite config.json via PS/Node — a trusted process keeps the file plaintext.
#   - gbrain may hold the DB lock (serve) — that does not affect this file-level tool.
import json, os, shutil, subprocess, sys, glob, time

HOME = os.path.expanduser(r"~\.gbrain")
CFG = os.path.join(HOME, "config.json")
GOLDEN = os.path.join(HOME, "config.json.golden")
PREFIX = b"%TSD-Header"

def read_head(path, n=16):
    try:
        with open(path, "rb") as f:
            return f.read(n)
    except Exception as e:
        return b""

def is_plain_json(path):
    if not os.path.exists(path):
        return None  # missing
    head = read_head(path)
    if head.startswith(PREFIX):
        return False
    try:
        with open(path, encoding="utf-8") as f:
            json.load(f)
        return True
    except Exception:
        return False

def gbrain_ok():
    for exe in (["gbrain"], [os.path.expanduser(r"~\.bun\bin\gbrain.exe")]):
        try:
            r = subprocess.run(exe + ["engine", "status"], capture_output=True, text=True,
                               encoding="utf-8", errors="replace", timeout=120)
            out = (r.stdout or "") + (r.stderr or "")
            return ("Engine:" in out and "pglite" in out), out[-300:]
        except FileNotFoundError:
            continue
        except Exception as e:
            return False, str(e)
    return False, "gbrain not found"

def snapshot():
    ok = is_plain_json(CFG)
    if ok is not True:
        print("REFUSE snapshot: current config.json is not plaintext JSON (state:", ok, ")")
        return 1
    shutil.copy(CFG, GOLDEN)
    print("golden snapshot updated:", GOLDEN, os.path.getsize(GOLDEN), "bytes")
    return 0

def fix():
    candidates = [GOLDEN] + sorted(glob.glob(os.path.join(HOME, "config.json.bak*")), key=os.path.getmtime, reverse=True)
    src = None
    for c in candidates:
        if os.path.exists(c) and is_plain_json(c) is True:
            src = c
            break
    if not src:
        print("NO usable plaintext source found (golden/backups all bad or missing)")
        return 1
    # keep the corrupted file for inspection
    if os.path.exists(CFG):
        shutil.copy(CFG, CFG + f".corrupt-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy(src, CFG)
    print("restored config.json from:", src)
    ok, msg = gbrain_ok()
    print("gbrain engine status:", "OK" if ok else "STILL BAD")
    print(msg)
    return 0 if ok else 1

def check():
    state = is_plain_json(CFG)
    print("config.json exists:", os.path.exists(CFG))
    print("state:", {True: "plaintext-json-OK", False: "CORRUPTED/encrypted", None: "MISSING"}[state])
    if state is not False:
        ok, msg = gbrain_ok()
        print("gbrain engine status:", "OK" if ok else "BAD", "|", msg.splitlines()[-1] if msg else "")
    return 0 if state is True else 1

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    if mode == "--snapshot":
        sys.exit(snapshot())
    elif mode == "--fix":
        sys.exit(fix())
    else:
        sys.exit(check())
