#!/usr/bin/env python3
"""Live check: a real y-websocket relay, a scripted browser (pycrdt) and batch Emacs
running texlyre-open-project (test/texlyre-workspace-live.el).

  TEXLYRE_YWS=/path/to/texlyre-ywebsocket-server \
  TEXLYRE_BRIDGE=/path/to/TeXlyre_bridge \
  TEXLYRE_BRIDGE_REPO=~/git_shit/TeXlyre_bridge  python3 test/live.py [-- emacs args]

Reuses Relay/Browser from TeXlyre_bridge/tests/integration.py.  Emacs args
(load paths) are taken from the command line after `--`.  Servers are killed at the end.
"""
import asyncio, os, shutil, sys, tempfile

repo = os.path.expanduser(os.environ.get("TEXLYRE_BRIDGE_REPO", "~/git_shit/TeXlyre_bridge"))
sys.path.insert(0, os.path.join(repo, "tests"))
os.environ.setdefault("TEXLYRE_BRIDGE", os.path.join(repo, "target/debug/TeXlyre_bridge"))
import integration as it  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


async def main():
    port = it.free_port()
    relay = it.Relay(port)
    tmp = tempfile.mkdtemp(prefix="tlw-live-")
    relay.start()
    br = proc = None
    try:
        br = it.Browser(port)
        br.add_doc("docmain", "main.tex", "\\documentclass{article}\n\\begin{document}\nHi 😀\n\\end{document}\n")
        br.add_doc("docbib", "refs.bib", "@misc{a}\n")
        br.data["projectMetadata"] = {"name": "Live", "mainFile": "/main.tex"}
        await asyncio.sleep(0.5)
        env = dict(os.environ, TLW_RELAY=f"ws://127.0.0.1:{port}/", TLW_PROJECT=f"https://x.example/#yjs:{it.PID}",
                   TLW_BRIDGE=it.BRIDGE, TLW_BASE=tmp)
        proc = await asyncio.create_subprocess_exec(
            "emacs", "-Q", "--batch", "-L", os.path.join(HERE, ".."), *args,
            "-l", os.path.join(HERE, "texlyre-workspace-live.el"), env=env)
        _, bt = br.doc("docmain")
        await it.until(lambda: "EMACS-MARK" in str(bt), "Emacs edit reaches the browser", 60)
        print("PASS emacs edit seen by the browser", flush=True)
        it.tins(bt, len(str(bt)), "BROWSER-MARK\n")
        rc = await asyncio.wait_for(proc.wait(), 60)
        assert rc == 0, f"emacs exited {rc}"
        text = str(bt)
        assert text.count("EMACS-MARK") == 1 and text.count("BROWSER-MARK") == 1, text
        mirrored = open(os.path.join(tmp, "mirror/live", it.PID, "main.tex")).read()
        assert mirrored == text, (mirrored, text)
        print("PASS both edits merged once; mirror file saved from Emacs equals the shared text")
        print("LIVE (python): PASS")
    finally:
        if proc and proc.returncode is None:
            proc.kill()
        if br:
            await br.close()
        relay.stop()
        shutil.rmtree(tmp, ignore_errors=True)


asyncio.run(main())
