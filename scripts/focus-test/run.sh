#!/bin/sh
# focus-test: travel five columns, type, change workspace, type, click a window, type, go back and travel back, type.
# Real hotkeys (hyper+h/l/u/i), keys and a click; checks where every key lands, how fast focus moves, and the recording
# for jolts and flicker. The first run opens test windows on two new workspaces after your last one; `--clean` closes them.
# Needs tegi running with the default binds, ffmpeg, and Screen Recording for the terminal.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
dir="$root/.build/focus-test"; tegi="$root/.build/release/tegi"
mkdir -p "$dir"
if [ "$1" = --clean ]; then [ -f "$dir/pids" ] && kill $(cat "$dir/pids") 2>/dev/null; rm -f "$dir/pids"; exit 0; fi
[ "$dir/keyapp" -nt "$here/keyapp.swift" ] || swiftc -O "$here/keyapp.swift" -o "$dir/keyapp"
[ "$dir/drive" -nt "$here/drive.swift" ] || swiftc -O "$here/drive.swift" -o "$dir/drive"
first() { "$tegi" msg state | python3 -c "
import json,sys
d=json.load(sys.stdin); m=d['monitors'][d['focused_monitor']]; ws=m['workspaces'][m['active_workspace']]
print(([t['title'] for c in ws['columns'] for t in c] + [''])[0], m['active_workspace'], len(m['workspaces']))"; }
act() { "$tegi" msg action "$@" >/dev/null; sleep 0.35; }
if [ "$(first | cut -d' ' -f1)" != A1 ]; then
    [ -f "$dir/pids" ] && kill $(cat "$dir/pids") 2>/dev/null; : > "$dir/pids"
    # The last workspace is always the empty one.
    set -- $(first); i=$2; while [ $((i + 1)) -lt $3 ]; do act focus-workspace-down; i=$((i + 1)); done
    export FOCUS_TEST_LOG="$dir/events.log"
    for app in "A 3" "B 3" - "C 2" "D 1"; do
        if [ "$app" = - ]; then act focus-workspace-down; continue; fi
        "$dir/keyapp" $app & echo $! >> "$dir/pids"; sleep 1.2
    done
    act focus-workspace-up
fi
act focus-workspace-down; act focus-column-last; act focus-workspace-up; act focus-column-first; sleep 0.2
: > "$dir/events.log"; rm -f "$dir/rec.mov"
screencapture -x -v -V 4 "$dir/rec.mov" & rec=$!; sleep 0.2
"$dir/drive" "$dir"; wait $rec
python3 "$here/analyze.py" "$dir"
