#!/usr/bin/env bash
#
# stress.sh - drive the real TUI in a real kitty window with a real prompt
# while capturing the screen at a fixed rate, so rendering bugs and rare
# crashes show up on a run that can be repeated. Frames land in
# <outdir>/frame-NNNNN.png, the final pane text in <outdir>/final.txt.
#
#   tools/stress.sh [-d seconds] [-r fps] [-o outdir] [-C cwd]
#                   [-b mza] [-n name] [-p prompt]

set -euo pipefail

fps=15
seconds=300
name="stress-$$"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bin=$here/../zig-out/bin/mza
cwd=$PWD
out=
prompt="Research this repo then create /tmp/my-review.html"

usage() {
    cat <<'EOF'
usage: stress.sh [options]
  -d seconds  how long to capture (default 300)
  -r fps      capture rate (default 15)
  -o outdir   where frames go (default /tmp/mz-stress-<stamp>)
  -C cwd      working directory mza runs in (default $PWD)
  -b path     mza binary (default ../zig-out/bin/mza)
  -n name     kitty session name (default stress-$$)
  -p prompt   what to type (default: review this repo into /tmp/my-review.html)
EOF
}

while getopts 'd:r:o:C:b:n:p:h' opt; do
    case $opt in
        d) seconds=$OPTARG ;;
        r) fps=$OPTARG ;;
        o) out=$OPTARG ;;
        C) cwd=$OPTARG ;;
        b) bin=$OPTARG ;;
        n) name=$OPTARG ;;
        p) prompt=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done

if (( fps <= 0 || seconds <= 0 )); then
    echo "stress: fps and seconds must be positive" >&2
    exit 2
fi
if [[ ! -x $bin ]]; then
    echo "stress: no executable at $bin (run zig build first)" >&2
    exit 2
fi
bin=$(readlink -f -- "$bin")
cwd=$(cd -- "$cwd" && pwd)
out=${out:-/tmp/mz-stress-$(date +%Y%m%d-%H%M%S)}
mkdir -p -- "$out"
out=$(readlink -f -- "$out")
socket=/tmp/mz-$name.sock

now_us() {
    local t=${EPOCHREALTIME/,/.}
    echo $(( ${t%.*} * 1000000 + 10#${t#*.} ))
}

kt() { kitty @ --to "unix:$socket" "$@"; }
pane() { kt get-text -m "id:$wid" --extent="$1" --ansi 2>/dev/null; }

wid=
cleanup() {
    if [[ -n $wid ]]; then
        kt close-window -m "id:$wid" >/dev/null 2>&1 || true
    fi
    rm -f -- "$socket"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# The shell stays alive after mza exits so the window holds the crash for
# inspection, and so the exit status can be read back off the pane.
printf -v launch 'cd %q; %q; printf "\nMZA-EXIT %%d\n" $?; exec sleep 86400' "$cwd" "$bin"

rm -f -- "$socket"
kitty --detach --listen-on "unix:$socket" \
    -o allow_remote_control=yes -o remember_window_size=no \
    -o initial_window_width=100c -o initial_window_height=30c \
    --title "mz-$name" \
    bash --norc --noprofile -c "$launch"

for _ in $(seq 100); do
    wid=$(kt ls 2>/dev/null | grep -o '"id": [0-9]*' | tail -n1 | tr -dc '0-9' || true)
    [[ -n $wid ]] && break
    sleep 0.1
done
if [[ -z $wid ]]; then
    echo "stress: kitty never reported a window on $socket" >&2
    exit 1
fi

# The banner lands in scrollback, not the live region, so wait on all of it.
for _ in $(seq 300); do
    pane all | grep -q 'mini-z-agent' && break
    sleep 0.1
done
if ! pane all | grep -q 'mini-z-agent'; then
    echo "stress: mza did not start; pane says:" >&2
    pane all >&2
    exit 1
fi

echo "stress: $out"
echo "stress: prompt: $prompt"
kt send-text -m "id:$wid" "$prompt"
kt send-key -m "id:$wid" enter

end_reason=
interval=$(( 1000000 / fps ))
start=$(now_us)
next=$start
checked=$start
frames=0
while :; do
    now=$(now_us)
    (( now - start >= seconds * 1000000 )) && break
    if ! kt screenshot -m "id:$wid" "$out/frame-$(printf '%05d' "$frames").png" >/dev/null 2>&1; then
        end_reason="window vanished after $frames frames"
        break
    fi
    frames=$(( frames + 1 ))
    now=$(now_us)
    if (( now - checked >= 1000000 )); then
        checked=$now
        if pane screen | grep -q 'MZA-EXIT'; then
            end_reason=$(pane screen | grep -o 'MZA-EXIT -\?[0-9]*' | tail -n1)
            break
        fi
    fi
    next=$(( next + interval ))
    if (( next > now )); then
        wait_us=$(( next - now ))
        sleep "$(( wait_us / 1000000 )).$(printf '%06d' $(( wait_us % 1000000 )))"
    fi
done

elapsed=$(( $(now_us) - start ))
pane all > "$out/final.txt" || true
pane screen > "$out/final-screen.txt" || true

echo "stress: $frames frames in $(( elapsed / 1000000 ))s (target ${fps}fps, got $(awk "BEGIN { printf \"%.1f\", $frames * 1000000 / $elapsed }")fps)"
if [[ -n $end_reason ]]; then
    echo "stress: ended early: $end_reason"
    [[ $end_reason == 'MZA-EXIT 0' ]] || exit 1
fi
