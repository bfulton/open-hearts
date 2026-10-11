/// A phone's build: no page it was served from, so the app's address —
/// where the service's handlers are, and what a shared link opens — is
/// the one the build names (config/openhearts.json's appOrigin, passed
/// by build_phone.sh), play.openhearts.game. A build that names none,
/// a test or a dev loop's, has only the platform's own, which asks no
/// service and builds no link.
library;

const _origin = String.fromEnvironment('OH_APP_ORIGIN');

Uri appBase() => appBaseFrom(_origin, Uri.base);

/// The app's address from the origin a build names, or [served] where
/// it names none.
Uri appBaseFrom(String origin, Uri served) => origin.isEmpty ? served : Uri.parse(origin).replace(path: '/');
