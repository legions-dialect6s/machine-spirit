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

# --- tmux integration (bin/tmux-*.sh: t t launch, t d split, t m u x sheol) ---
brew "tmux"               # start-time pane protection (plain tmux, one window) + the sheol recovery TUI

# --- Terminal splash (shell/splash) ---
brew "fastfetch"           # system info panel in the hotkey-window splash
# Optional, only needed to regenerate splash art (all banners/logos ship pre-rendered):
# brew "chafa"             # image -> terminal block art (shell/splash/tools)

# --- MachineSpirit.app (app/, kit/, forks/) — build-time only ---
# Building the app and forks needs full Xcode (not just CLT). Optional:
# brew "xcodegen"          # regenerates app/MachineSpirit/MachineSpirit.xcodeproj from project.yml (generated project is committed)
# brew "imagemagick"       # regenerates the fork's skull AppIcon (forks/LeaderKey/tools/make-appicon.sh); PNGs ship pre-rendered
