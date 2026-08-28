#!/usr/bin/env bash
# install.sh: build and install the Steel-enabled Helix stack and canopy from
# pinned, known-good revisions. Idempotent: re-runs skip steps already done at
# the pin. Linux (Fedora, Ubuntu/Debian, Arch) and macOS.
#
# Usage:
#   git clone https://github.com/a-marr/canopy.hx.git && cd canopy.hx && ./install.sh
#   curl -fsSL https://raw.githubusercontent.com/a-marr/canopy.hx/master/install.sh | bash
#
# Environment overrides:
#   CANOPY_SRC_DIR    where sources are cloned and built (default ~/.local/src/canopy-stack);
#                     the helix clone must persist, the runtime symlink points into it
#   HELIX_STEEL_REV   commit of mattwparas/helix (steel-event-system) to build
#   STEEL_REV         commit of mattwparas/steel to build the tools from
#   CANOPY_REV        canopy commit, tag, or branch when not run from a checkout
#
# Installs to ~/.cargo/bin: hx (with plugin support), forge, steel tools. A
# distro or brew hx stays on disk as a fallback; make sure ~/.cargo/bin comes
# first on PATH. Never edits an existing ~/.config/helix/init.scm.
set -euo pipefail

HELIX_STEEL_REPO="https://github.com/mattwparas/helix.git"
HELIX_STEEL_REV="${HELIX_STEEL_REV:-5a8635beda77414850a2b9604aa0643e4713db3b}"  # 2026-08-22
STEEL_REPO="https://github.com/mattwparas/steel.git"
STEEL_REV="${STEEL_REV:-1b785a4e9d24e3553b242522b35d4498dae72816}"
CANOPY_REPO="https://github.com/a-marr/canopy.hx.git"
CANOPY_REV="${CANOPY_REV:-master}"
SRC_DIR="${CANOPY_SRC_DIR:-$HOME/.local/src/canopy-stack}"
MIN_RUST_MAJOR=1
MIN_RUST_MINOR=90

STAMPS="$SRC_DIR/.stamps"
CONFIG="$HOME/.config/helix"
OS="$(uname -s)"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- preflight ---------------------------------------------------------------
say "Preflight ($OS)"

# the one-line install for whatever this machine uses
deps_hint() {
  if [ "$OS" = "Darwin" ]; then echo "xcode-select --install"
  elif have dnf;      then echo "sudo dnf install git gcc openssl-devel pkgconf-pkg-config"
  elif have apt-get;  then echo "sudo apt install git build-essential libssl-dev pkg-config"
  elif have pacman;   then echo "sudo pacman -S --needed git base-devel openssl pkgconf"
  else echo "git, a C compiler, OpenSSL headers and pkg-config"
  fi
}
RUST_HINT="rustup (https://rustup.rs): curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"

missing=()
have git || missing+=("git")
have cc || have gcc || have clang || missing+=("a C compiler")
if [ "$OS" = "Linux" ]; then
  if ! { have pkg-config && pkg-config --exists openssl 2>/dev/null; } && ! have perl; then
    missing+=("OpenSSL headers and pkg-config")
  fi
fi
if [ ${#missing[@]} -gt 0 ]; then
  printf 'Missing:\n'; printf '  - %s\n' "${missing[@]}"
  printf 'Install with:\n  %s\n' "$(deps_hint)"
  exit 1
fi

if ! have cargo || ! have rustc; then
  printf 'Missing: a Rust toolchain (%d.%d or newer).\nInstall with:\n  %s\n' \
    "$MIN_RUST_MAJOR" "$MIN_RUST_MINOR" "$RUST_HINT"
  exit 1
fi
rust_ver="$(rustc --version | awk '{print $2}')"
rust_major="${rust_ver%%.*}"; rust_rest="${rust_ver#*.}"; rust_minor="${rust_rest%%.*}"
if [ "$rust_major" -lt "$MIN_RUST_MAJOR" ] || { [ "$rust_major" -eq "$MIN_RUST_MAJOR" ] && [ "$rust_minor" -lt "$MIN_RUST_MINOR" ]; }; then
  printf 'Rust %s is too old (need %d.%d+). Distro packages often lag; use rustup:\n  %s\n' \
    "$rust_ver" "$MIN_RUST_MAJOR" "$MIN_RUST_MINOR" "$RUST_HINT"
  exit 1
fi
# system OpenSSL when available; the vendored build needs perl and takes longer
if have pkg-config && pkg-config --exists openssl 2>/dev/null; then
  export OPENSSL_NO_VENDOR=1
  ssl="system openssl"
else
  ssl="vendored openssl (slower build)"
fi
echo "ok: git, cc, rust $rust_ver, $ssl"
mkdir -p "$SRC_DIR" "$STAMPS"
# a full build plus grammar sources is about 6 GB
avail_kb="$(df -Pk "$SRC_DIR" | awk 'NR==2{print $4}')"
if [ -n "$avail_kb" ] && [ "$avail_kb" -lt $((8*1024*1024)) ]; then
  warn "less than 8 GB free under $SRC_DIR; the build needs about 6 GB"
fi

# --- helpers -----------------------------------------------------------------
# clone_at <repo-url> <rev> <dir>: fresh clone or fetch, hard-pinned to rev
clone_at() {
  local repo="$1" rev="$2" dir="$3"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch --quiet origin
  else
    git clone --quiet "$repo" "$dir"
  fi
  git -C "$dir" checkout --quiet --force "$rev"
}
stamp_ok()  { [ -f "$STAMPS/$1" ] && [ "$(cat "$STAMPS/$1")" = "$2" ]; }
stamp_set() { printf '%s' "$2" > "$STAMPS/$1"; }

# --- 1. steel tools ----------------------------------------------------------
say "Steel tools (interpreter, language server, cargo-steel-lib)"
if stamp_ok steel-tools "$STEEL_REV" && [ -x "$HOME/.cargo/bin/steel" ]; then
  echo "already at pin, skipping"
else
  cargo install --git "$STEEL_REPO" --rev "$STEEL_REV" \
    steel-interpreter steel-language-server cargo-steel-lib --locked --force
  stamp_set steel-tools "$STEEL_REV"
fi

# --- 2. forge, built without jit2 -------------------------------------------
# Steel's jit2 makes heap memory executable, which SELinux (Fedora) and some
# macOS setups deny (execheap). forge only needs the interpreter, so the
# feature is stripped: uniform and safe everywhere.
say "forge (Steel package manager)"
if stamp_ok forge "$STEEL_REV" && [ -x "$HOME/.cargo/bin/forge" ]; then
  echo "already at pin, skipping"
else
  clone_at "$STEEL_REPO" "$STEEL_REV" "$SRC_DIR/steel"
  sed -i.bak 's/"biased", "jit2", "imbl"/"biased", "imbl"/' "$SRC_DIR/steel/crates/forge/Cargo.toml"
  rm -f "$SRC_DIR/steel/crates/forge/Cargo.toml.bak"
  if grep -q '"jit2"' "$SRC_DIR/steel/crates/forge/Cargo.toml"; then
    warn "could not strip jit2 from forge's Cargo.toml (upstream changed the feature list); refusing to build it with jit2"
    exit 1
  fi
  cargo install --path "$SRC_DIR/steel/crates/forge" --force
  stamp_set forge "$STEEL_REV"
fi

# --- 3. Steel-enabled helix --------------------------------------------------
say "Steel-enabled hx (this is the long compile)"
if stamp_ok hx "$HELIX_STEEL_REV" && [ -x "$HOME/.cargo/bin/hx" ]; then
  echo "already at pin, skipping"
else
  clone_at "$HELIX_STEEL_REPO" "$HELIX_STEEL_REV" "$SRC_DIR/helix"
  cargo install --path "$SRC_DIR/helix/helix-term" --features steel,git --locked --force
  stamp_set hx "$HELIX_STEEL_REV"
fi

# --- 4. runtime + grammars ---------------------------------------------------
say "Runtime (grammars, queries, themes)"
mkdir -p "$CONFIG"
if [ -e "$CONFIG/runtime" ] && [ ! -L "$CONFIG/runtime" ]; then
  warn "$CONFIG/runtime exists and is not a symlink; leaving it alone."
  warn "hx will use it as-is; point it at $SRC_DIR/helix/runtime if themes or grammars look wrong."
else
  ln -sfn "$SRC_DIR/helix/runtime" "$CONFIG/runtime"
fi
if stamp_ok grammars "$HELIX_STEEL_REV"; then
  echo "grammars already built for this pin, skipping"
else
  "$HOME/.cargo/bin/hx" --grammar fetch
  "$HOME/.cargo/bin/hx" --grammar build
  stamp_set grammars "$HELIX_STEEL_REV"
fi

# --- 5. canopy ---------------------------------------------------------------
# run from a checkout: install that checkout; piped or elsewhere: clone the pin
say "canopy"
here=""
src="${BASH_SOURCE[0]:-}"
if [ -n "$src" ] && [ -f "$src" ]; then
  here="$(cd "$(dirname "$src")" && pwd)"
fi
if [ -n "$here" ] && grep -q "package-name 'canopy" "$here/cog.scm" 2>/dev/null; then
  echo "installing from checkout: $here"
  (cd "$here" && forge install)
else
  clone_at "$CANOPY_REPO" "$CANOPY_REV" "$SRC_DIR/canopy"
  (cd "$SRC_DIR/canopy" && forge install)
fi
# forge reports errors but still exits 0, so check the result on disk
COGS="${STEEL_HOME:-$HOME/.local/share/steel}/cogs"
for cog in canopy notify glyph devicons; do
  if [ ! -f "$COGS/$cog/cog.scm" ] && [ ! -f "$COGS/$cog/$cog.scm" ]; then
    warn "forge did not install '$cog' (look for an error above); aborting"
    exit 1
  fi
done

# --- 6. config ---------------------------------------------------------------
say "Config"
INIT="$CONFIG/init.scm"
SNIPPET='(require "canopy/canopy.scm")
(require "helix/keymaps.scm")

(canopy-start!)                                   ; dock at startup, editor keeps focus
(canopy-configure! '"'"'left #:ignore (list ".git" "target"))

;; Space-e toggles the panel; C-h focuses the tree, C-l returns to the buffer.
;; backspace doubles as C-h for terminals that still send Ctrl+h as 0x08.
(keymap (global)
        (normal (space (e ":canopy-toggle"))
                (C-h ":canopy-focus")
                (backspace ":canopy-focus")))'
if [ ! -e "$INIT" ] && [ ! -L "$INIT" ]; then
  printf '%s\n' "$SNIPPET" > "$INIT"
  echo "wrote starter $INIT"
elif [ -L "$INIT" ] && [ ! -e "$INIT" ]; then
  warn "$INIT is a symlink to a missing file (dotfiles not checked out yet?); add this to it later:"
  echo
  printf '%s\n' "$SNIPPET" | sed 's/^/    /'
elif grep -q 'canopy/canopy.scm' "$INIT"; then
  echo "$INIT already loads canopy, leaving it alone"
else
  echo "$INIT exists; add this to it:"
  echo
  printf '%s\n' "$SNIPPET" | sed 's/^/    /'
fi

# --- done --------------------------------------------------------------------
say "Done in $((SECONDS/60))m $((SECONDS%60))s"
"$HOME/.cargo/bin/hx" --version
resolved="$(command -v hx || true)"
echo "hx on PATH resolves to: ${resolved:-<none>}"
if [ "$resolved" != "$HOME/.cargo/bin/hx" ]; then
  warn "that is not ~/.cargo/bin/hx: put ~/.cargo/bin first on PATH (or open a new shell)."
fi
echo "Icons and chevrons are Nerd Font glyphs: use a Nerd Font in your terminal (https://www.nerdfonts.com)."
echo "Try it: cd into a git repo and run hx."
