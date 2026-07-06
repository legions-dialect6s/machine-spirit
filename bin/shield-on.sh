#!/bin/sh
# shield-on.sh — re-enable the busy-pane shield after shield-off.sh.
flag="$HOME/.config/machine-spirit/shield-disabled"
rm -f "$flag"
echo "busy-pane shield: ON  (busy panes now escalate on ⌘W)"
