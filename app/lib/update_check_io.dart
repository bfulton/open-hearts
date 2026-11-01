/// Non-web stub: native builds are installed, not deployed, so there is
/// no build-info.json to ask about.
library;

bool get forcedByQuery => false;

Future<String?> publishedBuild() async => null;

/// Nothing to reload on a native build — the binary on disk is the build.
void reloadPage() {}
