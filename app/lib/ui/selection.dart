/// Any words on any screen can be selected and copied: a name, a rule,
/// an error to send us.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

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
