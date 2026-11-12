#!/bin/sh
set -eu
output="$1"

folder="$(mktemp -d)"
cp -R "$(dirname "$0")/../build/Sandbar.app" "$folder"
"$folder/Sandbar.app/Contents/MacOS/Sandbar" &
program=$!
trap 'kill "$program" 2>/dev/null || true; wait "$program" 2>/dev/null || true; rm -rf "$folder"' EXIT

click() {
    osascript -e 'with timeout of 10 seconds' \
        -e "tell application \"System Events\" to click menu bar item 1 of menu bar $1 of (first process whose unix id is $program)" \
        -e 'end timeout' >/dev/null
}
deadline=$(($(date +%s) + 30))
until click 1 || click 2; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "System Events could not click Sandbar's menu bar item" >&2
        exit 1
    fi
    sleep 1
done

sleep 1
mkdir -p "$(dirname "$output")"
screencapture -x "$output"
if ! kill -0 "$program" 2>/dev/null; then
    echo "Sandbar ended before its screenshot was taken" >&2
    exit 1
fi
