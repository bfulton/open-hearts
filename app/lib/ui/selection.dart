/// Any words on any screen can be selected and copied: a name, a rule,
/// an error to send us.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show Selectable, SelectionRegistrar;

import '../net/copy.dart';

class CopyableSelection extends StatefulWidget {
  const CopyableSelection({super.key, required this.child});

  final Widget child;

  @override
  State<CopyableSelection> createState() => _CopyableSelectionState();
}

class _CopyableSelectionState extends State<CopyableSelection> {
  String _selected = '';

  /// Where the toolbar and the handles are drawn. This sits above the
  /// app's navigator, whose overlay is below it, so it brings its own:
  /// without one, a long press selected the words and then had nowhere
  /// to show Copy.
  late final _entry = OverlayEntry(builder: (context) => _area());

  /// The area's own focus, out of the Tab order: it is there to select
  /// text, not to be tabbed to. And in the order, it is asked where it
  /// is when the browser says the window has focus — which can be before
  /// the first frame is laid out, so it threw, every load.
  final _focus = FocusNode(debugLabel: 'selection', skipTraversal: true);

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(CopyableSelection old) {
    super.didUpdateWidget(old);
    _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);

  Widget _area() {
    return SelectionArea(
      focusNode: _focus,
      onSelectionChanged: (content) => _selected = content?.plainText ?? '',
      // On the web, Copy goes through the page (net/copy.dart), which is
      // the only way Safari lets it reach the clipboard. Elsewhere the
      // framework's own toolbar does.
      contextMenuBuilder: (context, region) {
        final items = [
          for (final item in region.contextMenuButtonItems)
            if (kIsWeb && item.type == ContextMenuButtonType.copy)
              item.copyWith(onPressed: () {
                copyText(_selected);
                region.hideToolbar(false);
              })
            else
              item,
        ];
        return AdaptiveTextSelectionToolbar.buttonItems(anchors: region.contextMenuAnchors, buttonItems: items);
      },
      child: widget.child,
    );
  }
}

/// Every page's way into [CopyableSelection]: its text is selectable
/// while its route is the one on top, and out of the selection while
/// another covers it.
///
/// The selection sits above the navigator, so a page under another is
/// still in it — and a page covered before it was ever laid out (a
/// reload landing on a page over the front door, a game rejoined as the
/// app starts) has text nobody has measured. The selection orders its
/// text by where each piece is on the screen, every time any of it
/// changes, and asking an unmeasured piece where it is throws: once a
/// second while the front door under a table ticked its online count.
///
/// Wraps the theme's own transitions (theme.dart), which every page
/// route builds through; the same widget either way, so a page covered
/// and uncovered keeps its state.
class SelectionWhileCurrent extends PageTransitionsBuilder {
  const SelectionWhileCurrent(this.inner);

  final PageTransitionsBuilder inner;

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      inner.buildTransitions(route, context, animation, secondaryAnimation, _WhileCurrent(child: child));
}

class _WhileCurrent extends StatelessWidget {
  const _WhileCurrent({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final outer = SelectionContainer.maybeOf(context);
    if (outer == null) return child;
    final current = ModalRoute.isCurrentOf(context) ?? true;
    return SelectionRegistrarScope(registrar: current ? outer : const _Nobody(), child: child);
  }
}

/// A registrar that takes nothing: a covered page's text, out of the
/// selection.
class _Nobody implements SelectionRegistrar {
  const _Nobody();

  @override
  void add(Selectable selectable) {}

  @override
  void remove(Selectable selectable) {}
}
