/// A tiny reader for the packages' command-line tools (engine's and
/// table's tool/): `--name value` or `--name=value`, with a default,
/// and `--name` alone for a switch. The tools are run by hand —
/// `dart run tool/arena.dart --games 3000` — so their knobs are
/// arguments, not build-time defines. Not part of the engine's library
/// (engine.dart); imported by name where a tool needs it.
library;

String? _argOf(List<String> args, String name) {
  final flag = '--$name';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == flag && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('$flag=')) return args[i].substring(flag.length + 1);
  }
  return null;
}

int intArg(List<String> args, String name, int fallback) => int.tryParse(_argOf(args, name) ?? '') ?? fallback;

double doubleArg(List<String> args, String name, double fallback) => double.tryParse(_argOf(args, name) ?? '') ?? fallback;

String strArg(List<String> args, String name, String fallback) => _argOf(args, name) ?? fallback;

/// `--name value`, or null when it is not given.
String? optionalArg(List<String> args, String name) => _argOf(args, name);

/// `--name 1,2,3` as numbers; [fallback] when it is not given.
List<int> intsArg(List<String> args, String name, List<int> fallback) {
  final v = _argOf(args, name);
  return v == null ? fallback : [for (final n in v.split(',')) int.parse(n.trim())];
}

/// Whether the switch `--name` is given.
bool flagArg(List<String> args, String name) => args.contains('--$name');
