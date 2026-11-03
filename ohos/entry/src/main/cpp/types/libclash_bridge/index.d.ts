/**
 * NAPI contract of libclash_bridge.so (see clash_bridge.cpp).
 * All strings crossing the boundary are UTF-8 JSON.
 */
export interface ClashBridge {
  /**
   * dlopen libclash_core.so, register C trampolines with the Go core
   * (registerCallbacks / setEventListener) and run handleInitClash
   * synchronously (initClashSync). Must be called once per process before
   * anything else.
   */
  initCore(homeDir: string): boolean;

  /**
   * Forward a JSON Action to the Go hub. The call itself is fire-and-forget;
   * the ActionResult JSON arrives later on the JS thread through the sink
   * registered with setEventSink, wrapped as
   * {"type":"actionResult","data":<resultJson>}. Correlate by the echoed
   * Action "id" (mirrors Dart's callbackCompleterMap).
   */
  invokeAction(actionJson: string): void;

  /** initClash + setState + setupConfig, run synchronously. Returns the legacy
   *  error string ('' = ok). */
  quickStart(initJson: string, paramsJson: string, stateJson: string): string;

  /** Attach the TUN device fd; returns false when the core rejects it. */
  startTun(fd: number): boolean;

  stopTun(): void;

  /** Tunnel start time in epoch ms, 0 when stopped. */
  getRunTime(): number;

  /** Serialized state.AndroidVpnOptions. */
  getAndroidVpnOptions(): string;

  getCurrentProfileName(): string;

  /** dnsJson: JSON array of DNS server strings. */
  updateDns(dnsJson: string): void;

  setState(stateJson: string): void;

  resetConnections(): void;

  /**
   * Ack a pending protect request. The Go dialer thread is blocked inside the
   * NAPI protect trampoline until this is called, so VpnConnection.protect()
   * is guaranteed to run while the socket is still open (pre-connect).
   */
  notifyProtected(fd: number): void;

  /** Graceful core shutdown (shutdown action, result ignored). */
  shutdownCore(): boolean;

  /**
   * Set the JS-side dispatcher. Receives string payloads on the JS thread:
   *  {"type":"actionResult","data":"<ActionResult JSON>"}
   *  {"type":"event","data":"<Go Message JSON>"}
   *  {"type":"protect","data":{"fd":<socket fd>}}
   */
  setEventSink(sink: (payload: string) => void): void;
}

export default clashBridge as ClashBridge;
