/// A tiny reader for the analysis tools' command-line arguments:
/// `--name value` or `--name=value`, with a default. The tools are run
/// by hand — `dart run tool/arena.dart --games 3000` — so their knobs
/// are arguments, not build-time defines.
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

String strArg(List<String> args, String name, String fallback) => _argOf(args, name) ?? fallback;
