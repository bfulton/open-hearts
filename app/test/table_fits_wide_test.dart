/// A game alone at the reader's text size, on everything wider than a
/// phone held upright: the phone on its side, where height runs out
/// first, a tablet and a desktop with their rail (fits.dart).
@Tags(['slow'])
library;

import 'package:flutter_test/flutter_test.dart';

import 'fits.dart';

void main() => soloMatrix((size) => !isPhoneUpright(size));
