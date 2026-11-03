import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  RPC_HOST, RPC_PORT, RpcPush, RpcRequest, RpcResponse,
  ByteLineSplitter, encodeFrame
} from './RpcProtocol';

const TAG: string = 'FlClashX-RpcClient';

interface Pending {
  resolve: (value: object | string | number | boolean | null) => void;
  reject: (reason: string) => void;
  timer: number;
}

type RpcValue = object | string | number | boolean | null;

/**
 * UI-process peer of ClashRpcServer. Owns the single loopback connection to
 * the VPN extension process; pushes (Go events, crash notices) are surfaced
 * through [onPush] so ClashServiceChannel can forward them into Dart via the
 * MethodChannel — exactly the Android `:remote` event path.
 */
export class ClashRpcClient {
  // API 24: the TCPSocket instance doubles as the connection (bind+connect).
  private conn: socket.TCPSocket | null = null;
  private splitter: ByteLineSplitter = new ByteLineSplitter();
  private seq: number = 0;
  private pending: Map<string, Pending> = new Map();
  private connectPromise: Promise<void> | null = null;

  /** Set by ClashServiceChannel. */
  onPush: ((push: RpcPush) => void) | null = null;
  /** Invoked when the connection drops unexpectedly (maps to Dart's 'crash'). */
  onDisconnected: ((reason: string) => void) | null = null;

  isConnected(): boolean {
    return this.conn !== null;
  }

  /** Idempotent connect; resolves once the extension's server answers. */
  connect(): Promise<void> {
    if (this.conn !== null) {
      return Promise.resolve();
    }
    if (this.connectPromise !== null) {
      return this.connectPromise;
    }
    this.connectPromise = this.doConnect().finally(() => {
      this.connectPromise = null;
    });
    return this.connectPromise;
  }

  private async doConnect(): Promise<void> {
    try {
      const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
      // API 24 requires an explicit (possibly ephemeral) local bind first.
      const localAddr: socket.NetAddress = { address: '0.0.0.0', port: 0, family: 1 };
      await tcp.bind(localAddr);
      await tcp.connect({
        address: { address: RPC_HOST, port: RPC_PORT, family: 1 },
        timeout: 10000
      });
      this.conn = tcp;
      this.splitter.reset();
      tcp.on('message', (value: socket.SocketMessageInfo) => {
        this.feed(value.message);
      });
      tcp.on('close', () => this.handleClose('closed'));
      tcp.on('error', (err: object) => this.handleClose(JSON.stringify(err)));
      hilog.info(0x0000, TAG, 'connected to extension rpc');
    } catch (e) {
      hilog.error(0x0000, TAG, 'connect failed: %{public}s', JSON.stringify(e));
      throw e as Error;
    }
  }

  close(): void {
    const conn: socket.TCPSocket | null = this.conn;
    this.conn = null;
    if (conn !== null) {
      conn.close().catch(() => {});
    }
    this.failAllPending('connection closed');
  }

  call(method: string, params?: RpcValue, timeoutMs: number = 30000): Promise<RpcValue> {
    if (this.conn === null) {
      return Promise.reject('rpc not connected');
    }
    const id = `r${++this.seq}`;
    const conn: socket.TCPSocket = this.conn;
    return new Promise((resolve: (value: RpcValue) => void,
                        reject: (reason: string) => void) => {
      const timer: number = setTimeout(() => {
        this.pending.delete(id);
        reject(`rpc timeout: ${method}`);
      }, timeoutMs);
      const entry: Pending = { resolve: resolve, reject: reject, timer: timer };
      this.pending.set(id, entry);
      const req: RpcRequest = { id: id, method: method, params: params ?? null };
      const frame = encodeFrame(req);
      conn.send({ data: frame }).catch((e: object) => {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(`rpc send failed: ${JSON.stringify(e)}`);
      });
    });
  }

  private feed(chunk: ArrayBuffer): void {
    for (const line of this.splitter.push(chunk)) {
      this.handleLine(line);
    }
  }

  private handleLine(line: string): void {
    let parsed: object;
    try {
      parsed = JSON.parse(line) as object;
    } catch (e) {
      hilog.error(0x0000, TAG, 'bad frame: %{public}s', line);
      return;
    }
    if (parsed['push'] !== undefined) {
      const push: RpcPush = {
        push: parsed['push'] as string,
        data: parsed['data'] as object | string
      };
      this.onPush?.(push);
      return;
    }
    const resp = parsed as RpcResponse;
    const pending = this.pending.get(resp.id);
    if (pending === undefined) {
      hilog.warn(0x0000, TAG, 'response without pending id=%{public}s', resp.id);
      return;
    }
    clearTimeout(pending.timer);
    this.pending.delete(resp.id);
    if (resp.error !== undefined) {
      pending.reject(resp.error);
    } else {
      pending.resolve(resp.result ?? null);
    }
  }

  private handleClose(reason: string): void {
    if (this.conn === null) {
      return;
    }
    this.conn = null;
    this.failAllPending(reason);
    // Unexpected loss of the extension process maps to Dart's crash-restart
    // flow (ClashLib._handleCrashRestart).
    this.onDisconnected?.(reason);
  }

  private failAllPending(reason: string): void {
    this.pending.forEach((pending: Pending): void => {
      clearTimeout(pending.timer);
      pending.reject(reason);
    });
    this.pending.clear();
  }
}
