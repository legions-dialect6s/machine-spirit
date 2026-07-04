# Brewfile — declarative list of everything this setup installs.
# Apply with:  brew bundle --file=Brewfile

# --- Core of the keyboard-driven workflow ---
cask "leader-key"          # nested/leader-key launcher (the heart of the setup)
cask "karabiner-elements"  # remaps Caps Lock -> F19 (silent leader key)
cask "iterm2"              # terminal
cask "rectangle"           # window snapping — driven from Leader Key via its rectangle:// URL scheme

# --- Menu bar ---
cask "stats"               # exelban/Stats — CPU/GPU/mem/network system monitor
# Note (macOS 26+): allow Stats under System Settings > Menu Bar or its icons
# won't show. Sensors + Bluetooth modules are the heaviest — disable them in
# Stats' settings if you want lower CPU/energy use.

# --- Menu bar management ---
# On macOS 15 (Sequoia) or earlier, use Ice:
cask "jordanbaird-ice"
# On macOS 26 (Tahoe): Ice's upstream slowed down and Tahoe changed the menu bar.
# Prefer the maintained fork "Thaw" (github.com/stonerl/Thaw) — install it manually
# from its releases page and comment out the jordanbaird-ice line above.

# --- Repo safety tooling ---
brew "gitleaks"            # scans commits for leaked secrets (used by the pre-commit hook)

# --- Shell / workflow ---
brew "fswatch"            # filesystem watcher for shell/cc-image-watch.sh (live image feed)

# --- Busy-pane shield (experimental, bin/pane-shield.py) ---
# No brew deps: SFX play via macOS-built-in `afplay`; the daemon runs on iTerm2's
# own bundled Python runtime + `iterm2` module (auto-installed when you enable
# iTerm's Python API). The optional visual overlay (assets/tools/shield-fx.swift)
# compiles with `swiftc` from the Xcode Command Line Tools — already present if
# you've built the splash art. Nothing to `brew install`; noted for discoverability.

# --- Terminal splash (shell/splash) ---
brew "fastfetch"           # system info panel in the hotkey-window splash
# Optional, only needed to regenerate splash art (all banners/logos ship pre-rendered):
# brew "chafa"             # image -> terminal block art (shell/splash/tools)
