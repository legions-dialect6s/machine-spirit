#!/bin/bash
# Region recording via the native toolbar, detached.
SHOTDIR="$HOME/Documents/screenshots_n_recordings"
mkdir -p "$SHOTDIR"
nohup screencapture -U -J video >/dev/null 2>&1 &
