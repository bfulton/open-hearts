/// The rules of Hearts, and the bots that play them.
///
/// Pure Dart: no Flutter, no I/O, no clock. The app imports this to play;
/// the service imports it so a juror can run the bot policy. Nothing in
/// here knows which of those it is being used by.
library;

export 'src/arena.dart';
export 'src/bot.dart';
export 'src/card.dart';
export 'src/deal_seed.dart';
export 'src/game.dart';
export 'src/oblivious.dart';
export 'src/persona.dart';
export 'src/rules.dart';
export 'src/solo_record.dart';
