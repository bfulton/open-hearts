"""Real taps in Mobile Safari on an iOS simulator, through idb, against
the deployed app: what each kind of touch leaves on the screen.

A browser's emulation of a phone goes nowhere near UIKit, which is
where Safari's own selection, callouts and highlights live; idb's taps
go through the simulator's touch input, as a finger's do. For each
gesture: a screenshot, the screen's brightness against the one before
it, and any native menu the accessibility tree shows (Copy, Select
All, Look Up), which only Safari draws.

    python3 e2e/ios_safari/probe.py <udid> <out dir> <url> [home]

With `home`, the page is first added to the Home Screen through
Safari's own Share menu and opened from its icon, as a web app: no
Safari around it, as an iPhone's owner plays it.

idb's accessibility tree is Safari's own controls, not the page's, so
the page is found in its screenshots: Play solo is the gold button, the
hand is the light card faces at the bottom.
"""

import json
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image, ImageStat

UDID, OUT, URL = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
HOME = len(sys.argv) > 4 and sys.argv[4] == 'home'
DISMISS = ('Close', 'dismiss popup', 'Continue', 'Not Now', 'OK')
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


def dismiss():
    """Safari's own first-run notes, over the page."""
    for _ in range(4):
        at = find(lambda t: t in DISMISS)
        if not at:
            return
        tap(*at)
        time.sleep(1)


def region(path, keep, below=0.0, filled=0.4):
    """The bounding box, in points, of the rows at least [filled] of
    whose width is pixels [keep] says are part of it, at or under
    [below] of the screen's height: a filled shape, not an outline or a
    small badge of the same colour. None if there is none."""
    image = Image.open(path).convert('RGB')
    scale = 3 if image.size[0] > 1000 else 2
    small = image.resize((image.size[0] // scale, image.size[1] // scale))
    px = small.load()
    # The tallest run of such rows one under another: a line of the
    # same colour elsewhere (an outline's edge) is a run of one.
    runs, run = [], []
    for y in range(int(small.size[1] * below), small.size[1]):
        row = [x for x in range(small.size[0]) if keep(px[x, y])]
        if len(row) >= small.size[0] * filled:
            run.append((y, row[0], row[-1]))
        elif run:
            runs.append(run)
            run = []
    if run:
        runs.append(run)
    best = max(runs, key=len, default=[])
    if len(best) < 4:
        return None
    return min(r[1] for r in best), best[0][0], max(r[2] for r in best), best[-1][0]


gold = lambda p: p[0] > 200 and 150 < p[1] < 200 and p[2] < 130
face = lambda p: p[0] > 235 and p[1] > 232 and p[2] > 220


def labels():
    return sorted({label(e) for e in elements() if label(e)})


def press(*names, wait=2.0, required=True):
    """Taps the Safari or Home Screen control named the first of
    [names] that is on the screen: in that order, not the screen's."""
    at = next((a for a in (find(lambda t, n=n: t == n) for n in names) if a), None)
    if not at:
        print(f'no {names}; on the screen: {labels()}', flush=True)
        if required:
            raise SystemExit(1)
        return False
    tap(*at)
    time.sleep(wait)
    return True


def read(name, phrase, lowest=False, rightmost=False):
    """Where [phrase] is written on the screen, in points, read by OCR:
    the share sheet is drawn by another process, which idb's tree does
    not reach. The lowest of several when [lowest], the rightmost when
    [rightmost]."""
    path = OUT / f'{name}.png'
    shot(name)
    image = Image.open(path)
    scale = 3 if image.size[0] > 1000 else 2
    # Grey, and read as scattered words: the sheet's small labels over
    # its translucent ground are lost otherwise.
    grey = OUT / f'{name}-grey.png'
    image.convert('L').save(grey)
    tsv = subprocess.run(['tesseract', str(grey), '-', '--psm', '11', 'tsv'], capture_output=True, text=True).stdout
    words = []
    for line in tsv.splitlines()[1:]:
        cols = line.split('\t')
        if len(cols) == 12 and cols[11].strip():
            left, top, width, height = map(int, cols[6:10])
            words.append((cols[11].strip(), left, top, width, height))
    # A phrase is its words in reading order, side by side on one line.
    words.sort(key=lambda w: (round(w[2] / 20), w[1]))
    want = phrase.split()
    found = []
    for i in range(len(words) - len(want) + 1):
        run = words[i:i + len(want)]
        if [w[0] for w in run] != want:
            continue
        if any(abs(b[2] - a[2]) > a[4] or b[1] < a[1] for a, b in zip(run, run[1:])):
            continue
        x0, y0 = run[0][1], min(w[2] for w in run)
        x1, y1 = run[-1][1] + run[-1][3], max(w[2] + w[4] for w in run)
        found.append(((x0 + x1) / 2 / scale, (y0 + y1) / 2 / scale))
    if not found:
        print(f'no "{phrase}" read on the screen; read: {" ".join(w[0] for w in words)[:400]}', flush=True)
        return None
    if rightmost:
        return max(found, key=lambda f: f[0])
    return max(found, key=lambda f: f[1]) if lowest else found[0]


def blue_button(name, above=0.25):
    """The middle, in points, of the system blue in the top [above] of
    the screen: the sheet's Add, white on blue, which OCR reads as
    nothing."""
    path = OUT / f'{name}.png'
    shot(name)
    image = Image.open(path).convert('RGB')
    scale = 3 if image.size[0] > 1000 else 2
    small = image.resize((image.size[0] // scale, image.size[1] // scale))
    px = small.load()
    hits = [(x, y) for y in range(int(small.size[1] * above)) for x in range(small.size[0])
            if px[x, y][2] > 200 and px[x, y][0] < 90 and 90 < px[x, y][1] < 170]
    if len(hits) < 40:
        print(f'no blue button on the screen', flush=True)
        return None
    return sum(h[0] for h in hits) / len(hits), sum(h[1] for h in hits) / len(hits)


def add_to_home_screen():
    """Safari's Share menu, Add to Home Screen, Add; then the icon."""
    subprocess.run(['xcrun', 'simctl', 'openurl', UDID, URL], check=True)
    time.sleep(12)
    dismiss()
    shot('h0-in-safari')
    print('safari:', labels(), flush=True)
    if not press('Share', wait=2, required=False):
        # The … button: Share is in it (Safari says so on first run).
        press('More', 'View Bookmarks, Share Menu, and Open Tabs')
        shot('h1-menu')
        print('menu:', labels(), flush=True)
        press('Share')
    shot('h2-share')
    print('share sheet:', labels(), flush=True)
    at = read('h2-share', 'Add to Home Screen')
    if not at:
        # Behind the More at the end of the sheet's row of actions.
        more = read('h2-share', 'More', lowest=True)
        if not more:
            raise SystemExit(1)
        tap(*more)
        time.sleep(2)
        at = read('h2b-actions', 'Add to Home Screen')
        if not at:
            raise SystemExit(1)
    tap(*at)
    time.sleep(3)
    # The blue button at the top right, not the Add in the sheet's title.
    add = blue_button('h3-add')
    if not add:
        raise SystemExit(1)
    tap(*add)
    time.sleep(3)
    # Safari stays in front: home, to the icon.
    idb('ui', 'button', 'HOME')
    time.sleep(3)
    for page in range(4):
        shot(f'h4-home-screen-{page}')
        print('home screen:', labels(), flush=True)
        if press('Open Hearts', wait=12, required=False):
            return
        idb('ui', 'swipe', '350', '450', '50', '450', '--duration', '0.3')
        time.sleep(1.5)
    raise SystemExit(1)


def open_app(timeout=90):
    if HOME:
        add_to_home_screen()
    else:
        subprocess.run(['xcrun', 'simctl', 'openurl', UDID, URL], check=True)
    began = time.time()
    while time.time() - began < timeout:
        time.sleep(3)
        dismiss()
        shot('00-loading')
        box = region(OUT / '00-loading.png', gold)
        if box:
            return (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    return None


def main():
    report = []
    e2e = '?e2e=1' in URL
    solo = open_app()
    if not solo:
        shot('00-no-app')
        print('the app did not come up; labels seen:', sorted({label(e) for e in elements()})[:60], flush=True)
        sys.exit(1)
    base = shot('00-home')
    print(f'home: brightness {base:.1f}', flush=True)
    tap(*solo)
    time.sleep(6)
    dismiss()
    base = shot('01-table')
    labels = sorted({label(e) for e in elements() if label(e)})
    print('table labels:', labels[:80], flush=True)
    (OUT / 'table-elements.json').write_text(json.dumps(elements(), indent=1))

    # Where things are: the hand is the card faces in the bottom third;
    # the rest is laid out around the middle of the felt above it.
    size = Image.open(OUT / '01-table.png').size
    scale = 3 if size[0] > 1000 else 2
    w, h = size[0] / scale, size[1] / scale
    hand = region(OUT / '01-table.png', face, below=0.6)
    if not hand:
        print('no hand on the screen: not at the table', flush=True)
        sys.exit(1)
    print(f'hand at {hand} on a {w:.0f}x{h:.0f} screen', flush=True)
    felt_y = hand[1] * 0.55
    spots = {
        'felt': (w * 0.5, felt_y),
        'card': ((hand[0] + hand[2]) / 2, (hand[1] + hand[3]) / 2),
        'name': (w * 0.5, felt_y * 0.55),
        'header': (w * 0.5, felt_y * 0.2),
        'side': (w * 0.12, felt_y),
    }
    def swipe(x, y, dx, dy, duration=0.3):
        idb('ui', 'swipe', str(round(x)), str(round(y)), str(round(x + dx)), str(round(y + dy)), '--duration', str(duration))

    gestures = [
        ('swipe-across', lambda x, y: swipe(x - 120, y, 240, 0)),
        ('swipe-down', lambda x, y: swipe(x, y - 60, 0, 160)),
        ('drag-up', lambda x, y: swipe(x, y, 0, -200, 0.8)),
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
