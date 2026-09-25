#!/usr/bin/env python3
"""Check the core's JSON against what the Pocket's firmware will accept.

    tools/check_json.py [pkg/pocket]

The APF parses these files itself and says almost nothing when it cannot:
the first flash of this core stopped at `Load error in "interact" - General
Error`, which was a duplicate variable id (two entries had used id 20) and
two names longer than the field allows.  Nothing in the build caught it,
because everything in the build only ever read the files with a JSON parser,
which is not what the firmware does.

So this checks the things the firmware cares about and a parser does not:

  * every file is valid JSON and carries the magic the firmware looks for;
  * interact variable ids are unique -- the fault above;
  * a list's `defaultval` is an INDEX into its options, not the value to
    write -- which is what the second flash died on, with indices of 256,
    16384 and 2097152 into lists of sixteen.  Every core that loads uses
    0 to 3 there, and in each one it selects the option whose value is
    zero;
  * names fit, and a list's options each have a name and a value;
  * data slot ids are unique and required slots name a filename;
  * video.json's scaler modes declare the size the core actually emits,
    given as --active WxH (the boot bench prints it).  This one is
    not a firmware rule, it is the fault it catches: the template shipped
    320x224 from an arcade board while this core emits 640x256, and on
    hardware that came out as a picture squished horizontally, the bottom
    32 lines -- where the on-screen keyboard is drawn -- cut off, and the
    whole image flickering;
  * the files are no larger than the largest this firmware is known to
    accept, because size is the one limit that cannot be read off the file.

It exits non-zero and prints every fault, not just the first.
"""
import glob
import json
import os
import re
import sys

# These are not from a document.  They are what a firmware that accepts a
# file is observed to accept, surveyed across the seventeen cores installed
# on the author's own Pocket (tools/survey_interact.py):
#
#     variables      up to 14      option values   up to 0x00C00000
#     bytes          up to 7,597   options a list  up to 16
#     longest name   26            defaultval      0..3
#     options in the whole file    up to 52
#
# The 23 characters an earlier version of this file called a limit was a
# guess, and wrong: OpenJazz ships a 26-character name and loads.
NAME_MAX = 26
OPTS_MAX = 16
SIZE_MAX = 7600
TOTAL_OPTS_MAX = 52    # atarisy2's, the most of any core that loads here

MAGIC = {
    'core.json': 'APF_VER_1', 'data.json': 'APF_VER_1',
    'input.json': 'APF_VER_1', 'interact.json': 'APF_VER_1',
    'variants.json': 'APF_VER_1', 'audio.json': 'APF_VER_1',
    'video.json': 'APF_VER_1',
}


def main(argv):
    active = None
    args = []
    i = 1
    while i < len(argv):
        if argv[i] == '--active' and i + 1 < len(argv):
            i += 1
            try:
                w_, h_ = argv[i].lower().split('x')
                active = (int(w_), int(h_))
            except ValueError:
                print(f'--active wants WxH, got {argv[i]!r}')
                return 2
        else:
            args.append(argv[i])
        i += 1
    root = args[0] if args else 'pkg/pocket'
    bad = []
    def fault(where, msg):
        bad.append(f'{where}: {msg}')

    files = []
    for dirpath, _dirs, names in os.walk(root):
        for n in sorted(names):
            if n.endswith('.json'):
                files.append(os.path.join(dirpath, n))
    if not files:
        print(f'no JSON under {root}')
        return 2

    for path in files:
        base = os.path.basename(path)
        size = os.path.getsize(path)
        try:
            d = json.load(open(path))
        except Exception as e:
            fault(path, f'not valid JSON: {e}')
            continue
        if size > SIZE_MAX:
            fault(path, f'{size} bytes, over the {SIZE_MAX} this firmware is '
                        f'known to accept')
        top = next(iter(d)) if len(d) == 1 else None
        if base in MAGIC:
            magic = d.get(top, {}).get('magic') if top else None
            if magic != MAGIC[base]:
                fault(path, f'magic is {magic!r}, expected {MAGIC[base]!r}')

        if base == 'interact.json':
            v = d['interact'].get('variables', [])
            total = sum(len(x.get('options', [])) for x in v)
            if total > TOTAL_OPTS_MAX:
                fault(path, f'{total} options in the whole file, more than the '
                            f'{TOTAL_OPTS_MAX} of any core that loads here')
            for x in v:
                for val in ([o.get('value') for o in x.get('options', [])]
                            + [x.get('value')]):
                    try:
                        n = int(str(val), 16)
                    except (TypeError, ValueError):
                        continue
                    if n & 0x80000000:
                        fault(path, f'{x.get("name")!r} has the value {val}, '
                                    f'with bit 31 set; no core that loads here '
                                    f'has one above 0x00C00000')
            seen = {}
            for x in v:
                i, name = x.get('id'), x.get('name', '')
                if i in seen:
                    fault(path, f'id {i} used by both {seen[i]!r} and {name!r}')
                seen[i] = name
                if len(name) > NAME_MAX:
                    fault(path, f'name {name!r} is {len(name)} characters, '
                                f'over {NAME_MAX}')
                if x.get('type') == 'list':
                    o = x.get('options', [])
                    if not o:
                        fault(path, f'{name!r} is a list with no options')
                    dv = x.get('defaultval')
                    if not isinstance(dv, int) or not 0 <= dv < max(len(o), 1):
                        fault(path, f'{name!r} defaultval is {dv!r}; it must be '
                                    f'an index into its {len(o)} options')
                    if len(o) > OPTS_MAX:
                        fault(path, f'{name!r} has {len(o)} options, over {OPTS_MAX}')
                    for k in o:
                        if 'name' not in k or 'value' not in k:
                            fault(path, f'{name!r} has an option missing '
                                        f'name or value: {k}')
                        elif len(k['name']) > NAME_MAX:
                            fault(path, f'{name!r} option {k["name"]!r} is '
                                        f'{len(k["name"])} characters')
                if x.get('type') != 'action' and 'address' not in x:
                    fault(path, f'{name!r} has no address')

        if base == 'video.json':
            # The active size has to come from outside this file: the
            # constant that sets it is named differently in every core, and a
            # check that guesses at the name is a check that silently stops
            # working.  Pass --active WxH -- the number the boot bench prints
            # as "N active pixels" is the one to use.
            if active is None:
                fault(path, 'no --active WxH given, so the declared scaler '
                            'size was NOT checked against what the core emits. '
                            'Pass the size the bench measures.')
            else:
                for i, m in enumerate(d['video'].get('scaler_modes', [])):
                    if (m.get('width'), m.get('height')) != active:
                        fault(path, f'scaler_modes[{i}] says '
                                    f'{m.get("width")}x{m.get("height")}, but the '
                                    f'core emits {active[0]}x{active[1]}')

        if base == 'data.json':
            slots = d['data'].get('data_slots', [])
            seen = {}
            for s in slots:
                i = s.get('id')
                if i in seen:
                    fault(path, f'slot id {i} used twice')
                seen[i] = s.get('name')
                # With a game list (Pleiads' layout) the slot that takes the
                # instance JSON has no filename, and the instances name the
                # others' files: every instance must then name this slot's.
                if s.get('required') and not s.get('filename'):
                    if 'json' in s.get('extensions', []):
                        continue
                    core_dir = os.path.basename(os.path.dirname(path))
                    insts = glob.glob(os.path.join(root, 'Assets', '*', core_dir, '*.json'))
                    named = [any(ds.get('id') == i and ds.get('filename')
                                 for ds in json.load(open(f))['instance'].get('data_slots', []))
                             for f in insts]
                    if not insts or not all(named):
                        fault(path, f'slot {i} is required but names no filename'
                                    + (' (and not every instance JSON names one)' if insts else ''))

    for f in bad:
        print('  ' + f)
    print()
    if bad:
        print(f'{len(bad)} fault(s) the Pocket would refuse')
        return 1
    print(f'{len(files)} JSON files, nothing the Pocket is known to refuse')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
