# TeXlyre-workspace

The TeXlyre frontend of [emacs-collab](../emacs-collab.el). Give a share link
or project UUID; Emacs gets a window layout with the project tree, the main
`.tex` file, the locally built PDF and a terminal, and every `.tex`/`.bib`
buffer syncs live with the TeXlyre editors. Compiling stays local (AUCTeX,
latexmk). GPL-3.0-or-later. Mirrors [overleaf-workspace](../overleaf-workspace).

The pieces:

- `TeXlyre_bridge` ([../TeXlyre_bridge](../TeXlyre_bridge)): joins the project
  through TeXlyre's y-websocket relay and mirrors the text files into a
  directory. Emacs starts it as a subprocess. It has no credentials.
- `emacs-collab.el`: buffer sync, cursors, and `emacs-collab-layout.el`
  (the layout and quit this package uses).
- `texlyre-workspace.el`: the list of relays, project choice, main file and
  PDF location.

## Setup

Build the bridge and put `TeXlyre_bridge` on `PATH` (or set
`texlyre-workspace-bridge-command` to a path or an argv list):

    cd TeXlyre_bridge && cargo build --release

Load the packages (Doom: `package!` recipes pointing at the local repos):

```elisp
(add-to-list 'load-path "~/git_shit/emacs-collab.el")
(add-to-list 'load-path "~/git_shit/TeXlyre-workspace")
(require 'texlyre-workspace)
```

## Relays

The TeXlyre flake serves its y-websocket relay at `/yws` on the TeXlyre
origin (`texlyre --websocket`). The default entry is a placeholder; replace
`YOUR-HOST` with the host (and port) you open TeXlyre at:

```elisp
(setq texlyre-workspace-relays
      '((:name "TeXlyre" :url "wss://YOUR-HOST/yws")))   ; ws:// without TLS
```

Add more entries for more servers; you are asked to pick when there are several.

## Use

`M-x texlyre-open-project`: choose the relay, then paste the share link
(anything containing `#yjs:<uuid>`) or the bare project UUID. Projects you
entered are offered again (add `texlyre-workspace-project-history` to
`savehist-additional-variables` to keep them across sessions).

The project is mirrored under `texlyre-workspace-mirror-directory`
(`~/collab/texlyre/<relay>/<uuid>/`). The layout:

| pane | content |
|---|---|
| tree | treemacs on the mirror directory |
| editor | the bridge's main file if it has `\documentclass`, else the first `.tex` that has one |
| pdf | the local build: `<main>.pdf` in `TeX-output-dir` (for example `build`) |
| terminal | a shell in the mirror directory (vterm, else `shell`) |

Keys, in buffers of the project (`texlyre-workspace-mode`):

| key | command |
|---|---|
| `M-t q` | `texlyre-quit`: save, stop everything, close the layout |
| `M-t r` | `texlyre-workspace-resync`: fetch this buffer's text from the bridge again |
| `M-t s` | `texlyre-workspace-status` |
| `M-t c` | `texlyre-workspace-compile`: AUCTeX's LatexMk if it has one, else `latexmk` |

When AUCTeX finishes a build, the PDF pane shows the new PDF. Files in
`build/` and PDFs, `.aux` and similar are never attached for syncing
(`texlyre-workspace-unsynced-regexp`, via `emacs-collab-attach-predicate`),
so build output never reaches the project.

## Limitations

- **The file tree is read-only from Emacs.** Create, rename and delete files
  in TeXlyre; they appear in the mirror. Edits to the text of existing files
  sync both ways.
- **Binaries and images are not synced.** TeXlyre moves them outside the
  shared documents, so the mirror lacks them and a compile may fail on
  `\includegraphics`. Copy the files into the mirror by hand; the bridge
  leaves them alone.
- **Relay mode only.** Rooms of different providers are not shared, so every
  browser must set TeXlyre's collaboration provider to the websocket mode
  (not WebRTC). The relay has no authentication.
- A project with many documents opens one websocket per document.

## Tests

    emacs -Q --batch -L . -L test -L ../emacs-collab.el <elpa -L dirs> \
      -l test/texlyre-workspace-test.el -f ert-run-tests-batch-and-exit

They run `TeXlyre_bridge --test` through `test/shim.py` (set `TEXLYRE_BRIDGE`
if the binary is not at `~/git_shit/TeXlyre_bridge/target/debug/`).

`test/live.py` is the end-to-end check: it starts the Nix-packaged relay
(`TEXLYRE_YWS`) and a pycrdt "browser" from the bridge's `tests/integration.py`,
then runs batch Emacs (`test/texlyre-workspace-live.el`) through open, edit,
a browser edit coming back, and quit. It kills the servers at the end:

    TEXLYRE_YWS=<texlyre-ywebsocket-server> python3 test/live.py -- -L ../emacs-collab.el <elpa -L dirs>
