/// The deployed-build check behind the "new build" pill.
///
/// The dev loop publishes on every commit, so the question a phone asks
/// constantly is "am I looking at the build that was just pushed?".
/// deploy.sh stamps [buildTag] into the binary and writes the same tag
/// to build-info.json beside it; when the file says something else, a
/// newer deploy has landed. Every env var this build reads is named
/// `OH_…`.
library;

import 'update_check.dart'
    if (dart.library.js_interop) 'update_check_web.dart' as platform;

/// Short commit the running build came from. deploy.sh passes
/// `--dart-define=OH_BUILD=<sha>`; a local `flutter run` leaves it "dev".
const buildTag = String.fromEnvironment('OH_BUILD', defaultValue: 'dev');

/// The check is opt-in, and deliberately explicit: deploy.sh passes
/// `OH_UPDATE_CHECK=on` and nothing else does. Inferring it from a real-
/// looking [buildTag] would turn the pill on in CI, where it floats over
/// every widget test and eats taps.
const _updateCheckDefine = String.fromEnvironment('OH_UPDATE_CHECK');

bool get updateCheckEnabled =>
    _updateCheckDefine == 'on' || platform.forcedByQuery;

/// The published build tag, or null when it cannot be read (offline, a
/// non-web build, a deploy mid-flight). Never throws: a failed check is
/// a non-event, not an error worth showing.
Future<String?> publishedBuild() => platform.publishedBuild();

/// Reloads onto the published build. A no-op off the web.
void reloadPage() => platform.reloadPage();
