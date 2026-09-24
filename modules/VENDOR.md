# Vendored modules

Third-party HDL cores copied into the tree — no submodules, so the build is
self-contained and reproducible. Each keeps its own LICENSE alongside.
`tools/vendor.sh <name>` fetches one from its upstream at a pinned commit,
with its licence; run it with no arguments to see what it knows about, or give
it a url and ref for anything else. `tools/gen_qip.sh` then lists everything
under `modules/` for Quartus.

| module | what it is | upstream | commit | licence |
|---|---|---|---|---|
| *(none yet)* | | | | |

For each module record what it is, its upstream repository and the exact
commit, its licence, and anything it needs that is not obvious — jt12's
`hdl/` has to be taken whole, for instance, because `jt12_top` instantiates
its ADPCM files outside a generate guard, so they must exist even when ADPCM
is disabled.

Written here rather than vendored: list the custom chips reimplemented from
MAME's device models, and where their behaviour is documented.

To update one: re-copy from upstream at the new commit and record it here.
