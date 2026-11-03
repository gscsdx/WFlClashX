import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ClashServiceChannel } from '../services/ClashServiceChannel';

const TAG: string = 'FlClashX-EntryAbility';

/**
 * UI-process entry. Hosts the Flutter engine and registers the
 * `com.wormhole.app/service` MethodChannel that Dart's ClashLib
 * (lib/clash/lib.dart) talks to.
 */
export default class EntryAbility extends FlutterAbility {
  private clashChannel: ClashServiceChannel | null = null;

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);
    hilog.info(0x0000, TAG, 'flutter engine configured');
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    super.onCreate(want, launchParam);
    hilog.info(0x0000, TAG, 'onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    super.onWindowStageCreate(windowStage);
    // Register the clash service channel once the engine exists.
    const engine: FlutterEngine | null = this.getFlutterEngine();
    if (engine !== null) {
      this.clashChannel = new ClashServiceChannel(this.context, engine);
      this.clashChannel.register();
      hilog.info(0x0000, TAG, 'ClashServiceChannel registered');
    }
  }

  onWindowStageDestroy(): void {
    this.clashChannel?.unregister();
    this.clashChannel = null;
    super.onWindowStageDestroy();
  }
}
