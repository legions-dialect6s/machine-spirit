#!/usr/bin/env zsh
export PATH="$HOME/.iterm2:/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
# cc-image-watch.sh — a live, cross-project image feed for iTerm2.
#
# Watches one or more directories; the instant Claude Code (or anything) writes
# an image, prints a label and renders it inline with imgcat. Because it watches
# the FILESYSTEM, not a terminal, it catches images regardless of which pane or
# CC session produced them — solving the "CC's TUI eats the escape codes" problem.
#
# Run it in its own dedicated iTerm pane and leave it going.
#
#   ./cc-image-watch.sh                       # watches ~/projects
#   ./cc-image-watch.sh ~/projects/moldforge  # scope to one project
#   ./cc-image-watch.sh ~/projects /private/tmp/claude-501  # add CC scratchpads
#
# Env:
#   CC_IMG_WIDTH   max render width (default 500px) so contact sheets don't blow up the pane

if ! command -v fswatch >/dev/null 2>&1; then
  echo "Need fswatch:  brew install fswatch" >&2; exit 1
fi
if ! command -v imgcat >/dev/null 2>&1; then
  echo "Need imgcat: iTerm2 → Install Shell Integration, and run this inside an iTerm pane." >&2; exit 1
fi

if (( $# )); then DIRS=("$@"); else DIRS=("$HOME/projects"); fi
WIDTH="${CC_IMG_WIDTH:-500px}"

typeset -A SEEN

echo "\033[1;32m👁  cc-image-watch\033[0m — watching: ${DIRS[*]}"
echo "   width=${WIDTH} · Ctrl+C to stop\n"

printf '\033]0;👁 ccwatch\007'   # rename the iTerm2 pane/tab so it's identifiable at a glance

fswatch -0 -r \
  --exclude '/\.git/' --exclude '/node_modules/' \
  --exclude '/\.venv/' --exclude '/\.next/' --exclude '/dist/' \
  "${DIRS[@]}" | while IFS= read -r -d '' img; do
    # NB: read into `img`, NOT `path` — in zsh `path` is the array bound to $PATH,
    # so reading each filename into it would wipe /bin out of PATH and break
    # sleep/date/stat/imgcat below. We also call tools by absolute path / `command`
    # so a clobbered PATH can never break this loop again.
    case "${img:l}" in
      *.png|*.jpg|*.jpeg|*.gif|*.webp|*.heic|*.bmp|*.tiff) ;;
      *) continue ;;
    esac
    [[ -f "$img" ]] || continue
    mt=$(/usr/bin/stat -f %m "$img" 2>/dev/null || echo 0)
    [[ "${SEEN[$img]:-}" == "$mt" ]] && continue     # dedupe repeated write events
    SEEN[$img]="$mt"
    /bin/sleep 0.3                                    # let the writer finish flushing
    ts=$(/bin/date '+%H:%M:%S')
    abs="${img:A}"                                    # absolute, symlink-resolved
    caption="${img#$HOME/projects/}"                  # short human caption only
    caption="${caption#/private/tmp/*/}"              # trim CC scratchpad prefix
    # Two lines: a human caption, then the bare absolute path on its OWN line so
    # iTerm2 Cmd-click resolves it (Semantic History → "open with default app").
    printf '\n\033[1;36m[%s]\033[0m %s\n' "$ts" "$caption"
    printf '%s\n' "$abs"
    command imgcat -W "$WIDTH" "$abs" 2>/dev/null || echo "  (couldn't render)"
done
