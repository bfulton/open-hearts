/// Whether the device has a network at all, as the device itself says.
///
/// Only ever an answer one way. A browser that says it is online may
/// still reach nothing — a captive portal, a train between masts — so
/// a relay is waited for all the same (home_page.dart, `waitForRelay`).
/// A browser that says it is offline is in airplane mode or has no
/// signal, and waiting forty seconds for a relay will not change that:
/// the door says so at once instead. Off the web nothing here is told,
/// and the device is taken to be online, which is the old behaviour:
/// wait for a relay, and give up at the far deadline.
library;

import 'network_io.dart' if (dart.library.js_interop) 'network_web.dart' as platform;

/// True when the device says it has no network. Settable, like the
/// service's address (licence.dart): a widget test has no browser to
/// ask, and stands its own answer here.
bool Function() deviceOffline = platform.offline;
