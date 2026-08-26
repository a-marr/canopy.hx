# Testing canopy

canopy is exercised end-to-end in a real terminal via tmux: the actual `hx`
binary runs in a detached session, keys are injected, and the rendered screen
is read back. No mocks.

## Harness

- Session: `tmux new-session -d -s <name> -x 180 -y 45 -c <fixture> 'hx z.txt'`,
  then `sleep 5` for startup (canopy docks via a deferred callback).
- Keys: `tmux send-keys -t <name> <key>`, ~1s apart, 2s after anything that
  refreshes the tree (open, rename, R, root change). Quote `<`, `>`, `?` and
  friends for the shell. `Space` then `e` are two separate sends.
- Screen: `tmux capture-pane -p -t <name>` for content,
  `capture-pane -pe` for styling. The tree's selected row carries the
  background escape `[48;2;69;71;90m` (theme `ui.menu.selected`); extract it:
  `capture-pane -pe | grep -F '[48;2;69;71;90m' | head -1 | sed 's/\x1b\[[0-9;]*m//g'`
- Toasts render top-right as bordered boxes; the statusline is the last rows.

## Fixture

A small git repo:

```
navtest/
├── dir1/f1.txt      (modified vs HEAD)
├── dir1/f2.txt
├── dir1/new.txt     (untracked)
├── dir2/
├── img.png          (binary-guard target)
└── z.txt
```

## Key-encoding gotchas

- `C-[` cannot be tested or bound: it IS Escape (0x1B).
- Legacy encoding sends `C-h` as backspace (0x08); terminals speaking the
  kitty keyboard protocol (ghostty, kitty) deliver a real `C-h`. tmux sends
  the legacy byte, so tests exercise the backspace alias path.
- tmux capital letters are sent as the literal (`H`), never `S-h`.
- Some private-use icon glyphs (devicons) may not survive `capture-pane`;
  verify icon presence by column alignment, identity by eye in a real
  terminal.

## State to reset between runs

- `~/.local/state/canopy/*.list` persists expanded dirs per root and restores
  them at startup; delete or account for it in expectations.
- The fixture's git status must match the table above (`git status --short`:
  ` M dir1/f1.txt`, `?? dir1/new.txt`).
