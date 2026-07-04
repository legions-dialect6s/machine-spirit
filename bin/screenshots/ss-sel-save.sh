#!/bin/bash
# Interactive selection/window screenshot -> file in SHOTDIR
SHOTDIR="$HOME/Documents/screenshots_n_recordings"
mkdir -p "$SHOTDIR"
screencapture -i "$SHOTDIR/shot-$(date +%Y%m%d-%H%M%S).png"
