#!/bin/sh
# shield-off.sh — instantly disable the busy-pane shield. ⌘W returns to 100%
# normal (closes panes immediately) with NO restart. The daemon stays running
# but passes every ⌘W straight through. Re-enable with shield-on.sh.
flag="$HOME/.config/machine-spirit/shield-disabled"
mkdir -p "$(dirname "$flag")"
: > "$flag"
echo "busy-pane shield: OFF  (⌘W is now stock behavior; run shield-on.sh to re-arm)"
