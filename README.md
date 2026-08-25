# canopy.hx

The ultimate file tree for Steel-enabled Helix: a persistent docked sidebar,
minimalist at rest, powerful on demand.

Forked from [forest.hx](https://github.com/Ra77a3l3-jar/forest.hx) (MIT) and
reshaped: full vim navigation, filter-search that reshapes the tree, file
operations that follow open buffers, git awareness, full mouse support.

Status: v0 in active development. See SPEC in the parent project.

## Keys (v0)

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
| `?` or `Space` | help popup |
| `n` / `N` | new file / new directory |
| `r` / `m` | rename / move |
| `y` / `p` | yank entry / paste a copy |
| `Y` | copy absolute path to clipboard |
| `d` | delete (confirms; trash when available) |
| `/` | filter search (box appears only while active) |
| `.` / `i` | toggle dotfiles / git-ignored |
| `R` | refresh |
| `+` / `-` | resize |
| `Esc`, any ctrl/alt chord | focus editor |

Git status badges mark changed files and propagate to their parent
directories; badges match paths against the repo root, so they survive
root dives. The tree follows the focused buffer (`#:auto-reveal`).
Renaming or moving a file whose buffer is open and clean re-paths the
buffer; a dirty buffer gets a warning instead. Expanded directories
persist per root under `~/.local/state/canopy/`. File icons come from
devicons.hx (nvim-tree catalog).

Known-binary files are refused with a status message instead of opening as
raw bytes.

## License

MIT. Based on forest.hx, Copyright (c) 2026 Raffaele Meo.
