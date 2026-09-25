#!/bin/sh
# Regenerate the frozen-state set from MAME (deterministic: the same command
# gives byte-identical dumps).  The dumps are 1.5 MB each and are not
# committed; the events, MAME's pictures and the models' pictures are.
#
#   tools/capture_states.sh            gameplay set -> artifacts/states
#   tools/capture_states.sh service    service menu -> artifacts/states_service
#   GAME=nbajamte tools/capture_states.sh   -> artifacts/states_nbajamte
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
case "${1:-play}" in
  play)    out=artifacts/states; inputs=tools/inputs/play1.txt; secs=100
           frames=100,400,1000,1250,1400,1700,1900,2300,2500,3000,3500,4000,4600,5200 ;;
  service) out=artifacts/states_service; inputs=tools/inputs/service.txt; secs=20
           frames=700,1000 ;;
  *) echo "usage: $0 [play|service]" >&2; exit 2 ;;
esac
# another game (GAME=nbajamte) gets its own set: artifacts/states_nbajamte
[ "${GAME:-nbajam}" = nbajam ] || out=${out}_$GAME
rm -rf .mame/nvram/"${GAME:-nbajam}" "$out"
mkdir -p "$out"
FRAMES=$frames INPUTS=$inputs OUT=$out tools/mame.sh -seconds_to_run $secs \
    -autoboot_script tools/dump_state.lua
