import clashBridge from 'libclash_bridge.so';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'FlClashX-CoreBridge';

export interface DispatcherPayload {
  type: string;
  data: object | string;
}

interface ActionResultEnvelope {
  id?: string;
  method?: string;
  data?: object;
}

/**
 * Typed wrapper over the NAPI bridge to libclash_core.so (mihomo, built by
 * core/build_ohos.sh). Maps 1:1 to the cgo exports in core/lib_android.go
 * (shared android/ohos bridge) and core/lib.go.
 *
 * Result routing mirrors Dart's callbackCompleterMap: every Action carries an
 * "id", the Go hub echoes it in the ActionResult, and pending Promise
 * resolvers live in [pendingInvokes] until the dispatcher delivers the
 * matching payload.
 */
export class CoreBridge {
  private static pendingInvokes: Map<string, (result: string) => void> = new Map();
  private static sinkRegistered = false;

  /** Router for 'event' / 'protect' payloads; set by the RPC server. */
  static eventHandler: ((msg: DispatcherPayload) => void) | null = null;

  /** Load the Go core, register callbacks, and run handleInitClash. */
  static init(homeDir: string): boolean {
    hilog.info(0x0000, TAG, 'init home=%{public}s', homeDir);
    if (!CoreBridge.sinkRegistered) {
      clashBridge.setEventSink((payload: string) => CoreBridge.onDispatch(payload));
      CoreBridge.sinkRegistered = true;
    }
    return clashBridge.initCore(homeDir);
  }

  /** Forward a JSON Action; resolves with the raw ActionResult JSON string. */
  static invokeAction(actionJson: string): Promise<string> {
    return new Promise<string>((resolve) => {
      let id = '';
      try {
        const action: object = JSON.parse(actionJson);
        if (typeof action['id'] === 'string') {
          id = action['id'];
        }
      } catch (e) {
        hilog.error(0x0000, TAG, 'invokeAction json parse failed');
      }
      if (id !== '') {
        CoreBridge.pendingInvokes.set(id, resolve);
      }
      clashBridge.invokeAction(actionJson);
      if (id === '') {
        // No correlation id: nothing will ever resolve this. Fail fast with an
        // empty envelope so callers treat it like the Android empty-response
        // path (see ClashLib._failPendingCompleter).
        resolve('');
      }
    });
  }

  /** quickStart = initClash + setState + setupConfig, '' = ok. Synchronous. */
  static quickStart(initJson: string, paramsJson: string, stateJson: string): string {
    return clashBridge.quickStart(initJson, paramsJson, stateJson);
  }

  /** Bring the TUN up on the fd returned by VpnConnection.create(). */
  static startTun(fd: number): boolean {
    return clashBridge.startTun(fd);
  }

  static stopTun(): void {
    clashBridge.stopTun();
  }

  static getRunTime(): number {
    return clashBridge.getRunTime();
  }

  static getAndroidVpnOptions(): string {
    return clashBridge.getAndroidVpnOptions();
  }

  static getCurrentProfileName(): string {
    return clashBridge.getCurrentProfileName();
  }

  static updateDns(dnsJson: string): void {
    clashBridge.updateDns(dnsJson);
  }

  static setState(stateJson: string): void {
    clashBridge.setState(stateJson);
  }

  static resetConnections(): void {
    clashBridge.resetConnections();
  }

  /** Release the Go dialer thread parked in TrampProtect (see clash_bridge.cpp). */
  static notifyProtected(fd: number): void {
    clashBridge.notifyProtected(fd);
  }

  static shutdown(): boolean {
    return clashBridge.shutdownCore();
  }

  private static onDispatch(payload: string): void {
    let msg: DispatcherPayload;
    try {
      msg = JSON.parse(payload) as DispatcherPayload;
    } catch (e) {
      hilog.error(0x0000, TAG, 'dispatcher payload parse failed: %{public}s', payload);
      return;
    }
    switch (msg.type) {
      case 'actionResult': {
        const raw = typeof msg.data === 'string' ? msg.data : JSON.stringify(msg.data);
        let id = '';
        try {
          const parsed: ActionResultEnvelope = JSON.parse(raw) as ActionResultEnvelope;
          if (typeof parsed.id === 'string') id = parsed.id;
        } catch (e) {
          // Not an ActionResult envelope (plain error string from a raw
          // callback) — nothing to correlate.
        }
        const resolver = CoreBridge.pendingInvokes.get(id);
        if (resolver !== undefined) {
          CoreBridge.pendingInvokes.delete(id);
          resolver(raw);
        } else if (id !== '') {
          hilog.warn(0x0000, TAG, 'actionResult without pending invoke id=%{public}s', id);
        }
        break;
      }
      case 'event':
      case 'protect':
        CoreBridge.onEvent(msg);
        break;
      default:
        break;
    }
  }

  /** Override point: RPC server / extension routes these to Dart. */
  private static onEvent(msg: DispatcherPayload): void {
    if (CoreBridge.eventHandler !== null) {
      CoreBridge.eventHandler(msg);
    } else {
      hilog.debug(0x0000, TAG, 'core event dropped (no handler): %{public}s', msg.type);
    }
  }
}
