import 'dart:io';

import 'package:wormhole/plugins/app.dart';
import 'package:wormhole/state.dart';

class Android {
  Future<void> init() async {
    app?.onExit = () async {
      await globalState.appController.savePreferences();
    };
  }
}

final android = Platform.isAndroid ? Android() : null;
