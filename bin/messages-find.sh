#!/bin/zsh
# Activate Messages and verify AX focus on conversation search, including narrow
# Catalyst windows. Native AX avoids System Events' stale post-menu UI cache.
# Never types, presses Return, or touches the compose field. 0=focused, 11=miss.
emulate -L zsh
script_dir=${0:A:h}
"$script_dir/ms" messages-find >/dev/null 2>&1 || exit 11
exit 0
