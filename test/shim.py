#!/usr/bin/env python3
"""Test shim: TeXlyre_bridge --test behind the real open params.

Forwards emacs-collab messages to `$TEXLYRE_BRIDGE --test`.  `mirror_dir`
becomes `dir` (what --test wants).  Every open it saw is logged as JSON to
$SHIM_LOG, and an open without a relay/project is answered with an error.
"""
import json, os, subprocess, sys, threading

child = subprocess.Popen([os.environ["TEXLYRE_BRIDGE"], "--test"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, text=True, bufsize=1)
log = os.environ.get("SHIM_LOG")

def pump():
    for line in child.stdout:
        sys.stdout.write(line); sys.stdout.flush()
    os._exit(0)
threading.Thread(target=pump, daemon=True).start()

for line in sys.stdin:
    m = json.loads(line)
    if m.get("t") == "open":
        p = m["params"]
        if log:
            with open(log, "a") as f:
                f.write(json.dumps({"params": p}) + "\n")
        p["dir"] = p.get("mirror_dir")
    child.stdin.write(json.dumps(m) + "\n"); child.stdin.flush()
child.stdin.close()
child.wait()
