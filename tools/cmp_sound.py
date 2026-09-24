#!/usr/bin/env python3
"""The sound board against MAME, same command stream (sim/run_sound.sh).

    cmp_sound.py mame.wav rtl_dir [seconds]

1. aligns rtl_mix.wav with MAME's recording (cross-correlation, +-20 ms);
2. per second: AC RMS of each and their ratio, and the waveform correlation
   (the 6809's program is deterministic given the same commands at the same
   times, so the two should be phase-locked where FM or samples play);
3. solves MAME = a*ym + b*oki + c*dac + d by least squares over the whole
   capture, from the RTL's separate chip outputs, each at its own MAME full
   scale.  MAME's routes are ym 0.10, dac 0.10, oki 0.15; the rtl_oki.wav
   stream is written at 1/4 (four voices fit), so b should come out 0.60.
   Coefficients far from those mean a chip's level is wrong -- a measurement,
   not a fit to apply (METHODOLOGY 5.12).
"""
import sys, struct, math

def rd(path):
    d = open(path, 'rb').read(); i = 12; ch = 1
    while i < len(d):
        cid = d[i:i + 4]; n = struct.unpack('<I', d[i + 4:i + 8])[0]
        if cid == b'fmt ': ch = struct.unpack('<H', d[i + 10:i + 12])[0]
        if cid == b'data':
            s = struct.unpack(f'<{n // 2}h', d[i + 8:i + 8 + n // 2 * 2])
            return list(s[::ch])
        i += 8 + n + (n & 1)

def main():
    m = rd(sys.argv[1]); r = sys.argv[2].rstrip('/')
    mix, ym, oki, dac = (rd(f'{r}/rtl_{k}.wav') for k in ('mix', 'ym', 'oki', 'dac'))
    secs = int(sys.argv[3]) if len(sys.argv) > 3 else min(len(m), len(mix)) // 48000
    n = min(len(m), len(mix), secs * 48000)
    # 1. alignment on the loudest second
    best = max(range(1, n // 48000 - 1), key=lambda s: sum(abs(v) for v in m[s * 48000:(s + 1) * 48000]))
    a0 = best * 48000; W = 48000
    def corr(x, y):
        mx = sum(x) / len(x); my = sum(y) / len(y)
        sx = math.sqrt(sum((v - mx) ** 2 for v in x)); sy = math.sqrt(sum((v - my) ** 2 for v in y))
        return sum((p - mx) * (q - my) for p, q in zip(x, y)) / (sx * sy) if sx and sy else 0.0
    lags = [(corr(m[a0:a0 + W], mix[a0 + L:a0 + L + W]), L) for L in range(-960, 961, 8)]
    c, lag = max(lags)
    lags = [(corr(m[a0:a0 + W], mix[a0 + L:a0 + L + W]), L) for L in range(lag - 8, lag + 9)]
    c, lag = max(lags)
    print(f'alignment: RTL lags MAME by {lag} samples ({lag / 48:.2f} ms), correlation {c:+.3f} at second {best}')
    sh = lambda x: x[max(0, lag):] if lag >= 0 else [0] * (-lag) + x
    mix, ym, oki, dac = sh(mix), sh(ym), sh(oki), sh(dac)
    # 2. per second
    print(' sec   MAME rms   RTL rms   ratio   corr')
    for s in range(n // 48000):
        x = m[s * 48000:(s + 1) * 48000]; y = mix[s * 48000:(s + 1) * 48000]
        if len(y) < 48000: break
        mx = sum(x) / 48000; my = sum(y) / 48000
        rx = math.sqrt(sum((v - mx) ** 2 for v in x) / 48000); ry = math.sqrt(sum((v - my) ** 2 for v in y) / 48000)
        if rx > 20 or ry > 20:
            print(f'{s:4d}  {rx:9.0f} {ry:9.0f}   {ry / rx if rx > 20 else float("nan"):5.2f}  {corr(x, y):+.3f}')
    # 3. least squares, decimated x4 for speed; a chip that never moves (its
    # column constant) is reported and left out
    L = min(n, len(ym))
    cols = {'ym': ym, 'oki/4': oki, 'dac': dac}
    names = []
    for nm, col in cols.items():
        v = col[:L:4]; mu = sum(v) / len(v)
        var = sum((q - mu) ** 2 for q in v) / len(v)
        print(f'  {nm:6s} rms {math.sqrt(var):8.1f}' + ('   (constant: left out)' if var < 1 else ''))
        if var >= 1: names.append(nm)
    rows = [[cols[nm][i] for nm in names] + [1.0, m[i]] for i in range(0, L, 4)]
    k = len(names) + 1
    A = [[0.0] * k for _ in range(k)]; bb = [0.0] * k
    for row in rows:
        v = row[:k]; t = row[k]
        for p in range(k):
            bb[p] += v[p] * t
            for q in range(k): A[p][q] += v[p] * v[q]
    for i in range(k):
        piv = max(range(i, k), key=lambda j: abs(A[j][i])); A[i], A[piv] = A[piv], A[i]; bb[i], bb[piv] = bb[piv], bb[i]
        for j in range(i + 1, k):
            f = A[j][i] / A[i][i]
            for q in range(i, k): A[j][q] -= f * A[i][q]
            bb[j] -= f * bb[i]
    x = [0.0] * k
    for i in reversed(range(k)):
        x[i] = (bb[i] - sum(A[i][q] * x[q] for q in range(i + 1, k))) / A[i][i]
    print('MAME ~ ' + ' + '.join(f'{x[i]:.3f} {names[i]}' for i in range(len(names))) + f' + {x[-1]:.0f}'
          + '   (MAME routes: ym 0.100, oki/4 0.600, dac 0.100)')


if __name__ == '__main__':
    main()
