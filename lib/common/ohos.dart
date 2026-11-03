import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// OHOS / HarmonyOS NEXT platform detection.
///
/// The Flutter-OHOS engine (`flutter_flutter`, OpenHarmony SIG) reports
/// `Platform.operatingSystem == 'ohos'`; on stock Flutter SDKs this is never
/// true, so Android / desktop builds are unaffected.

/// True when running on a HarmonyOS/OpenHarOS target built with Flutter-OHOS.
bool get isOhos => !kIsWeb && Platform.operatingSystem == 'ohos';

/// Mobile form factor: Android or HarmonyOS. Keep desktop behaviours
/// (window/tray/system proxy) keyed to the individual desktop platforms —
/// do NOT widen those call-sites with this getter.
bool get isOhosOrAndroid => Platform.isAndroid || isOhos;
