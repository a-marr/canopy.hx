# canopy.hx

The ultimate file tree for Steel-enabled Helix: a persistent docked sidebar,
minimalist at rest, powerful on demand.

Forked from [forest.hx](https://github.com/Ra77a3l3-jar/forest.hx) (MIT) and
reshaped: full vim navigation, filter-search that reshapes the tree, file
operations that follow open buffers, git awareness, full mouse support.

Requires mattwparas' Steel-enabled Helix fork (branch `steel-event-system`).
It does not run on stock Helix, which has no plugin runtime.

Status: feature-complete for daily use; the API may still shift.

## Install

canopy runs inside the Steel-enabled Helix fork, so installing it means
building that fork plus Steel's package manager. `install.sh` does the whole
thing from pinned, known-good revisions and is safe to re-run.

Dependencies: git, a Rust toolchain 1.90 or newer ([rustup](https://rustup.rs);
distro packages often lag), a C compiler, and on Linux the OpenSSL headers plus
pkg-config. Use a Nerd Font in your terminal for the icons.

| Platform | Dependencies |
|----------|--------------|
| macOS | `xcode-select --install` |
| Fedora | `sudo dnf install git gcc openssl-devel pkgconf-pkg-config` |
| Ubuntu / Debian | `sudo apt install git build-essential libssl-dev pkg-config` |
| Arch | `sudo pacman -S --needed git base-devel openssl pkgconf` |

Then:

```sh
git clone https://github.com/a-marr/canopy.hx.git
cd canopy.hx
./install.sh
```

The first run compiles Helix; allow 10 to 20 minutes and about 6 GB under
the source directory. It installs `hx`,
`forge`, and the Steel tools to `~/.cargo/bin` (a distro or brew `hx` stays on
disk as a fallback, so keep `~/.cargo/bin` first on PATH), links the Helix
runtime, builds the grammars, installs canopy with its dependencies, and writes
a starter `~/.config/helix/init.scm` if you have none. An existing `init.scm`
is never edited; the snippet to add is printed instead. Sources live under
`~/.local/src/canopy-stack` (`CANOPY_SRC_DIR` moves them; the Helix clone must
stay, the runtime symlink points into it).

Already on Steel Helix with `forge`? Skip the script:

```sh
forge pkg install --git https://github.com/a-marr/canopy.hx.git
```

and add the snippet from Configuration below to `init.scm`. Use the https
URL: forge clones through libgit2 without credential callbacks, so ssh
remotes and private repos fail (and forge still exits 0 when they do).

The fork tracks upstream Helix closely and is daily-driven by its users;
`install.sh` pins the revision canopy was last tested against.

## Keys

| Key | Action |
|-----|--------|
| `j` / `k` | move linearly through the visible tree (clamped) |
| `h` | collapse expanded dir, else jump to parent |
| `l` | expand dir / open file |
| `gg` / `G` | top / bottom |
| `Ctrl-d` / `Ctrl-u` | half page down / up |
| `Enter` | open file / toggle dir |
| `Ctrl-s` / `Ctrl-v` | open in horizontal / vertical split |
| `f` | reveal current buffer's file (expand ancestors) |
| `>` / `<` | dive into dir as new root / climb out |
| `P` | toggle file preview popup |
| `Space f` / `Space e` | file picker / toggle panel (mini-leader) |
| `?` or `Space Space` | help popup |
| `n` | new file, or new directory when the name ends in `/` |
| `r` / `m` | rename / move |
| `y` / `p` | yank entry / paste a copy |
| `Y` | copy absolute path to clipboard |
| `d` | delete (confirms; trash when available) |
| `/` | filter search (box appears only while active) |
| `.` / `i` | toggle dotfiles / git-ignored |
| `R` | refresh |
| `+` / `-` | resize |
| `q` | close the panel |
| `:` | hand focus back and open the editor command line |
| `Esc`, `Ctrl-l`, other chords | focus editor |

The look: the root row doubles as a header band (menu-shade background,
changed-file count at the right edge, hidden when clean). Faint indent
guides trace depth, directories carry slim chevrons, and git state
renders as a themed dot with the filename tinted to match (diff colors
from your theme). Clean files stay plain; changed state propagates to
parent directories as a dot. Badges match paths against the repo root,
so they survive root dives. Symlinks carry a dim `→ target` suffix.
Popups (rename/new/move/delete, help, preview) share one kit: `ui.popup`
backdrop, visible border, bold title in the top edge.

Cursor semantics: refocusing the tree restores your last position. The
tree only jumps to the active file when the buffer actually changed
since the tree last saw it (`#:auto-reveal`, also covering startup and
changes made while the panel was hidden), or on demand via `f`.
Renaming or moving a file whose buffer is open and clean re-paths the
buffer; a dirty buffer gets a warning instead. Expanded directories
persist per root under `~/.local/state/canopy/`. File icons come from
devicons.hx (nvim-tree catalog).

Known-binary files are refused with a status message instead of opening as
raw bytes.

## Configuration

```scheme
;; init.scm
(require "canopy/canopy.scm")
(require "helix/keymaps.scm")

(canopy-start!)                       ; dock at startup, editor keeps focus

(canopy-configure! 'left              ; or 'right
                   #:ignore (list ".git" "target")
                   #:linear-nav #t    ; sibling-wrap when #f
                   #:auto-reveal #t   ; follow the focused buffer
                   #:use-trash 'auto) ; 'never deletes directly
(canopy-set-style! 'snacks)           ; or 'mini (floating columns)

;; Space-e toggles visibility; C-h/C-l move focus tree <-> buffer.
;; backspace aliases C-h for terminals using legacy encoding.
(keymap (global)
        (normal (space (e ":canopy-toggle"))
                (C-h ":canopy-focus")
                (backspace ":canopy-focus")))
```

Commands: `:canopy-open` (focus, opening if needed, Esc-toggle style),
`:canopy-focus` (focus, no-op if already focused), `:canopy-toggle`
(visibility only), `:canopy-close`, plus `(canopy-start!)` for init.scm.

## License

MIT. Based on forest.hx, Copyright (c) 2026 Raffaele Meo.
