/// A probe for taps that do not land: where the browser says a finger
/// came down beside where the app saw it, and the sizes each of them
/// goes by. Switched on by tapping the build number in About five
/// times, off the same way, and shown over every screen until then.
///
/// Red ring: the browser's touch, from the page (web/touch_probe.js).
/// Blue dot: the app's own pointer-down. Apart, the two are measuring
/// the screen differently; a ring with no dot is a touch the app never
/// got. Nothing leaves the device.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'touch_probe_io.dart' if (dart.library.js_interop) 'touch_probe_web.dart' as platform;

final touchProbeOn = ValueNotifier<bool>(false);

class TouchProbe extends StatefulWidget {
  const TouchProbe({super.key, required this.child});

  final Widget child;

  @override
  State<TouchProbe> createState() => _TouchProbeState();
}

class _TouchProbeState extends State<TouchProbe> {
  Offset? _app;
  Map<String, dynamic>? _page;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    touchProbeOn.addListener(_switched);
    _switched();
  }

  @override
  void dispose() {
    touchProbeOn.removeListener(_switched);
    _poll?.cancel();
    super.dispose();
  }

  void _switched() {
    _poll?.cancel();
    _poll = null;
    if (touchProbeOn.value) {
      _read();
      // A touch the app never sees still shows: the page is asked
      // again on a clock, not only when the app is touched.
      _poll = Timer.periodic(const Duration(milliseconds: 400), (_) => _read());
    }
    if (mounted) setState(() {});
  }

  void _read() {
    final json = platform.pageTouches();
    final page = json == null ? null : jsonDecode(json) as Map<String, dynamic>;
    if (mounted) setState(() => _page = page);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (!touchProbeOn.value) return;
        setState(() => _app = e.position);
        _read();
      },
      child: Stack(
        textDirection: TextDirection.ltr,
        children: [
          widget.child,
          if (touchProbeOn.value)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _Marks(app: _app, page: _pageTouch()),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: _Numbers(lines: _lines(context)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The browser's last touch, in the app's coordinates: the page's
  /// client position less where the app's view starts.
  Offset? _pageTouch() {
    final last = _page?['last'] as Map<String, dynamic>?;
    final touch = (last?['touchstart'] ?? last?['pointerdown']) as Map<String, dynamic>?;
    if (touch == null) return null;
    final view = (_page?['view'] as List?)?.cast<num>();
    return Offset((touch['x'] as num).toDouble() - (view?[0] ?? 0), (touch['y'] as num).toDouble() - (view?[1] ?? 0));
  }

  List<String> _lines(BuildContext context) {
    final mq = MediaQuery.maybeOf(context);
    String r(Object? v) => v is num ? v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1) : v is List ? v.map(r).join(' ') : '$v';
    final page = _page;
    final last = (page?['last'] as Map<String, dynamic>?) ?? {};
    return [
      'app  size ${r(mq?.size.width)}x${r(mq?.size.height)}  pad ${_insets(mq?.padding)}  view ${_insets(mq?.viewPadding)}  dpr ${r(mq?.devicePixelRatio)}',
      'app  tap ${_app == null ? '-' : '${r(_app!.dx)},${r(_app!.dy)}'}',
      if (page == null) 'page -'
      else ...[
        'page inner ${r(page['inner'])}  client ${r(page['client'])}  visual ${r(page['visual'])}',
        'page screen ${r(page['screen'])} ${page['orientation']}  dpr ${r(page['dpr'])}  standalone ${page['standalone']}',
        'page view ${r(page['view'])}  scroll ${r(page['scroll'])}  safe ${r(page['safe'])}  settled ${page['settled']}',
        for (final kind in ['touchstart', 'pointerdown'])
          'page $kind ${last[kind] == null ? '-' : '${r(last[kind]['x'])},${r(last[kind]['y'])}'}',
      ],
    ];
  }

  static String _insets(EdgeInsets? e) => e == null ? '-' : '${e.top.round()}/${e.right.round()}/${e.bottom.round()}/${e.left.round()}';
}

class _Numbers extends StatelessWidget {
  const _Numbers({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(6),
        color: const Color(0xCC000000),
        child: Text(
          lines.join('\n'),
          textDirection: TextDirection.ltr,
          style: const TextStyle(fontSize: 10.5, height: 1.3, color: Color(0xFFFFFFFF), fontFamily: 'monospace', decoration: TextDecoration.none),
        ),
      );
}

class _Marks extends CustomPainter {
  _Marks({required this.app, required this.page});

  final Offset? app;
  final Offset? page;

  @override
  void paint(Canvas canvas, Size size) {
    if (page != null) {
      canvas.drawCircle(page!, 16, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFFFF3B30));
    }
    if (app != null) canvas.drawCircle(app!, 6, Paint()..color = const Color(0xFF0A84FF));
  }

  @override
  bool shouldRepaint(_Marks old) => old.app != app || old.page != page;
}
