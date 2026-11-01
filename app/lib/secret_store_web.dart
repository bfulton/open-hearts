/// The web has no store of its own for the key: it is among the page's
/// preferences, in the browser's storage, where web/carry.js brings it
/// along from the app's old address.
library;

import 'secret_store.dart';

SecretStore? secretStoreHere() => null;
