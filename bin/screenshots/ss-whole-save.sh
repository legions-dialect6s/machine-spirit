#!/bin/bash
# Whole-screen screenshot -> file in SHOTDIR
SHOTDIR="$HOME/Documents/screenshots_n_recordings"
mkdir -p "$SHOTDIR"
screencapture "$SHOTDIR/shot-$(date +%Y%m%d-%H%M%S).png"
