#!/bin/bash
# Whole-screen recording, detached so Leader Key doesn't hang waiting on it.
# Stop with:  ss r x   (or Cmd-Ctrl-Esc)
SHOTDIR="$HOME/Documents/screenshots_n_recordings"
mkdir -p "$SHOTDIR"
nohup screencapture -v "$SHOTDIR/rec-$(date +%Y%m%d-%H%M%S).mov" >/dev/null 2>&1 &
