#!/usr/bin/env bash
#
# qa.sh - drive the real TUI in a real kitty window through a timed script of
# keystrokes and prompts, screenshotting throughout. stress.sh types one prompt
# and watches; this fires submissions, cancellations and pauses at chosen times
# so turn control paths can be exercised on a repeatable run.
#
#   tools/qa.sh -C <cwd> -o <outdir> -e <xdg config home> -s <spec> [-s <spec>...]
#
# A spec is a sequence of steps separated by ``;;``:
#
#   wait=<seconds>   pause before the next step
#   text=<string>    type the string into the editor (may contain commas)
#   key=<name>       press a key: enter, shift+enter, ctrl+c, esc, tab, ctrl+d
#   shot=<label>     write the pane text to <outdir>/mark-<n>-<label>.txt
#
# The first step runs once the banner is up. Every action is logged to
# <outdir>/steps.txt with its wall time. Frames land in <outdir>/frame-NNNNN.png
# and the final pane in final.txt / final-screen.txt.

set -euo pipefail

fps=15
seconds=180
name="qa-$$"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bin=$here/../zig-out/bin/mini
cwd=$PWD
out=
xdg=
specs=()

usage() {
    cat <<'EOF'
usage: qa.sh [options]
  -d seconds  how long to capture at most (default 180)
  -r fps      capture rate (default 15)
  -o outdir   where frames go (required)
  -C cwd      working directory mini runs in (default $PWD)
  -e path     XDG_CONFIG_HOME holding mini-coding-agent/config.json
  -b path     mini binary (default ../zig-out/bin/mini)
  -n name     kitty session name (default qa-$$)
  -s spec     a step list (repeatable), see the header comment
EOF
}

while getopts 'd:r:o:C:e:b:n:s:h' opt; do
    case $opt in
        d) seconds=$OPTARG ;;
        r) fps=$OPTARG ;;
        o) out=$OPTARG ;;
        C) cwd=$OPTARG ;;
        e) xdg=$OPTARG ;;
        b) bin=$OPTARG ;;
        n) name=$OPTARG ;;
        s) specs+=("$OPTARG") ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done

if (( fps <= 0 || seconds <= 0 )); then
    echo "qa: fps and seconds must be positive" >&2
    exit 2
fi
if [[ -z $out || ${#specs[@]} -eq 0 ]]; then
    usage >&2
    exit 2
fi
if [[ ! -x $bin ]]; then
    echo "qa: no executable at $bin (run zig build first)" >&2
    exit 2
fi
bin=$(readlink -f -- "$bin")
cwd=$(cd -- "$cwd" && pwd)
mkdir -p -- "$out"
out=$(readlink -f -- "$out")
socket=/tmp/mini-$name.sock

now_ms() {
    local t=${EPOCHREALTIME/,/.}
    echo $(( ${t%.*} * 1000 + 10#${t#*.} / 1000 ))
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

printf -v launch 'cd %q; %q; printf "\nMINI-EXIT %%d\n" $?; exec sleep 86400' "$cwd" "$bin"

rm -f -- "$socket"
env_args=()
if [[ -n $xdg ]]; then
    env_args=(env "XDG_CONFIG_HOME=$xdg")
fi
kitty --detach --listen-on "unix:$socket" \
    -o allow_remote_control=yes -o remember_window_size=no \
    -o initial_window_width=110c -o initial_window_height=34c \
    --title "mini-$name" \
    "${env_args[@]}" bash --norc --noprofile -c "$launch"

for _ in $(seq 100); do
    wid=$(kt ls 2>/dev/null | grep -o '"id": [0-9]*' | tail -n1 | tr -dc '0-9' || true)
    [[ -n $wid ]] && break
    sleep 0.1
done
if [[ -z $wid ]]; then
    echo "qa: kitty never reported a window on $socket" >&2
    exit 1
fi

for _ in $(seq 300); do
    pane all | grep -q 'mini ·' && break
    sleep 0.1
done
if ! pane all | grep -q 'mini ·'; then
    echo "qa: mini did not start; pane says:" >&2
    pane all >&2
    exit 1
fi

log=$out/steps.txt
: > "$log"
echo "qa: $out"
shot=0

send_text() {
    kt send-text -m "id:$wid" "$1"
}

send_key() {
    case $1 in
        enter) kt send-key -m "id:$wid" enter ;;
        shift+enter) kt send-key -m "id:$wid" shift+enter ;;
        ctrl+c) kt send-key -m "id:$wid" ctrl+c ;;
        esc) kt send-key -m "id:$wid" escape ;;
        tab) kt send-key -m "id:$wid" tab ;;
        ctrl+d) kt send-key -m "id:$wid" ctrl+d ;;
        *) echo "qa: unknown key $1" >&2; exit 2 ;;
    esac
}

# Expand every -s spec into a flat list of "at_ms<TAB>verb<TAB>arg" lines.
steps=()
t=0
for spec in "${specs[@]}"; do
    spec=${spec//;;/$'\n'}
    while IFS= read -r part; do
        part=${part#"${part%%[![:space:]]*}"}
        [[ -z $part ]] && continue
        verb=${part%%=*}
        arg=${part#*=}
        if [[ $verb == wait ]]; then
            t=$(awk "BEGIN { printf \"%d\", $t + $arg * 1000 }")
            continue
        fi
        steps+=("$t	$verb	$arg")
    done < <(printf '%s\n' "$spec")
done

exec_steps() {
    local now=$1
    while (( ${#steps[@]} > 0 )); do
        local line=${steps[0]}
        local at=${line%%	*}
        if (( at > now - start )); then break; fi
        steps=("${steps[@]:1}")
        local rest=${line#*	}
        local verb=${rest%%	*}
        local arg=${rest#*	}
        case $verb in
            text) send_text "$arg"; printf '%s text %s\n' "$(( now - start ))" "$arg" >> "$log" ;;
            key) send_key "$arg"; printf '%s key %s\n' "$(( now - start ))" "$arg" >> "$log" ;;
            shot)
                shot=$(( shot + 1 ))
                pane all > "$out/mark-$(printf '%02d' "$shot")-$arg.txt" || true
                printf '%s shot %s\n' "$(( now - start ))" "$arg" >> "$log"
                ;;
            *) echo "qa: unknown step $verb" >&2; exit 2 ;;
        esac
    done
}

end_reason=
start=$(now_ms)
next=$start
frames=0
while :; do
    now=$(now_ms)
    (( now - start >= seconds * 1000 )) && break
    exec_steps $now

    if ! kt screenshot -m "id:$wid" "$out/frame-$(printf '%05d' "$frames").png" >/dev/null 2>&1; then
        end_reason="window vanished after $frames frames"
        break
    fi
    frames=$(( frames + 1 ))

    if pane screen | grep -q 'MINI-EXIT'; then
        end_reason=$(pane screen | grep -o 'MINI-EXIT -\?[0-9]*' | tail -n1)
        break
    fi

    next=$(( next + 1000 / fps ))
    sleep "$(awk "BEGIN { printf \"%.3f\", 1 / $fps }")"
done

exec_steps 999999999
elapsed=$(( $(now_ms) - start ))
pane all > "$out/final.txt" || true
pane screen > "$out/final-screen.txt" || true

echo "qa: $frames frames in $(( elapsed / 1000 ))s"
if [[ -n $end_reason ]]; then
    echo "qa: ended early: $end_reason"
fi
