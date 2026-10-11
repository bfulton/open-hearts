/// A live table at the reader's text size, on the protocol's clock:
/// who is here, a seat's clock and the Boot, the Auto switch, and the
/// hand's sheet, a hand of it (fits.dart; to the game's end in
/// table_fits_live_end_test.dart).
@Tags(['slow'])
library;

import 'package:flutter_test/flutter_test.dart';

import 'fits.dart';

void main() => liveMatrix(toTheEnd: false);
