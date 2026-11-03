import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RPC_HOST, RPC_PORT, RpcRequest, RpcResponse, RpcPush,
  ByteLineSplitter, encodeFrame } from './RpcProtocol';

const TAG: string = 'FlClashX-RpcServer';

export type RpcHandler = (method: string, params: object | string | number | boolean | null) => Promise<object | string | number | boolean | null>;

/**
 * Loopback JSON-RPC server running in the VPN extension process. The UI
 * process (ClashRpcClient) is the only intended peer — bind to 127.0.0.1 so
 * the endpoint is unreachable from the network.
 */
export class ClashRpcServer {
  // API 24: dedicated server class (TCPSocket has no listen()).
  private server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
  private handlers: Map<string, RpcHandler> = new Map();
  private connections: socket.TCPSocketConnection[] = [];
  private buffers: Map<socket.TCPSocketConnection, ByteLineSplitter> = new Map();
  private running = false;

  /** Register a command handler (method name -> async handler). */
  on(method: string, handler: RpcHandler): void {
    this.handlers.set(method, handler);
  }

  async start(): Promise<boolean> {
    if (this.running) return true;
    try {
      const bindAddr: socket.NetAddress = { address: RPC_HOST, port: RPC_PORT, family: 1 };
      await this.server.listen(bindAddr);
      this.server.on('connect', (client: socket.TCPSocketConnection) => {
        this.attach(client);
      });
      this.running = true;
      hilog.info(0x0000, TAG, 'listening on %{public}d', RPC_PORT);
      return true;
    } catch (e) {
      hilog.error(0x0000, TAG, 'start failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  async stop(): Promise<void> {
    this.running = false;
    for (const conn of this.connections) {
      try {
        await conn.close();
      } catch (e) {
        // ignore
      }
    }
    this.connections = [];
    this.buffers.clear();
    try {
      await this.server.close();
    } catch (e) {
      // ignore
    }
  }

  /** Push a message to every connected UI peer. */
  push(pushName: string, data: object | string): void {
    if (!this.running) return;
    const push: RpcPush = { push: pushName, data: data };
    const frame = encodeFrame(push);
    for (const conn of this.connections) {
      conn.send({ data: frame }).catch((e: object) => {
        hilog.warn(0x0000, TAG, 'push to peer failed: %{public}s', JSON.stringify(e));
      });
    }
  }

  private attach(client: socket.TCPSocketConnection): void {
    hilog.info(0x0000, TAG, 'peer connected');
    this.connections.push(client);
    this.buffers.set(client, new ByteLineSplitter());
    client.on('message', (value: socket.SocketMessageInfo) => {
      this.feed(client, value.message);
    });
    client.on('close', () => {
      this.detach(client);
    });
    client.on('error', (err: object) => {
      hilog.warn(0x0000, TAG, 'peer error: %{public}s', JSON.stringify(err));
      this.detach(client);
    });
  }

  private detach(client: socket.TCPSocketConnection): void {
    const idx = this.connections.indexOf(client);
    if (idx >= 0) this.connections.splice(idx, 1);
    this.buffers.delete(client);
  }

  private feed(client: socket.TCPSocketConnection, chunk: ArrayBuffer): void {
    const splitter = this.buffers.get(client);
    if (splitter === undefined) return;
    for (const line of splitter.push(chunk)) {
      this.dispatch(client, line);
    }
  }

  private dispatch(client: socket.TCPSocketConnection, line: string): void {
    let req: RpcRequest;
    try {
      req = JSON.parse(line) as RpcRequest;
    } catch (e) {
      hilog.error(0x0000, TAG, 'bad rpc frame: %{public}s', line);
      return;
    }
    const handler = this.handlers.get(req.method);
    if (handler === undefined) {
      const errResp: RpcResponse = { id: req.id, error: `unknown method: ${req.method}` };
      this.reply(client, errResp);
      return;
    }
    handler(req.method, req.params ?? null).then(
      (result: object | string | number | boolean | null) => {
        const okResp: RpcResponse = { id: req.id, result: result };
        this.reply(client, okResp);
      },
      (err: object) => {
        const errResp: RpcResponse = { id: req.id, error: JSON.stringify(err) };
        this.reply(client, errResp);
      }
    );
  }

  private reply(client: socket.TCPSocketConnection, resp: RpcResponse): void {
    client.send({ data: encodeFrame(resp) }).catch((e: object) => {
      hilog.warn(0x0000, TAG, 'reply send failed: %{public}s', JSON.stringify(e));
    });
  }
}
