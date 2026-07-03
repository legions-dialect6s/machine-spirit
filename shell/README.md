# shell — inline image tooling for iTerm2

Claude Code writes its renders to disk but its TUI eats the terminal escape codes,
so images never appear inline in the CC pane. The fix is to watch the *filesystem*
instead of the terminal. Two tools, one live and one on-demand.

## Requirements
- iTerm2 with **Shell Integration + Utilities** installed (gives `imgcat` / `imgls`):
  iTerm2 → Install Shell Integration. Open a NEW pane afterward so it's on PATH.
- `fswatch` for the live watcher: `brew install fswatch` (already in the Brewfile).

## Live feed — `cc-image-watch.sh`
A dedicated pane that renders every new image across all projects as it lands,
labeled with timestamp + project-relative path. Leave it running in its own pane.

```
./shell/cc-image-watch.sh                       # watch ~/projects
./shell/cc-image-watch.sh ~/projects/moldforge  # scope to one project
CC_IMG_WIDTH=800px ./shell/cc-image-watch.sh    # bigger renders
```

Caveat: it shows EVERY image written — a 42-sheet bake will scroll 42 images. Scope
it to a subfolder (e.g. a project's `renders/`) if a run floods the pane.

## On-demand gallery — `ccshots`
From `aliases.zsh`. Shows images modified in the last N minutes across projects.
Controllable, no flood, no fswatch dependency.

```
ccshots        # last 30 min
ccshots 120    # last 2 hours
```

## `show <file>`
Inline an image in iTerm, else open in the default app. Not named `cat` on purpose.

## Install (make it travel)
Add one line to `~/.zshrc` (do NOT commit your ~/.zshrc — it holds secrets):

```
source ~/projects/aesthetic-mac-setup/shell/aliases.zsh
```

## Getting closer to "automatic"
iTerm Triggers (Settings → Profiles → Advanced → Triggers) can watch a pane's
output for an image-path regex and auto-run `imgcat \1` on a match — but only for
YOUR shell's output, not text captured inside CC's TUI. The filesystem watcher
above is the more reliable path to "images just show up."
