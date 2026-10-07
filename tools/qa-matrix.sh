#!/usr/bin/env bash
#
# qa-matrix.sh - run the QA scenarios from tools/qa.sh against every provider
# listed in AGENTS.md and print a pass/fail summary per scenario.
#
#   tools/qa-matrix.sh [-o root] [-C cwd] [-d max-seconds] [-p provider]...
#
# Each provider needs a scratch XDG_CONFIG_HOME at <root>/configs/<provider>
# holding mini-coding-agent/config.json, and each scenario gets <root>/runs/
# <provider>/<scenario>. Only the providers named with -p are run; with none,
# all four from AGENTS.md are.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=/tmp/mini-qa
cwd=$PWD
maxd=90
providers=()

usage() {
    cat <<'EOF'
usage: qa-matrix.sh [options]
  -o root     where configs and runs live (default /tmp/mini-qa)
  -C cwd      working directory mini runs in (default $PWD)
  -d seconds  capture cap per scenario (default 90)
  -p name     provider to run (repeatable); default all of AGENTS.md
EOF
}

while getopts 'o:C:d:p:h' opt; do
    case $opt in
        o) root=$OPTARG ;;
        C) cwd=$OPTARG ;;
        d) maxd=$OPTARG ;;
        p) providers+=("$OPTARG") ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
if (( ${#providers[@]} == 0 )); then
    providers=(completions responses anthropic google)
fi
root=$(readlink -f -- "$root")
cwd=$(cd -- "$cwd" && pwd)

run() {
    local provider=$1 scenario=$2 duration=$3 spec=$4
    local out=$root/runs/$provider/$scenario
    rm -rf -- "$out"
    mkdir -p -- "$out"
    echo "== $provider / $scenario =="
    "$here/qa.sh" -C "$cwd" -o "$out" -e "$root/configs/$provider" \
        -n "qa-$provider-$scenario" -d "$duration" -s "$spec" > "$out/run.log" 2>&1 || true
    tail -n 3 "$out/run.log" | sed 's/^/   /'
}

# A flag is "the app died" when the pane reports MINI-EXIT with a nonzero code,
# or the app never reached an idle prompt after the scenario's final step.
check() {
    local provider=$1 scenario=$2 expect=$3
    local out=$root/runs/$provider/$scenario
    local final=$out/final.txt
    local verdict="ok"
    if grep -q 'MINI-EXIT' "$final" && ! grep -q 'MINI-EXIT 0' "$final"; then
        verdict="CRASH"
    elif ! grep -q '\[complete' "$final"; then
        verdict="NO-TURN"
    elif ! grep -qiE "$expect" "$final"; then
        verdict="MISSING:$expect"
    fi
    printf '%-11s %-10s %s\n' "$provider" "$scenario" "$verdict"
}

dur() {
    local want=$1
    if (( want > maxd )); then echo "$maxd"; else echo "$want"; fi
}

for p in "${providers[@]}"; do
    run "$p" single "$(dur 40)" 'text=Read a.txt and tell me its contents in one short sentence;;key=enter;;wait=30;;shot=done'
    run "$p" multi "$(dur 55)" 'text=Read a.txt and b.txt, then tell me both contents;;key=enter;;wait=45;;shot=done'
    run "$p" cancel "$(dur 45)" 'text=Run this exact bash command: sleep 30; echo done;;key=enter;;wait=6;;shot=running;;key=ctrl+c;;wait=5;;shot=cancelled;;text=Say hi in one word;;key=enter;;wait=20;;shot=recovered'
    run "$p" pause "$(dur 55)" 'text=Run this exact bash command: sleep 12; echo HELLO. Then run: sleep 12; echo WORLD. Then say ALL DONE;;key=enter;;wait=4;;shot=running;;key=esc;;wait=13;;shot=paused;;text=Stop, just say STEERED;;key=enter;;wait=25;;shot=steered'
done

echo
echo "summary (expect = text that must appear in final.txt, else MISSING):"
for p in "${providers[@]}"; do
    check "$p" single 'hello world'
    check "$p" multi 'foo bar'
    check "$p" cancel 'cancelled'
    check "$p" pause 'STEERED'
done
