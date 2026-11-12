#!/bin/sh
set -eu
stage="$1"
output="$2"
opening="${3:-click}"
if [ "$opening" = claude-sign-in ] && [ "${GITHUB_ACTIONS:-}" != true ]; then
    echo "claude-sign-in runs only on GitHub's runner: it signs in through Sandbar's own folders and takes the clipboard" >&2
    exit 64
fi
root="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$stage" = - ]; then set --; else set -- --show "$root/Tests/Stages/$stage.json"; fi
folder="$(mktemp -d)"
cp -R "$root/build/Sandbar.app" "$folder"
"$folder/Sandbar.app/Contents/MacOS/Sandbar" "$@" &
program=$!
trap 'kill "$program" 2>/dev/null || true; wait "$program" 2>/dev/null || true; rm -rf "$folder"' EXIT

item() {  # the status item has a menu bar of its own, beside Sandbar's hidden main menu of three
    osascript -e 'with timeout of 10 seconds' \
        -e "tell application \"System Events\" to tell (first process whose unix id is $program)" \
        -e 'set itemBar to missing value' \
        -e 'repeat with bar in menu bars' -e 'if (count of menu bar items of bar) is 1 then set itemBar to contents of bar' \
        -e 'end repeat' -e 'if itemBar is missing value then error "no menu bar of Sandbar holds its item alone"' \
        -e 'tell menu bar item 1 of itemBar' \
        -e 'if item 1 of (get position) < 0 then error "not placed in the menu bar yet: a click now opens the panel off screen"' \
        -e "$1" -e 'end tell' -e 'end tell' -e 'end timeout' >/dev/null
}
press() {
    osascript -e "tell application \"System Events\" to keystroke \"$1\" using {$2}"
}
key() {
    osascript -e 'tell application "System Events"' -e "repeat $2 times" -e "key code $1" -e 'delay 0.05' \
        -e 'end repeat' -e 'end tell'
}
capture() {
    sleep 1
    mkdir -p "$(dirname "$1")"
    screencapture -x "$1"
}
runs() {  # an ended program stays in the process list until it is waited for
    case "$(ps -o stat= -p "$program")" in '' | Z*) return 1 ;; esac
}
frontWindow() {
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $program)" \
        -e 'if (count of windows) is 0 then return "none"' -e 'return name of window 1' -e 'end tell'
}
expectWindow() {
    shown="$(frontWindow)"
    if [ "$shown" != "$1" ]; then
        echo "Sandbar's front window is $shown, not $1" >&2
        exit 1
    fi
}
element() {
    osascript - "$program" "$1" "$2" <<'END'
on run arguments
    set {program, wanted, action} to arguments
    with timeout of 20 seconds
        tell application "System Events" to tell (first process whose unix id is (program as integer))
            set everything to entire contents of window 1  # a list walked in place is asked for again at each turn
            repeat with n from 1 to count of everything
                set candidate to item n of everything
                set labels to {}
                try
                    set end of labels to name of candidate
                end try
                try
                    set end of labels to description of candidate
                end try
                try
                    set end of labels to value of candidate
                end try
                try
                    set end of labels to role of candidate
                end try
                if labels contains wanted then
                    if action is "click" then click candidate
                    if action is "value" then return value of candidate
                    if action is "middle" then
                        set {x, y} to position of candidate
                        set {width, height} to size of candidate
                        return ((x + width div 2) as text) & " " & ((y + height div 2) as text)
                    end if
                    return
                end if
            end repeat
        end tell
    end timeout
    error "no " & wanted & " in Sandbar's window"
end run
END
}
clickAt() {  # with the mouse, as a person does: System Events' click is a press that no mouse made
    osascript -l JavaScript - "$1" "$2" <<'END'
ObjC.import("CoreGraphics")
function run(place) {
    const point = { x: Number(place[0]), y: Number(place[1]) }
    for (const kind of [$.kCGEventMouseMoved, $.kCGEventLeftMouseDown, $.kCGEventLeftMouseUp]) {
        $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateMouseEvent($(), kind, point, $.kCGMouseButtonLeft))
        delay(0.12)
    }
}
END
}
waitFor() {
    deadline=$(($(date +%s) + $2))
    until element "$1" find 2>/dev/null; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "Sandbar never showed $1" >&2
            exit 1
        fi
        if [ "$(frontWindow)" = none ]; then item click || true; fi  # a browser page that opens closes the panel
        sleep 1
    done
}

action=click
if [ "$opening" = shortcut ]; then action='get position'; fi
deadline=$(($(date +%s) + 30))
until item "$action"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "System Events could not click Sandbar's menu bar item" >&2
        exit 1
    fi
    sleep 1
done

case "$opening" in
    settings | close) sleep 1 && press , "command down" ;;
    shortcut) press p "option down, command down" ;;
    gear)
        sleep 1
        osascript - "$program" <<'END' >/dev/null
on run arguments
    with timeout of 10 seconds
        tell application "System Events" to tell (first process whose unix id is ((item 1 of arguments) as integer))
            set everything to entire contents of window 1
            repeat with n from 1 to count of everything
                set candidate to item n of everything
                if role of candidate is "AXMenuButton" then
                    perform action "AXShowMenu" of candidate
                    return
                end if
            end repeat
        end tell
    end timeout
    error "no gear in Sandbar's window"
end run
END
        ;;
    claude-sign-in)
        waitFor "Sign in" 20
        element "Sign in" click  # Claude's row comes first
        waitFor "Finish in your browser" 120
        waitFor AXTextField 20
        printf WDJB-MJHT | pbcopy
        clickAt $(element AXTextField middle)
        press v "command down"
        ;;
    keys)  # on the many stage: the sixth row down is the first stack's fold row, and Return opens that stack
        sleep 1
        key 125 6
        key 36 1
        key 125 1
        ;;
esac
capture "$output"
if [ "$opening" = settings ]; then
    for pane in "Menu Bar" Accounts Notifications; do
        osascript -e "tell application \"System Events\" to tell (first process whose unix id is $program)" \
            -e "click button \"$pane\" of toolbar 1 of window 1" -e 'end tell' >/dev/null
        capture "${output%.png}-$(echo "$pane" | tr -d ' ' | tr '[:upper:]' '[:lower:]').png"
    done
fi
if [ "$opening" = keys ]; then
    key 125 60
    capture "${output%.png}-last-row.png"
fi
if [ "$opening" = close ]; then
    expectWindow General
    press w "command down"
    capture "${output%.png}-closed.png"
    expectWindow none
    item click
    sleep 1
    press , "command down"
    sleep 1
    expectWindow General
    press q "command down"
    deadline=$(($(date +%s) + 10))
    while runs; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "Sandbar still runs 10 seconds after ⌘Q with Settings in front" >&2
            exit 1
        fi
        sleep 1
    done
    wait "$program" || {
        echo "Sandbar ended with status $? after ⌘Q" >&2
        exit 1
    }
    exit 0
fi
if [ "$opening" = claude-sign-in ]; then
    pasted="$(element AXTextField value)"
    if [ "$pasted" != WDJB-MJHT ]; then
        echo "⌘V left \"$pasted\" in the code field" >&2
        exit 1
    fi
    element Cancel click
    waitFor "Not signed in" 20
    capture "$(dirname "$output")/app-claude-cancelled.png"
    if pgrep -x claude >/dev/null; then
        echo "a claude process is still running after Cancel" >&2
        exit 1
    fi
    profiles="$HOME/Library/Application Support/Sandbar/Profiles"
    if [ -n "$(ls -A "$profiles" 2>/dev/null)" ]; then
        echo "a profile folder is left after Cancel: $(ls -A "$profiles")" >&2
        exit 1
    fi
fi
if ! runs; then
    echo "Sandbar ended before its screenshot was taken" >&2
    exit 1
fi
