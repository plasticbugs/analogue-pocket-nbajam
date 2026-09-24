#!/usr/bin/env python3
"""Histogram of TMS34010 mnemonics and operand forms in tools/insn_trace.lua's
windows:  insn_hist.py dir"""
import sys, glob, re, collections
mn, forms, total = collections.Counter(), collections.Counter(), 0
for f in sorted(glob.glob(sys.argv[1] + '/tr_*.txt')):
    for line in open(f, errors='replace'):
        m = re.match(r'\s*[0-9A-F]{8}:\s+(\S+)\s*(.*)', line)
        if not m:
            continue
        op, args = m.group(1), m.group(2)
        total += 1
        mn[op] += 1
        shape = re.sub(r'[AB]\d+|SP', 'R', args)
        shape = re.sub(r'[0-9A-F]+h', 'n', shape)
        forms[op + ' ' + shape.strip()] += 1
print(f'{total} instructions, {len(mn)} mnemonics, {len(forms)} forms')
for k, v in mn.most_common():
    print(f'{v:10d}  {k}')
print('\nforms:')
for k, v in forms.most_common():
    print(f'{v:10d}  {k}')
