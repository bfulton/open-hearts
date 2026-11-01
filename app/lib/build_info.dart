/// Which build is running, and the deployed-build check behind the "new
/// build" pill.
///
/// The build's identity is compiled in, since a build cannot fetch its
/// own: every build that ships is given its commit and date as defines,
/// with the update check on, by app/tool/defines.mjs, which deploy.sh,
/// build_phone.sh and the iOS workflow run. deploy.sh also writes the
/// same tag into build-info.json beside the published app; when the file
/// says something else, a newer deploy has landed.
library;

import 'update_check_io.dart' if (dart.library.js_interop) 'update_check_web.dart' as platform;

/// Short commit the running build came from, with "+" when it was built
/// from a tree with uncommitted changes; "dev" for a local run.
const buildTag = String.fromEnvironment('OH_BUILD_TAG', defaultValue: 'dev');

/// UTC date the running build was made, YYYY-MM-DD; "dev" for a local
/// run.
const buildDate = String.fromEnvironment('OH_BUILD_DATE', defaultValue: 'dev');

/// On in every build app/tool/defines.mjs writes, and off in local runs
/// and tests, so the pill never floats over the widget tests and eats
/// their taps. Only the web shows the pill: a phone has no
/// build-info.json, so publishedBuild() is null there.
bool get updateCheckEnabled => const bool.fromEnvironment('OH_UPDATE_CHECK') || platform.forcedByQuery;

/// The published build tag, or null when it cannot be read (offline, a
/// non-web build, a deploy mid-flight). Never throws: a failed check is
/// a non-event, not an error worth showing.
Future<String?> publishedBuild() => platform.publishedBuild();

/// Reloads onto the published build. A no-op off the web.
void reloadPage() => platform.reloadPage();
