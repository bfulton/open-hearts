/// Which build is running, and the deployed-build check behind the "new
/// build" pill.
///
/// The build's identity is compiled in, since a build cannot fetch its
/// own: every build that ships is given it as defines. deploy.sh gives
/// the web build its commit and date, and turns the update check on;
/// build_phone.sh and the iOS workflow give a phone build the same two
/// through app/tool/defines.mjs. deploy.sh also writes the same tag into
/// build-info.json beside the published app; when the file says
/// something else, a newer deploy has landed.
library;

import 'update_check_io.dart' if (dart.library.js_interop) 'update_check_web.dart' as platform;

/// Short commit the running build came from, with "+" when it was built
/// from a tree with uncommitted changes; "dev" for a local run.
const buildTag = String.fromEnvironment('OH_BUILD_TAG', defaultValue: 'dev');

/// UTC date the running build was made, YYYY-MM-DD; "dev" for a local
/// run.
const buildDate = String.fromEnvironment('OH_BUILD_DATE', defaultValue: 'dev');

/// On only in a deployed web build: deploy.sh turns it on, and every
/// other build has it off, so the pill never floats over the widget
/// tests in CI and eats their taps.
bool get updateCheckEnabled => const bool.fromEnvironment('OH_UPDATE_CHECK') || platform.forcedByQuery;

/// The published build tag, or null when it cannot be read (offline, a
/// non-web build, a deploy mid-flight). Never throws: a failed check is
/// a non-event, not an error worth showing.
Future<String?> publishedBuild() => platform.publishedBuild();

/// Reloads onto the published build. A no-op off the web.
void reloadPage() => platform.reloadPage();
