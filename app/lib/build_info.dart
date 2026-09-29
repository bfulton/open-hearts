/// The deployed-build check behind the "new build" pill.
///
/// The dev loop publishes on every commit, so the question a phone asks
/// constantly is "am I looking at the build that was just pushed?".
/// deploy.sh writes the running build's identity into
/// `build_info.g.dart` before it builds — the one thing that has to be
/// compiled in, since a build cannot fetch its own identity — and the
/// same tag into build-info.json beside the published app; when the
/// file says something else, a newer deploy has landed.
library;

import 'build_info.g.dart';
import 'update_check.dart'
    if (dart.library.js_interop) 'update_check_web.dart' as platform;

/// Short commit the running build came from; "dev" for a local run.
const buildTag = generatedBuildTag;

/// UTC date the running build was published; "dev" for a local run.
const buildDate = generatedBuildDate;

/// On only in a deployed build: deploy.sh generates it on, and the
/// placeholder every other build uses has it off, so the pill never
/// floats over the widget tests in CI and eats their taps.
bool get updateCheckEnabled => generatedUpdateCheck || platform.forcedByQuery;

/// The published build tag, or null when it cannot be read (offline, a
/// non-web build, a deploy mid-flight). Never throws: a failed check is
/// a non-event, not an error worth showing.
Future<String?> publishedBuild() => platform.publishedBuild();

/// Reloads onto the published build. A no-op off the web.
void reloadPage() => platform.reloadPage();
