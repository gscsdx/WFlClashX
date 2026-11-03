import 'dart:async';
import 'dart:io';

import 'package:wormhole/clash/clash.dart';
import 'package:wormhole/common/ohos.dart';

/// Compatibility façade over [ClashLib] for call-sites that still reach for a
/// standalone "service" object. Under the AIDL architecture there is no
/// separate Dart-side service — everything is one MethodChannel.
class Service {
  factory Service() => _instance ??= Service._();
  static Service? _instance;
  Service._();

  Future<bool?> init() async {
    await clashLib?.preload();
    return true;
  }

  Future<bool?> destroy() async => clashLib?.destroy();

  Future<bool?> startVpn() async {
    final rt = await clashLib?.startVpn() ?? 0;
    return rt != 0;
  }

  Future<bool?> stopVpn() async => clashLib?.stopVpn();
}

Service? get service => isOhosOrAndroid ? Service() : null;
