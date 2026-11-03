/**
 * Shared RPC protocol between the UI process (Flutter host) and the VPN
 * extension process. This is the OHOS counterpart of Android's AIDL
 * `com.wormhole.app.service` layer: the Go core and the TUN device both live
 * in the extension process, commands come in as newline-delimited JSON over
 * loopback TCP, and Go's async event stream is pushed back on the same wire.
 *
 * Wire format (one JSON object per line):
 *   request : {"id":"<rpcId>","method":"<name>","params":<any>}
 *   response: {"id":"<rpcId>","result":<any>} | {"id":"<rpcId>","error":"..."}
 *   push    : {"push":"event"|"crash"|"onStarted","data":<any>}
 */

import { util } from '@kit.ArkTS';

export const RPC_PORT = 47471;
export const RPC_HOST = '127.0.0.1';

/** MethodChannel name shared with lib/clash/lib.dart. */
export const CHANNEL_NAME = 'com.wormhole.app/service';

/** Want parameter / action constants for startVpnExtensionAbility. */
export const VPN_ABILITY_NAME = 'ClashVpnExtensionAbility';

export interface RpcRequest {
  id: string;
  method: string;
  params?: object | string | number | boolean | null;
}

export interface RpcResponse {
  id: string;
  result?: object | string | number | boolean | null;
  error?: string;
}

export interface RpcPush {
  push: string;
  data?: object | string;
}

/** Frame helpers -------------------------------------------------------- */

export function encodeFrame(obj: object): string {
  return JSON.stringify(obj) + '\n';
}

/** Splits an accumulated TCP buffer into complete lines, returning the rest. */
export interface ExtractResult {
  lines: string[];
  rest: string;
}

export function extractLines(buffer: string): ExtractResult {
  const lines: string[] = [];
  let rest = buffer;
  for (;;) {
    const idx = rest.indexOf('\n');
    if (idx < 0) break;
    const line = rest.substring(0, idx).trim();
    rest = rest.substring(idx + 1);
    if (line.length > 0) {
      lines.push(line);
    }
  }
  const result: ExtractResult = { lines: lines, rest: rest };
  return result;
}

/**
 * Byte-level line splitter for the loopback transport.
 *
 * Decoding must happen on **whole lines**, never on raw TCP chunks: a single
 * UTF-8 character (e.g. a 3-byte Chinese char, or a 4-byte emoji) can straddle
 * a segment boundary, and a per-chunk decoder silently turns the split bytes
 * into U+FFFD. That corruption used to mangle proxy names in the 46 KB
 * setupConfig payload, so mihomo could no longer match a proxy-group entry
 * against its proxy ("proxy group[0]: ... not found").
 *
 * Splitting on the 0x0A byte first guarantees every decoded slice is a complete
 * JSON frame, hence every character in it is complete too.
 */
export class ByteLineSplitter {
  private rest: Uint8Array = new Uint8Array(0);

  /** Feed one TCP chunk, get back every complete line it finished. */
  push(chunk: ArrayBuffer): string[] {
    const view = new Uint8Array(chunk);
    const total = this.rest.length + view.length;
    const buf = new Uint8Array(total);
    buf.set(this.rest, 0);
    buf.set(view, this.rest.length);

    const lines: string[] = [];
    let start = 0;
    for (let i = 0; i < total; i++) {
      if (buf[i] !== 0x0a) continue;
      if (i > start) {
        const text = decodeUtf8Bytes(buf.subarray(start, i)).trim();
        if (text.length > 0) lines.push(text);
      }
      start = i + 1;
    }
    // `slice` copies, so the tail does not pin the whole chunk in memory.
    this.rest = start >= total ? new Uint8Array(0) : buf.slice(start);
    return lines;
  }

  reset(): void {
    this.rest = new Uint8Array(0);
  }
}

function decodeUtf8Bytes(bytes: Uint8Array): string {
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeWithStream(bytes);
}
