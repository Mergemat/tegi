# Reads focus-test's logs and recording: where each key landed and how fast, focus changes, jolts, tears and flicker.
import colorsys, re, subprocess, sys
d = sys.argv[1]
ev = sorted((float(t), k, r) for t, k, r in (l.split(' ', 2) for l in open(f'{d}/events.log').read().split('\n') if l.strip()))
t0 = next(t for t, k, r in ev if k == 'mark' and r == 'start')
ms = lambda t: (t - t0) * 1000
fails = []

# Typing: every key lands in the window focus moved to.
expect = {'right': 'B3', 'workspace-down': 'C1|C2|D1', 'click': 'C2', 'workspace-up': 'B3', 'left': 'A1'}
keys = [(t, r.split()[0], r.split()[1] if len(r.split()) > 1 else '') for t, k, r in ev if k == 'key']
action, at, delivery = None, 0, []
for t, k, r in ev:
    if k == 'mark' and (r.startswith('hot ') or r.startswith('click')):
        action, at = (r.split()[1] if r.startswith('hot') else 'click'), t
    if k == 'mark' and r.startswith('type '):
        ch = r[5:]
        got = next(((kt, w) for kt, w, c in keys if c == ch and t - 0.001 <= kt < t + 1), None)
        if not got:
            fails.append(f"'{ch}' typed after {action} never arrived"); continue
        delivery.append(got[0] - t)
        ok = re.fullmatch(expect[action], got[1])
        line = f"'{ch}' typed {ms(t) - ms(at):4.0f} ms after {action:14s} → {got[1]} after {(got[0] - t) * 1000:3.0f} ms"
        print(('  ' if ok else '✗ ') + line)
        if not ok: fails.append(line)
for t, k, r in ev:
    if k == 'mark' and (r.startswith('hot') or r.startswith('click')):
        nxt = next(((t2, r2) for t2, k2, r2 in ev if k2 == 'keywin' and t2 > t), None)
        if nxt: print(f"  {r:22s} → {nxt[1]:3s} focused in {(nxt[0] - t) * 1000:4.0f} ms")

# Jolts, from the window server's frames: a window that stops mid-slide and then jumps to catch up.
# During a workspace slide tegi shows pictures over the screen, so the windows beneath move unseen.
slides = [t for t, k, r in ev if k == 'mark' and 'workspace' in r]
hidden = lambda t: any(0 <= t - s < 0.45 for s in slides)
tracks = {}
for l in open(f'{d}/frames.log').read().split('\n'):
    if not l.strip(): continue
    p = l.split()
    for a in p[1:]:
        tracks.setdefault(a.split(':')[0], []).append((float(p[0]), tuple(map(int, a.split(':')[1].split(',')))))
jolts = []
for w, tr in tracks.items():
    pts = [(t, f) for t, f in tr if f[1] < 1000]
    for (ta, a), (tb, b), (tc, c) in zip(pts, pts[1:], pts[2:]):
        if hidden(tc): continue
        if tb - ta < 0.02 and b[0] != a[0] and 0.026 < tc - tb < 0.4 and abs(c[0] - b[0]) > 12:
            jolts.append(f"a window stopped {(tc - tb) * 1000:.0f} ms mid-slide, then jumped {c[0] - b[0]} pt at {ms(tc):.0f} ms")
        if not hidden(tb) and tc - ta < 0.1 and (b[0] - a[0]) * (c[0] - b[0]) < 0 and min(abs(b[0] - a[0]), abs(c[0] - b[0])) > 2:
            jolts.append(f"a window went back {a[0]}→{b[0]}→{c[0]} at {ms(tb):.0f} ms")
for j in jolts: print('✗ ' + j)
fails += jolts

# The recording: one scanline through the bright test windows in every frame, and single-frame flashes.
rec = f'{d}/rec.mov'; W = 1728
times = [float(x.strip(',')) for x in subprocess.run(["ffprobe", "-v", "error", "-show_entries", "frame=pts_time", "-select_streams", "v",
                                                      "-of", "csv=p=0", rec], capture_output=True, text=True).stdout.split() if x.strip(',')]
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", rec, "-fps_mode", "passthrough", "-vf", f"scale={W}:-1,crop={W}:1:0:ih*0.7",
                      "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
torn = []
for t, i in zip(times, range(0, len(raw) - W * 3 + 1, W * 3)):
    row = raw[i:i + W * 3]
    on = [s > 0.5 and v > 0.7 for _, s, v in (colorsys.rgb_to_hsv(row[x * 3] / 255, row[x * 3 + 1] / 255, row[x * 3 + 2] / 255) for x in range(W))]
    runs, x = [], 0
    while x < W:
        if on[x]:
            s0 = x
            while x < W and on[x]: x += 1
            if x - s0 > 40: runs.append((s0, x))
        x += 1
    gaps = [b[0] - a[1] for a, b in zip(runs, runs[1:]) if b[0] - a[1] > 3]
    if gaps and max(abs(g - 16) for g in gaps) > 12: torn.append(max(abs(g - 16) for g in gaps))
fl = subprocess.run(["ffmpeg", "-v", "error", "-i", rec, "-vf", "fps=60,scale=240:155,format=gray", "-f", "rawvideo", "-"], capture_output=True).stdout
n = 240 * 155; fr = [fl[i:i + n] for i in range(0, len(fl) - n + 1, n)]
diff = lambda a, b: sum(abs(x - y) for x, y in zip(a[::7], b[::7])) / (n / 7)
flashes = sum(1 for i in range(1, len(fr) - 1)
              if (a := diff(fr[i - 1], fr[i])) > 6 and (b := diff(fr[i], fr[i + 1])) > 6 and diff(fr[i - 1], fr[i + 1]) < min(a, b) * 0.35)
if flashes: fails.append(f"{flashes} single-frame flashes")

print(f"\ntyping: {len(delivery)} keys, worst {max(delivery) * 1000:.0f} ms to land" if delivery else "no keys")
print(f"motion: {len(jolts)} jolts; {len(torn)} frames where neighbouring windows drift apart, worst {max(torn or [0])} pt")
print(f"flicker: {flashes} flashes")
print("PASS" if not fails else "FAIL")
sys.exit(0 if not fails else 1)
