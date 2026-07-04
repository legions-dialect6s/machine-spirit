#!/bin/bash
# Stop any active screencapture recording (finalizes the .mov cleanly)
killall -INT screencapture 2>/dev/null && echo "recording stopped" || echo "no recording running"
