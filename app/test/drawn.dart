/// Finding what the table draws, past the copies it only lays out.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_hearts/ui/table_view.dart' show BadgeGhost;

/// What [finder] matches that is drawn: not the copies of a badge that
/// its partner is sized by, which are laid out and never shown.
Finder drawn(Finder finder) => _Drawn(finder);

class _Drawn extends ChainedFinder {
  _Drawn(super.parent);

  @override
  String get description => '${parent.describeMatch(Plurality.many)}, drawn';

  @override
  Iterable<Element> filter(Iterable<Element> parentCandidates) => parentCandidates.where((e) {
        var ghost = false;
        e.visitAncestorElements((a) {
          ghost = a.widget is BadgeGhost;
          return !ghost;
        });
        return !ghost;
      });
}
