#!/bin/sh
# Lint every module in rtl/ on its own, so a warning has one obvious owner.
# Run before every push: it costs seconds and catches what a two-minute
# Quartus map would, without waiting for Quartus.
#
# The vendored cores are waived by rule and path. The waiver file is built
# here rather than committed, because Verilator rejects the whole file if it
# names a rule that version does not know -- which is how a waiver written
# against the newest Verilator broke the lint on CI's older one. Each rule is
# probed first and only the ones that exist go in.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }

. "$here/waivers.sh"
WAIVE="$WAIVERS"

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
echo 'module lintprobe; endmodule' > "$PROBE/lintprobe.v"

OPTS="-Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-TIMESCALEMOD"
for w in UNUSEDPARAM PINCONNECTEMPTY; do
    verilator --lint-only "-Wno-$w" "$PROBE/lintprobe.v" >/dev/null 2>&1 \
        && OPTS="$OPTS -Wno-$w"
done

# vendored modules, if there are any yet
MODS=$(ls "$root"/modules/*/*.v "$root"/modules/*/*.sv "$root"/modules/*/hdl/*.v 2>/dev/null || true)

fail=0
for f in "$root"/rtl/*.sv; do
    m=$(basename "$f" .sv)
    printf '%-20s ' "$m"
    out=$(verilator --lint-only $OPTS "$WAIVE" --top-module "$m" \
          "$root"/rtl/*.sv $MODS 2>&1 \
          | grep -E '^%(Error|Warning)' | grep -v 'Exiting due to' \
          | grep -v '/modules/' || true)
    if [ -z "$out" ]; then echo ok
    else echo; echo "$out" | sed 's/^/    /'; fail=1
    fi
done

printf '%-20s ' "pocket memories"
out=$(verilator --lint-only $OPTS "$WAIVE" --top-module nbajam_mem \
      "$root"/target/pocket/nbajam_mem.sv "$root"/target/pocket/sdram_ctrl.sv \
      "$root"/target/pocket/sram_port.sv 2>&1 \
      | grep -E '^%(Error|Warning)' | grep -v 'Exiting due to' \
      | grep -v 'sdram_ctrl.sv' || true)
if [ -z "$out" ]; then echo ok
else echo; echo "$out" | sed 's/^/    /'; fail=1
fi

printf '%-20s ' "sram self-test"
out=$(verilator --lint-only $OPTS "$WAIVE" --top-module sram_selftest \
      "$root"/target/pocket/sram_selftest.sv 2>&1 \
      | grep -E '^%(Error|Warning)' | grep -v 'Exiting due to' || true)
if [ -z "$out" ]; then echo ok
else echo; echo "$out" | sed 's/^/    /'; fail=1
fi

# The one clock relationship no bench can see: the core makes a dot every
# DOT_DIV system clocks and the Pocket samples them with the PLL's video clock.
printf '%-20s ' "video clock"
out=$(python3 - "$root" <<'PY'
import re, sys
root = sys.argv[1]
pll = open(root + '/target/pocket/core_pll/core_pll/core_pll_0002.v').read()
f = [float(x) for x in re.findall(r'output_clock_frequency[012]\("([0-9.]+) MHz"\)', pll)]
div = int(re.search(r'localparam int DOT_DIV = (\d+);', open(root + '/rtl/clk_enables.sv').read()).group(1))
ph = [int(x) for x in re.findall(r'phase_shift[12]\("(\d+) ps"\)', pll)]
bad = []
for i in (1, 2):
    if abs(f[0] / f[i] - div) > 1e-3:
        bad.append(f'PLL outclk_{i} is {f[i]} MHz but the core makes a dot every {div} clocks of {f[0]} MHz ({f[0]/div:.6f} MHz)')
want90 = ph[0] + round(1e6 / f[1] / 4)
if abs(ph[1] - want90) > 2:
    bad.append(f'PLL outclk_2 is shifted {ph[1]} ps; 90 degrees after outclk_1 is {want90} ps')
print('\n'.join(bad))
PY
)
if [ -z "$out" ]; then echo ok
else echo; echo "$out" | sed 's/^/    /'; fail=1
fi

[ $fail = 0 ] || exit 1
echo "lint clean"
