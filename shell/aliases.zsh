# aliases.zsh — source this from ~/.zshrc:   source ~/path/to/machine-spirit/shell/aliases.zsh
# (Keep this in the repo; NEVER commit your whole ~/.zshrc — it collects secrets.)

# show <file> — render an image inline in iTerm2, else open in the default app.
# Deliberately NOT named `cat`: shadowing a core Unix command is cute until it
# breaks a pipe or script at 3am.
show() {
  case "${1:l}" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.heic|*.bmp|*.tiff)
      command -v imgcat >/dev/null 2>&1 && imgcat -W 500px "$1" || open "$1" ;;
    *) open "$1" ;;
  esac
}

# ccshots [minutes] [max] — snapshot of recent images across projects (one-shot).
# For a LIVE feed, use ccwatch (cc-image-watch.sh).
ccshots() {
  local mins=${1:-60} max=${2:-15}
  local root=${CC_PROJECTS:-$HOME/projects}
  command -v imgcat >/dev/null 2>&1 || { echo "need imgcat (iTerm shell integration)"; return 1; }
  local files; files=$(find "$root" \
      -type d \( -name .git -o -name node_modules -o -name .venv -o -name dist -o -name .next \) -prune -o \
      -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.gif' \) \
      -mmin -"$mins" -print 2>/dev/null)
  [[ -z "$files" ]] && { echo "no images in the last ${mins}m under $root"; return 0; }
  print -r -- "$files" | while IFS= read -r f; do stat -f '%m %N' "$f"; done \
    | sort -rn | head -n "$max" | while read -r _ f; do
        printf '\n\033[1;36m%s\033[0m\n' "$f"
        imgcat -W 480px "$f"
      done
  echo "\n(newest ${max} of last ${mins}m — more: ccshots <min> <count>)"
}
alias ccwatch="$HOME/projects/ccshots/cc-image-watch.sh $HOME/projects"
# Hotkey-window-only greeting (see splash/splash.zsh). iTerm sets
# ITERM_PROFILE in the environment at launch, so it's visible here during
# .zshrc — unlike the profile's "Send text at start", which runs after
# startup. HOTKEY_PANE is kept as a manual override for testing, and exported
# so child processes can detect the hotkey window.
if [[ -n "$HOTKEY_PANE" || "$ITERM_PROFILE" == "Hotkey Window" ]]; then
  export HOTKEY_PANE=1
  source "${${(%):-%N}:A:h}/splash/splash.zsh"
  hotkey_splash
fi
