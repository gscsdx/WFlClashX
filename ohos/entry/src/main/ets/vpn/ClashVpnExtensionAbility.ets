import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
// NOTE: startBackgroundRunning is held by the UI process (KeepAliveManager in
// ClashServiceChannel) — the stage-model gate rejects continuous-task requests
// from extension contexts with 401 "Permission denied", so attempting it here
// is pointless. The extension relies on the main process' task plus the
// system's own keep-alive for active VPN tunnels.
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CoreBridge, DispatcherPayload } from '../services/CoreBridge';
import { ClashRpcServer } from '../services/ClashRpcServer';

const TAG: string = 'FlClashX-VpnExt';

/** Mirrors core/state.AndroidVpnOptions JSON tags. */
interface AccessControlProps {
  enable: boolean;
  mode: string;
  acceptList: string[];
  rejectList: string[];
}

interface VpnOptions {
  enable: boolean;
  port: number;
  ipv4Address: string;
  ipv6Address: string;
  accessControl?: AccessControlProps | null;
  routeAddress?: string[];
  bypassDomain?: string[];
  dnsServerAddress: string;
  includePackage?: string[];
  excludePackage?: string[];
}

/**
 * OHOS counterpart of android/service FlVpnService + RemoteService: this
 * extension process hosts BOTH the Go clash core (via NAPI) and the TUN
 * device, so no fd hand-off across processes is needed (the OHOS equivalent
 * of Android's `:remote` + AIDL transport is the loopback JSON-RPC served
 * here by ClashRpcServer).
 *
 * Lifecycle: the UI process calls startAbility(ClashVpnExtensionAbility)
 * whenever Dart's ClashLib performs `init`/`start`; the system shows the
 * VPN consent dialog when vpnConnection.create() first runs.
 */
export default class ClashVpnExtensionAbility extends VpnExtensionAbility {
  private rpcServer: ClashRpcServer = new ClashRpcServer();
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private tunFd: number = -1;
  private notificationTitle: string = 'FlClashX';
  private notificationStopText: string = '';

  onCreate(want: Want): void {
    hilog.info(0x0000, TAG, 'onCreate');
    // The core's home MUST be the same root the Dart side uses for its data
    // (path_provider's getApplicationSupportDirectory() -> el2/base/files).
    // A VpnExtensionContext's filesDir resolves to el2/base/haps/entry/files,
    // one level deeper; using it made the core's SAFE_PATHS allow-list reject
    // every path the UI hands over (e.g. .../base/files/zashboard), which
    // popped a blocking "path is not subpath of home directory" dialog on
    // launch and swallowed all further taps behind its modal barrier.
    const extFilesDir = this.context.filesDir;
    const hapsIdx = extFilesDir.indexOf('/haps/');
    const homeDir =
      hapsIdx > 0 ? `${extFilesDir.substring(0, hapsIdx)}/files` : extFilesDir;
    hilog.info(0x0000, TAG, 'core home=%{public}s', homeDir);
    if (!CoreBridge.init(homeDir)) {
      hilog.error(0x0000, TAG, 'core init failed');
    }
    // Route core events to the UI peer; socket protection goes to the live
    // VpnConnection (OHOS counterpart of Android's Protect JNI callback).
    CoreBridge.eventHandler = (msg: DispatcherPayload) => this.onCoreEvent(msg);

    this.registerHandlers();
    this.rpcServer.start().then((ok: boolean) => {
      if (!ok) {
        hilog.error(0x0000, TAG, 'rpc server failed to start');
      }
    });
    this.rpcServer.push('onStarted', '');
    this.updateNotification();
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'onDestroy');
    this.rpcServer.push('crash', 'extension destroyed');
    this.rpcServer.stop();
    CoreBridge.stopTun();
    this.destroyVpn();
  }

  onConnect(want: Want): void {
    hilog.info(0x0000, TAG, 'onConnect');
  }

  onDisconnect(want: Want): void {
    hilog.info(0x0000, TAG, 'onDisconnect');
  }

  private onCoreEvent(msg: DispatcherPayload): void {
    if (msg.type === 'event') {
      // Mirror every core event into hilog: the Dart log page is silent on
      // OHOS, so hilog is the only observability we have for core messages
      // ([TCP]/[UDP]/loopback/stack selection).
      hilog.info(0x0000, TAG, 'coreEvent: %{public}s',
        JSON.stringify(msg.data).substring(0, 1000));
      this.rpcServer.push('event', msg.data);
      return;
    }
    if (msg.type === 'protect') {
      const fd = (msg.data as Record<string, number>)['fd'] ?? 0;
      if (fd <= 0) {
        return;
      }
      const conn = this.vpnConnection;
      if (conn === null) {
        CoreBridge.notifyProtected(fd);
        return;
      }
      // The Go dialer thread is parked in TrampProtect until this ack lands,
      // so the socket is still open and connect() has not been issued yet —
      // exactly the contract Android's VpnService.protect() gives mihomo.
      conn.protect(fd).then(() => {
        CoreBridge.notifyProtected(fd);
      }).catch((e: object) => {
        hilog.warn(0x0000, TAG, 'protect fd %{public}d failed: %{public}s', fd, JSON.stringify(e));
        CoreBridge.notifyProtected(fd);
      });
    }
  }

  private registerHandlers(): void {
    this.rpcServer.on('ping', async () => 'pong');
    this.rpcServer.on('init', async () => 'ok');
    this.rpcServer.on('invokeAction', async (_m: string, params: object | string | number | boolean | null) => {
      return CoreBridge.invokeAction(params as string);
    });
    this.rpcServer.on('quickStart', async (_m: string, params: object | string | number | boolean | null) => {
      const args = params as Record<string, string>;
      return CoreBridge.quickStart(args.init, args.params, args.state);
    });
    this.rpcServer.on('getAndroidVpnOptions', async () => CoreBridge.getAndroidVpnOptions());
    this.rpcServer.on('updateDns', async (_m: string, params: object | string | number | boolean | null) => {
      CoreBridge.updateDns(params as string);
      return true;
    });
    this.rpcServer.on('getRunTime', async () => CoreBridge.getRunTime());
    this.rpcServer.on('getCurrentProfileName', async () => CoreBridge.getCurrentProfileName());
    this.rpcServer.on('resetConnections', async () => {
      CoreBridge.resetConnections();
      return true;
    });
    this.rpcServer.on('start', async (_m: string, params: object | string | number | boolean | null) => {
      return this.startVpn(params as string);
    });
    this.rpcServer.on('stop', async () => this.stopVpn());
    this.rpcServer.on('shutdown', async () => {
      await this.stopVpn();
      CoreBridge.shutdown();
      this.rpcServer.stop();
      // NOTE: VpnExtensionContext has no terminateSelf() in OpenHarmony API 12;
      // the process is reclaimed by the system once idle (all tasks stopped).
      return true;
    });
    this.rpcServer.on('updateNotificationParams', async (_m: string, params: object | string | number | boolean | null) => {
      const args = JSON.parse(params as string) as Record<string, string>;
      this.notificationTitle = args.title ?? 'FlClashX';
      this.notificationStopText = args.stopText ?? '';
      await this.updateNotification();
      return true;
    });
    this.rpcServer.on('setCrashlytics', async (_m: string, _p: object | string | number | boolean | null) => true);
    this.rpcServer.on('saveParams', async (_m: string, _p: object | string | number | boolean | null) => {
      // Cold-start persistence (tile/widget equivalents) is not wired on OHOS
      // yet; params are accepted so the Dart contract stays intact.
      return true;
    });
  }

  /** Build VpnConfig from state.AndroidVpnOptions and bring the TUN up. */
  private async startVpn(optionsJson: string): Promise<number> {
    if (optionsJson === '') {
      hilog.error(0x0000, TAG, 'startVpn: empty options');
      return 0;
    }
    let options: VpnOptions;
    try {
      options = JSON.parse(optionsJson) as VpnOptions;
    } catch (e) {
      hilog.error(0x0000, TAG, 'startVpn: bad options json');
      return 0;
    }
    hilog.info(0x0000, TAG, 'startVpn options: %{public}s', optionsJson);

    if (this.vpnConnection !== null) {
      // A previous tunnel is still around; tear it down first (matches
      // Android VpnService.prepare() semantics).
      await this.destroyVpn();
    }

    const conn: vpnExtension.VpnConnection =
      vpnExtension.createVpnConnection(this.context);
    this.vpnConnection = conn;

    try {
      this.tunFd = await conn.create(this.buildVpnConfig(options));
    } catch (e) {
      hilog.error(0x0000, TAG, 'vpn create rejected: %{public}s', JSON.stringify(e));
      this.vpnConnection = null;
      return 0;
    }

    const ok = CoreBridge.startTun(this.tunFd);
    if (!ok) {
      hilog.error(0x0000, TAG, 'core rejected tun fd %{public}d', this.tunFd);
      // fd ownership passed to the core on startTun entry; on rejection the
      // core may have closed it — do not double-close here.
      this.destroyVpn();
      return 0;
    }
    hilog.info(0x0000, TAG, 'tun up fd=%{public}d', this.tunFd);
    return this.tunFd;
  }

  private async stopVpn(): Promise<boolean> {
    CoreBridge.stopTun();
    await this.destroyVpn();
    return true;
  }

  private async destroyVpn(): Promise<void> {
    const conn = this.vpnConnection;
    this.vpnConnection = null;
    this.tunFd = -1;
    if (conn !== null) {
      try {
        await conn.destroy();
      } catch (e) {
        hilog.warn(0x0000, TAG, 'vpn destroy: %{public}s', JSON.stringify(e));
      }
    }
  }

  private buildVpnConfig(options: VpnOptions): vpnExtension.VpnConfig {
    const addresses: vpnExtension.LinkAddress[] = [];
    const v4 = options.ipv4Address ?? '';
    if (v4 !== '') {
      const parts = v4.split('/');
      addresses.push({
        address: { address: parts[0], family: 1 },
        prefixLength: parseInt(parts[1] ?? '30', 10)
      });
    }
    const v6 = options.ipv6Address ?? '';
    const hasV6 = v6 !== '';
    if (hasV6) {
      const parts6 = v6.split('/');
      addresses.push({
        address: { address: parts6[0], family: 2 },
        prefixLength: parseInt(parts6[1] ?? '126', 10)
      });
    }

    const routes: vpnExtension.RouteInfo[] = [];
    const routeAddress = options.routeAddress ?? [];
    if (routeAddress.length === 0) {
      routes.push(this.prefixToRoute('0.0.0.0/0'));
      if (hasV6) {
        routes.push(this.prefixToRoute('::/0'));
      }
    } else {
      for (const prefix of routeAddress) {
        routes.push(this.prefixToRoute(prefix));
      }
    }

    // Split tunneling: accessControl wins over the profile-level
    // include/excludePackage lists, mirroring the Dart merge order.
    let trustedApplications: string[] = options.includePackage ?? [];
    let blockedApplications: string[] = options.excludePackage ?? [];
    const ac = options.accessControl;
    if (ac !== null && ac !== undefined && ac.enable) {
      if (ac.mode === 'accept') {
        trustedApplications = ac.acceptList ?? [];
        blockedApplications = [];
      } else {
        blockedApplications = ac.rejectList ?? [];
        trustedApplications = [];
      }
    }

    // Android's VpnService implicitly keeps the VPN owner out of its own
    // tunnel; OHOS VpnConnection does not. Without this, every socket the Go
    // core opens (proxy dials, health checks, DNS upstream) is captured by
    // our own TUN, re-enters mihomo as a fresh flow and is killed by its
    // loop guard (component/loopback: an incoming flow whose source addr:port
    // equals the local addr of one of our own outbound sockets):
    //   [TCP] 172.19.0.1:59222 --> 172.64.146.88:443 error: reject loopback ...
    // OHOS semantics (mutually exclusive, see @ohos.net.vpnExtension):
    //   trustedApplications = allowlist: only these are proxied
    //   blockedApplications = denylist:  all but these are proxied
    // So an allowlist must simply not contain us, while a denylist must.
    // NOTE: keeping our own bundle in either list does not work on OHOS.
    // trustedApplications is an allowlist (only those apps are proxied), so
    // listing ourselves made *only* the core's sockets traverse the tunnel —
    // the exact loop we wanted to avoid. blockedApplications behaves like a
    // black hole for the listed UIDs on this device (the browser lost all
    // connectivity), not like Android's addDisallowedApplication. So the core
    // is kept out of its own tunnel the Android way: synchronous
    // VpnConnection.protect() on every outbound socket (see TrampProtect).
    hilog.info(0x0000, TAG, 'vpn apps trusted=%{public}d blocked=%{public}d',
      trustedApplications.length, blockedApplications.length);

    const dnsServers: string[] = [];
    if (options.dnsServerAddress !== undefined && options.dnsServerAddress !== '') {
      dnsServers.push(options.dnsServerAddress);
    }

    const config: vpnExtension.VpnConfig = {
      addresses: addresses,
      routes: routes,
      mtu: 1500,
      dnsAddresses: dnsServers,
      isIPv4Accepted: true,
      isIPv6Accepted: hasV6,
      isInternal: false,
      isBlocking: false,
      trustedApplications: trustedApplications,
      blockedApplications: blockedApplications
    };
    return config;
  }

  private prefixToRoute(prefix: string): vpnExtension.RouteInfo {
    const parts = prefix.split('/');
    const isV6 = parts[0].indexOf(':') >= 0;
    // connection.RouteInfo requires interface + gateway even when unused
    // (hasGateway=false makes the gateway value ignored).
    const route: vpnExtension.RouteInfo = {
      interface: '',
      destination: {
        address: { address: parts[0], family: isV6 ? 2 : 1 },
        prefixLength: parseInt(parts[1] ?? '0', 10)
      },
      gateway: { address: '', family: 1 },
      hasGateway: false,
      isDefaultRoute: parts[1] === '0'
    };
    return route;
  }

  private async updateNotification(): Promise<void> {
    const content = this.notificationStopText !== ''
      ? `${this.notificationTitle} · ${this.notificationStopText}`
      : this.notificationTitle;
    const request: notificationManager.NotificationRequest = {
      id: 1001,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: content,
          text: 'VPN 运行中',
          additionalText: ''
        }
      }
    };
    try {
      await notificationManager.publish(request);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'notification publish: %{public}s', JSON.stringify(e));
    }
  }
}
