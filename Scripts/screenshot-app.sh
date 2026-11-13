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
case "$opening" in  # System Events cannot read the label of a SwiftUI button
    claude-sign-in | spoken | keys) swiftc -O "$root/Scripts/accessibility.swift" -o "$folder/accessibility" ;;
esac

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
    "$folder/accessibility" "$program" "$@"
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
    until element has "$1" 2>/dev/null; do
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
        element press "Sign in"  # Claude's row comes first
        waitFor "Finish in your browser" 120
        sleep 5  # the browser's page comes forward now, which closes the panel
        waitFor AXTextField 20
        printf WDJB-MJHT | pbcopy
        field="$(element frame AXTextField)"
        set -- $field
        clickAt $(($1 + $3 / 2)) $(($2 + $4 / 2))
        press v "command down"
        ;;
    spoken) sleep 1 ;;
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
    if ! element list | grep -q "number 41309, 8 days | selected"; then
        echo "the arrow keys and Return did not select the row that appeared at the top of the opened stack" >&2
        exit 1
    fi
    key 125 60
    capture "${output%.png}-last-row.png"
    row="$(element frame "Draft, Try a smaller image cache for product pages, number 104, 1 month")"
    list="$(element frame AXScrollArea)"
    set -- $row $list
    if [ "$2" -lt "$6" ] || [ $(($2 + $4)) -gt $(($6 + $8)) ]; then
        echo "the selected last row did not scroll into view: it spans $2 to $(($2 + $4)), the list $6 to $(($6 + $8))" >&2
        exit 1
    fi
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
if [ "$opening" = spoken ]; then
    element list >"${output%.png}.txt"
    for sentence in "Work, Month, 3120 dollars, 52 percent, 19 days 9 hours left" \
        "Review requested by mchen, Stop the importer from retrying uploads that already failed twice, checks passed, number 6821, 2 days" \
        "Approved, Read saved carts through one cart reader, checks passed, number 41250, 3 days" Refresh Menu; do
        element has "$sentence" || unread=yes
    done
    if [ -n "${unread:-}" ]; then exit 1; fi
fi
if [ "$opening" = claude-sign-in ]; then
    pasted="$(element value AXTextField)"
    if [ "$pasted" != WDJB-MJHT ]; then
        echo "⌘V left \"$pasted\" in the code field" >&2
        exit 1
    fi
    element press Cancel
    deadline=$(($(date +%s) + 20))
    until [ "$(element list | grep -c "Not signed in")" = 2 ]; do  # Codex's row says so all along
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "Cancel did not bring Claude's row back to Not signed in" >&2
            exit 1
        fi
        if [ "$(frontWindow)" = none ]; then item click || true; fi
        sleep 1
    done
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
