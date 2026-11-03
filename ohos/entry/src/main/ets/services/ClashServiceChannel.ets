import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { vpnExtension } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FlutterEngine, MethodChannel, MethodCall, MethodResult, MethodCallHandler } from '@ohos/flutter_ohos';
import { CHANNEL_NAME, VPN_ABILITY_NAME, RpcPush } from './RpcProtocol';
import { ClashRpcClient } from './ClashRpcClient';
import { KeepAliveManager } from './KeepAliveManager';

const TAG: string = 'FlClashX-Channel';

/**
 * Extract the VpnOptions JSON out of whatever shape the channel delivered.
 * Dart maps reach ArkTS either as a plain object or as an ES Map depending on
 * the codec path, so probe both before giving up.
 */
function readOptionsJson(args: object | string | number | boolean | null | undefined): string {
  if (args === null || args === undefined) {
    return '';
  }
  if (typeof args === 'string') {
    return args;
  }
  const rec = args as Record<string, string>;
  const direct = rec.data;
  if (typeof direct === 'string') {
    return direct;
  }
  const asMap = args as Map<string, string>;
  if (typeof asMap.get === 'function') {
    const fromMap = asMap.get('data');
    if (typeof fromMap === 'string') {
      return fromMap;
    }
  }
  return '';
}

/**
 * UI-process implementation of the `com.wormhole.app/service` MethodChannel.
 * Contract (must stay in sync with lib/clash/lib.dart):
 *
 *   init                       -> "ok"                 (start VPN ext + connect)
 *   invokeAction(String json)  -> String ActionResult  (forwarded over RPC)
 *   quickStart{init,params,state} -> String error ('' = ok)
 *   getAndroidVpnOptions       -> String
 *   updateDns(String json)     -> bool
 *   getRunTime                 -> int ms (0 = stopped)
 *   getCurrentProfileName      -> String
 *   start {data: optionsJson}  -> int fd (0 = failed)
 *   stop                       -> bool
 *   shutdown                   -> bool
 *   updateNotificationParams(String json) -> void
 *   setCrashlytics(bool)       -> void
 *   saveParams{init,params,state} -> void
 *
 * Pushes into Dart:
 *   event(String json)     — Go Message stream (traffic/logs/delays/…)
 *   crash(String reason)   — extension connection lost unexpectedly
 *   onStarted()            — extension process ready
 */
export class ClashServiceChannel {
  private client: ClashRpcClient = new ClashRpcClient();
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext, engine: FlutterEngine) {
    this.context = context;
    this.channel = new MethodChannel(engine.dartExecutor.getBinaryMessenger(), CHANNEL_NAME);
  }

  register(): void {
    this.client.onPush = (push: RpcPush) => this.forwardPush(push.push, push.data);
    this.client.onDisconnected = (reason: string) => this.forwardPush('crash', reason);
    const handler: MethodCallHandler = {
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        this.handle(call, result);
      }
    };
    this.channel?.setMethodCallHandler(handler);
  }

  unregister(): void {
    this.client.close();
    this.channel?.setMethodCallHandler(null);
  }

  private forwardPush(name: string, data: object | string | undefined): void {
    // Dart registers a handler on the same channel (ClashLib._onMethodCall).
    // Fire-and-forget: push failures only surface in the log.
    this.channel?.invokeMethod(name, data ?? '');
  }

  /** Ensure the VPN extension process is up and the RPC channel is live. */
  private ensureTask: Promise<void> | null = null;

  /**
   * Single-flight: every MethodChannel call funnels through here, and concurrent
   * Dart calls (init + preload + status polls on cold start) would otherwise
   * each fail to connect and each call startVpnExtensionAbility — spawning one
   * extension process per call and killing the previous one mid-init.
   */
  private ensureExtension(): Promise<void> {
    if (this.ensureTask === null) {
      this.ensureTask = this.doEnsureExtension().finally(() => {
        this.ensureTask = null;
      });
    }
    return this.ensureTask;
  }

  private async doEnsureExtension(): Promise<void> {
    try {
      await this.client.connect();
      return;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'initial connect failed: %{public}s', JSON.stringify(err));
    }
    // Server may not be listening yet (cold extension). Start it, then poll:
    // the extension must boot, init the Go core via NAPI and bind the port.
    try {
      await this.startExtensionAbility();
    } catch (e) {
      hilog.error(0x0000, TAG, 'startExtensionAbility failed: %{public}s', JSON.stringify(e));
    }
    for (let i = 0; i < 40; i++) {
      try {
        await this.client.connect();
        hilog.info(0x0000, TAG, 'extension rpc connected after %{public}d retries', i);
        return;
      } catch (err) {
        await new Promise<void>((resolve) => setTimeout(resolve, 250));
      }
    }
    hilog.error(0x0000, TAG, 'extension rpc never came up after start');
  }

  private async startExtensionAbility(): Promise<void> {
    const want: Want = {
      deviceId: '',
      bundleName: this.context.abilityInfo.bundleName,
      abilityName: VPN_ABILITY_NAME
    };
    hilog.info(0x0000, TAG, 'startExtensionAbility: %{public}s', JSON.stringify(want));
    // VpnExtensionAbility CANNOT be started via context.startAbility (error
    // 16000002 "incorrect ability type"); the VPN-specific entry point pops
    // the system VPN trust dialog on first use and then launches onCreate.
    await vpnExtension.startVpnExtensionAbility(want);
  }

  private handle(call: MethodCall, result: MethodResult): void {
    const method: string = call.method;
    hilog.debug(0x0000, TAG, 'channel call %{public}s', method);
    switch (method) {
      case 'init':
        this.ensureExtension()
          .then(() => this.client.call('init'))
          .then(() => result.success('ok'))
          .catch((err: BusinessError<string>) => {
            hilog.error(0x0000, TAG, 'init failed: %{public}s', JSON.stringify(err));
            result.success('');
          });
        break;
      case 'invokeAction': {
        const actionJson = call.args as string;
        this.ensureExtension()
          .then(() => this.client.call('invokeAction', actionJson, 60000))
          .then((res) => result.success(res as string))
          .catch((err: BusinessError<string>) => {
            hilog.error(0x0000, TAG, 'invokeAction failed: %{public}s', JSON.stringify(err));
            result.success('');
          });
        break;
      }
      case 'quickStart': {
        const args = call.args as object;
        this.ensureExtension()
          .then(() => this.client.call('quickStart', args, 90000))
          .then((res) => result.success(res as string))
          .catch((err: BusinessError<string>) => {
            hilog.error(0x0000, TAG, 'quickStart failed: %{public}s', err);
            result.success(`rpc error: ${err}`);
          });
        break;
      }
      case 'getAndroidVpnOptions':
        this.ensureExtension()
          .then(() => this.client.call('getAndroidVpnOptions', null, 15000))
          .then((res) => result.success(res as string))
          .catch(() => result.success(''));
        break;
      case 'updateDns':
        this.ensureExtension()
          .then(() => this.client.call('updateDns', call.args as string, 15000))
          .then(() => result.success(true))
          .catch(() => result.success(false));
        break;
      case 'getRunTime':
        this.ensureExtension()
          .then(() => this.client.call('getRunTime', null, 15000))
          .then((res) => result.success(typeof res === 'number' ? res : parseInt(`${res}`, 10) || 0))
          .catch(() => result.error('getRunTime probe failed', '', null));
        break;
      case 'getCurrentProfileName':
        this.ensureExtension()
          .then(() => this.client.call('getCurrentProfileName', null, 15000))
          .then((res) => result.success(res as string))
          .catch(() => result.success(''));
        break;
      case 'start': {
        // Callers may pass the merged options JSON directly (preferred) or, for
        // older builds, wrapped as {data: <json>}. A Dart Map arrives here as an
        // ArkTS Map, where `args.data` is undefined — so try the Map getter too.
        const optionsJson = readOptionsJson(call.args);
        hilog.info(0x0000, TAG, 'start: options len=%{public}d', optionsJson.length);
        this.ensureExtension()
          .then(() => this.client.call('start', optionsJson, 120000))
          .then((res) => {
            const fd = typeof res === 'number' ? res : parseInt(`${res}`, 10) || 0;
            if (fd > 0) {
              // Tunnel is up: hold the continuous task from the UI process.
              // startBackgroundRunning only accepts UIAbility contexts — the
              // extension process gets 401 — so the keep-alive lives here.
              KeepAliveManager.get().enable(this.context)
                .catch((e: object) => {
                  hilog.error(0x0000, TAG, 'keep-alive enable: %{public}s', JSON.stringify(e));
                });
            }
            result.success(fd);
          })
          .catch((err: BusinessError<string>) => {
            hilog.error(0x0000, TAG, 'start failed: %{public}s', err);
            result.success(0);
          });
        break;
      }
      case 'stop':
        KeepAliveManager.get().disable(this.context);
        this.client.isConnected()
          ? this.client.call('stop', null, 60000)
            .then(() => result.success(true))
            .catch(() => result.success(true)) // UI-side cleanup proceeds anyway
          : Promise.resolve().then(() => result.success(true));
        break;
      case 'shutdown':
        KeepAliveManager.get().disable(this.context);
        this.client.isConnected()
          ? this.client.call('shutdown', null, 60000)
            .then(() => result.success(true))
            .catch(() => result.success(true))
          : Promise.resolve().then(() => result.success(true));
        this.client.close();
        break;
      case 'updateNotificationParams': {
        // The notification title flows through the extension too, but the
        // keep-alive live view is published from THIS process — mirror it.
        try {
          const notifyArgs = JSON.parse(`${call.args}`) as Record<string, string>;
          KeepAliveManager.get().setTitle(notifyArgs.title ?? '');
        } catch (e) {
          // Malformed payload: keep the previous title.
        }
        this.client.isConnected()
          ? this.client.call('updateNotificationParams', call.args as string, 15000)
            .then(() => result.success(null))
            .catch((e: string) => result.error('notify', e, null))
          : result.success(null);
        break;
      }
      case 'setCrashlytics':
        // v1: persisted on the extension side for parity; no crash reporting.
        result.success(null);
        break;
      case 'saveParams':
        this.client.isConnected()
          ? this.client.call('saveParams', call.args as object, 30000)
            .then(() => result.success(null))
            .catch(() => result.success(null))
          : result.success(null);
        break;
      default:
        result.notImplemented();
        break;
    }
  }
}
