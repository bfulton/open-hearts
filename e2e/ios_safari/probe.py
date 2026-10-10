"""Real taps in Mobile Safari on an iOS simulator, through idb, against
the deployed app: what each kind of touch leaves on the screen.

A browser's emulation of a phone goes nowhere near UIKit, which is
where Safari's own selection, callouts and highlights live; idb's taps
go through the simulator's touch input, as a finger's do. For each
gesture: a screenshot, the screen's brightness against the one before
it, and any native menu the accessibility tree shows (Copy, Select
All, Look Up), which only Safari draws.

    python3 e2e/ios_safari/probe.py <udid> <out dir> <url> [<where Play solo is>.json]

With ?e2e the app builds its accessibility tree, and Play solo is found
there and written down; without it (as in production) there is none,
and the place written down by an ?e2e run is used.
"""

import json
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image, ImageStat

UDID, OUT, URL = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
KNOWN = Path(sys.argv[4]) if len(sys.argv) > 4 else None
OUT.mkdir(parents=True, exist_ok=True)
NATIVE = ('Copy', 'Select All', 'Select', 'Look Up', 'Share', 'Translate', 'Search Web', 'Speak')


def idb(*args, capture=False):
    run = subprocess.run(['idb', *args, '--udid', UDID], capture_output=True, text=True, timeout=60)
    if run.returncode != 0:
        print(f'idb {" ".join(args)}: {run.stderr.strip()}', flush=True)
    return run.stdout if capture else None


def elements():
    raw = idb('ui', 'describe-all', '--json', capture=True) or '[]'
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        # Older idb prints one element per line.
        return [json.loads(line) for line in raw.splitlines() if line.strip().startswith('{')]


def label(e):
    return (e.get('AXLabel') or e.get('title') or '').strip()


def find(pattern):
    for e in elements():
        if pattern(label(e)):
            f = e['frame']
            return f['x'] + f['width'] / 2, f['y'] + f['height'] / 2
    return None


def shot(name):
    path = OUT / f'{name}.png'
    subprocess.run(['xcrun', 'simctl', 'io', UDID, 'screenshot', str(path)], capture_output=True, check=True)
    image = Image.open(path).convert('L')
    return ImageStat.Stat(image).mean[0]


def native_menu():
    return sorted({label(e) for e in elements() if label(e) in NATIVE})


def tap(x, y, duration=None):
    args = ['ui', 'tap', str(round(x)), str(round(y))]
    if duration:
        args += ['--duration', str(duration)]
    idb(*args)


def taps(x, y, n, gap=0.12):
    # Started side by side, so the gap between them is the sleep, not
    # idb's start-up time.
    procs = []
    for i in range(n):
        procs.append(subprocess.Popen(['idb', 'ui', 'tap', str(round(x)), str(round(y)), '--udid', UDID]))
        time.sleep(gap)
    for p in procs:
        p.wait()


def open_page(url, ready, timeout=90):
    subprocess.run(['xcrun', 'simctl', 'openurl', UDID, url], check=True)
    began = time.time()
    while time.time() - began < timeout:
        at = find(ready)
        if at:
            return at
        time.sleep(2)
    return None


def main():
    report = []
    e2e = '?e2e=1' in URL
    if e2e:
        solo = open_page(URL, lambda t: t == 'Play solo')
        if solo and KNOWN:
            KNOWN.write_text(json.dumps(solo))
    else:
        subprocess.run(['xcrun', 'simctl', 'openurl', UDID, URL], check=True)
        time.sleep(30)
        solo = tuple(json.loads(KNOWN.read_text())) if KNOWN and KNOWN.exists() else None
    if not solo:
        shot('00-no-app')
        print('the app did not come up; labels seen:', sorted({label(e) for e in elements()})[:60], flush=True)
        sys.exit(1)
    base = shot('00-home')
    print(f'home: brightness {base:.1f}', flush=True)
    tap(*solo)
    time.sleep(6)
    base = shot('01-table')
    labels = sorted({label(e) for e in elements() if label(e)})
    print('table labels:', labels[:80], flush=True)
    (OUT / 'table-elements.json').write_text(json.dumps(elements(), indent=1))

    # Where things are: from the accessibility tree where the app builds
    # it (?e2e), else the fractions of the screen they took there.
    size = Image.open(OUT / '01-table.png').size
    scale = 3 if size[0] > 1000 else 2
    w, h = size[0] / scale, size[1] / scale
    spots = {
        'felt': (w * 0.5, h * 0.48),
        'card': (w * 0.5, h * 0.9),
        'name': (w * 0.5, h * 0.27),
        'header': (w * 0.5, h * 0.11),
        'side': (w * 0.12, h * 0.45),
    }
    gestures = [
        ('tap', lambda x, y: tap(x, y)),
        ('double-tap', lambda x, y: taps(x, y, 2)),
        ('triple-tap', lambda x, y: taps(x, y, 3)),
        ('long-press', lambda x, y: tap(x, y, 1.2)),
        ('quick-taps', lambda x, y: taps(x, y, 4, gap=0.06)),
    ]
    last = base
    step = 2
    for spot, (x, y) in spots.items():
        for name, gesture in gestures:
            gesture(x, y)
            time.sleep(1.2)
            tag = f'{step:02d}-{spot}-{name}'
            now = shot(tag)
            menu = native_menu()
            line = f'{tag}: brightness {now:.1f} (table {base:.1f}, before {last:.1f}){"  NATIVE MENU " + ",".join(menu) if menu else ""}'
            print(line, flush=True)
            report.append({'step': tag, 'brightness': now, 'base': base, 'menu': menu})
            # Washed: does a tap somewhere else clear it?
            if now - base > 12:
                tap(w * 0.5, h * 0.62)
                time.sleep(1.2)
                after = shot(f'{tag}-then-tap')
                print(f'   then a tap on the felt: brightness {after:.1f}', flush=True)
                report[-1]['afterTap'] = after
            last = now
            step += 1
    (OUT / 'report.json').write_text(json.dumps({'url': URL, 'e2e': e2e, 'steps': report}, indent=1))


main()
