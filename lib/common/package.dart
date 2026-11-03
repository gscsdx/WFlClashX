import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

extension PackageInfoExtension on PackageInfo {
  /// FlClash X's own User-Agent. Not the outbound default: unless the user
  /// picks this identity explicitly, requests go out as clash-verge (see
  /// `common/ua.dart`). [appVersion] is the display version (the exact tag on
  /// release builds, pubspec version + `-pre` on local ones); [coreVersion] is
  /// the embedded mihomo version (already `v`-prefixed), surfaced as a `core/`
  /// token.
  String ua({required String appVersion, String? coreVersion}) => [
        "FlClash X/v$appVersion",
        if (coreVersion != null && coreVersion.isNotEmpty) "core/$coreVersion",
        "Platform/${Platform.operatingSystem}",
      ].join(" ");
}
