/// A game alone at the reader's text size, on a phone held upright:
/// where width runs out first (fits.dart).
@Tags(['slow'])
library;

import 'package:flutter_test/flutter_test.dart';

import 'fits.dart';

void main() => soloMatrix(isPhoneUpright);
