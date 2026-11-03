// clash_bridge.cpp — NAPI bridge between ArkTS and the Go clash core
// (libclash_core.so, product of core/build_ohos.sh).
//
// The Go core was built with -buildmode=c-shared and exports the cgo surface
// declared in core/android_bride.go / core/lib_android.go / core/lib.go.
// On Android the host side registers JNI-flavoured trampolines; here the
// trampolines marshal payloads into NAPI threadsafe functions so callbacks
// fired from Go goroutines land on the JS thread.
//
// Protocol towards JS (single dispatcher, see setEventSink):
//   {"type":"actionResult","data":"<ActionResult JSON from Go>"}
//   {"type":"event","data":"<Go Message JSON>"}
//   {"type":"protect","data":{"fd":<socket fd>}}
// invokeAction/quickStart results are correlated by the Action "id" field on
// the ArkTS side (CoreBridge), mirroring Dart's callbackCompleterMap.

#include "napi/native_api.h"
#include "hilog/log.h"
#include <dlfcn.h>
#include <cstring>
#include <cstdlib>
#include <cerrno>
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <chrono>
#include <condition_variable>
#include <map>
#include <mutex>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "FlClashX-bridge"

// ---------------------------------------------------------------------------
// Go cgo export surface (must match the C declarations in core/*.go)
// ---------------------------------------------------------------------------
typedef void (*invoke_callback_func)(void *callback, const char *data);
typedef void (*event_listener_func)(void *listener, const char *data);
typedef void (*protect_func)(void *tun_interface, int fd);
typedef const char *(*resolve_process_func)(void *tun_interface, int protocol,
                                            const char *source, const char *target,
                                            int uid);
typedef void (*release_object_func)(void *obj);

static const char *kCoreLib = "libclash_core.so";

struct CoreApi {
  void *handle = nullptr;

  void (*registerCallbacks)(invoke_callback_func, event_listener_func,
                            protect_func, resolve_process_func,
                            release_object_func) = nullptr;
  void (*setEventListener)(void *listener) = nullptr;
  void (*invokeAction)(const char *params, void *callback) = nullptr;
  bool (*initClashSync)(int version, const char *homeDir) = nullptr;
  char *(*quickStartSync)(const char *initParams, const char *params,
                          const char *state) = nullptr;
  bool (*startTUN)(int fd, void *callback) = nullptr;
  void (*stopTun)() = nullptr;
  char *(*getRunTime)() = nullptr;
  char *(*getAndroidVpnOptions)() = nullptr;
  char *(*getCurrentProfileName)() = nullptr;
  void (*updateDns)(const char *s) = nullptr;
  void (*setState)(const char *s) = nullptr;
  void (*resetConnections)() = nullptr;
  void (*freeCString)(char *s) = nullptr;
};

static CoreApi g_api{};
static void *g_listenerToken = reinterpret_cast<void *>(0x1);
static void *g_tunToken = reinterpret_cast<void *>(0x2);
// Go's invokeCallback drops the delivery when the callback pointer is nil,
// so every async action must carry this non-nil sentinel.
static void *g_actionToken = reinterpret_cast<void *>(0x3);

// ---------------------------------------------------------------------------
// JS dispatcher (threadsafe)
// ---------------------------------------------------------------------------
static napi_threadsafe_function g_dispatcher = nullptr;

// Trampolines ----------------------------------------------------------------
static void TrampInvokeCallback(void *callback, const char *data) {
  // Action results are delivered through the same dispatcher; the "data"
  // wrapper carries the raw Go ActionResult JSON, and the ArkTS side correlates
  // by the echoed Action id.
  (void)callback;
  if (g_dispatcher == nullptr || data == nullptr) return;
  std::string payload = "{\"type\":\"actionResult\",\"data\":";
  // data is already a JSON string (ActionResult JSON). Embed verbatim.
  payload += data;
  payload += "}";
  char *dup = strdup(payload.c_str());
  if (napi_call_threadsafe_function(g_dispatcher, dup, napi_tsfn_nonblocking) != napi_ok) {
    free(dup);
  }
}

static void TrampEventListener(void *listener, const char *data) {
  (void)listener;
  if (g_dispatcher == nullptr || data == nullptr) return;
  std::string payload = "{\"type\":\"event\",\"data\":";
  payload += data;
  payload += "}";
  char *dup = strdup(payload.c_str());
  if (napi_call_threadsafe_function(g_dispatcher, dup, napi_tsfn_nonblocking) != napi_ok) {
    free(dup);
  }
}

// --- Synchronous protect handshake -----------------------------------------
// mihomo calls the protect hook from the socket-control callback, i.e. right
// after socket() and BEFORE connect(). The JS-side VpnConnection.protect() is
// promise-based, so a fire-and-forget dispatch always lost the race: by the
// time ArkTS ran, the dial had already been captured by our own TUN, rejected
// by mihomo's loop detector and the socket closed — protect then failed with
// 2203004 "Invalid socket file descriptor" (netd logged EBADF sending the fd).
// So block the calling Go thread until ArkTS acks, like Android's synchronous
// JNI VpnService.protect().
static std::mutex g_protectMx;
static std::condition_variable g_protectCv;
static std::map<int, int> g_protectPending;  // fd -> 0 pending / 1 acked
static const int kProtectTimeoutMs = 1500;

static void TrampProtect(void *tunInterface, int fd) {
  (void)tunInterface;
  if (g_dispatcher == nullptr) return;
  {
    std::lock_guard<std::mutex> lk(g_protectMx);
    g_protectPending[fd] = 0;
  }
  std::string payload = "{\"type\":\"protect\",\"data\":{\"fd\":" + std::to_string(fd) + "}}";
  char *dup = strdup(payload.c_str());
  if (napi_call_threadsafe_function(g_dispatcher, dup, napi_tsfn_nonblocking) != napi_ok) {
    free(dup);
    std::lock_guard<std::mutex> lk(g_protectMx);
    g_protectPending.erase(fd);
    return;
  }

  std::unique_lock<std::mutex> lk(g_protectMx);
  bool acked = g_protectCv.wait_for(
      lk, std::chrono::milliseconds(kProtectTimeoutMs), [fd] {
        auto it = g_protectPending.find(fd);
        return it == g_protectPending.end() || it->second == 1;
      });
  g_protectPending.erase(fd);
  if (!acked) {
    OH_LOG_WARN(LOG_APP, "protect fd %{public}d not acked in %{public}dms", fd,
                kProtectTimeoutMs);
  }
}

// Called from ArkTS once VpnConnection.protect(fd) has settled.
static napi_value NotifyProtected(napi_env env, napi_callback_info info) {
  (void)env;
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  int fd = 0;
  if (argc >= 1) napi_get_value_int32(env, argv[0], &fd);
  {
    std::lock_guard<std::mutex> lk(g_protectMx);
    auto it = g_protectPending.find(fd);
    if (it != g_protectPending.end()) it->second = 1;
  }
  g_protectCv.notify_all();
  return nullptr;
}

static const char *TrampResolveProcess(void *tunInterface, int protocol,
                                       const char *source, const char *target,
                                       int uid) {
  // v1: no per-app process attribution on OHOS.
  (void)tunInterface; (void)protocol; (void)source; (void)target; (void)uid;
  return nullptr;
}

static void TrampReleaseObject(void *obj) { (void)obj; }

// Dispatcher plumbing ---------------------------------------------------------
// The payload handed to napi_call_threadsafe_function is the strdup'ed JSON
// string itself (a plain char*), NOT a wrapper struct. Treating it as a struct
// dereferences the first 8 characters of the JSON as a pointer ("{\"type\":" ->
// 0x3a2265707974227b) and segfaults inside napi_create_string_utf8's strlen.
static void CallDispatcher(napi_env env, napi_value jsCallback, void *context,
                           void *data) {
  (void)context;
  char *json = static_cast<char *>(data);
  if (json == nullptr) return;
  napi_value str = nullptr;
  napi_value result = nullptr;
  if (napi_create_string_utf8(env, json, NAPI_AUTO_LENGTH, &str) == napi_ok) {
    if (napi_call_function(env, jsCallback, jsCallback, 1, &str, &result) != napi_ok) {
      OH_LOG_ERROR(LOG_APP, "dispatcher call failed");
    }
  } else {
    OH_LOG_ERROR(LOG_APP, "dispatcher create_string failed");
  }
  free(json);
}

static void FinalizeDispatcher(napi_env env, void *data, void *hint) {
  (void)env; (void)data; (void)hint;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static napi_value ToNapiString(napi_env env, const std::string &s) {
  napi_value out = nullptr;
  napi_create_string_utf8(env, s.c_str(), s.length(), &out);
  return out;
}

static std::string FromNapiString(napi_env env, napi_value value) {
  size_t len = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
    return std::string();
  }
  // Reserve room for the terminator: napi writes up to bufsize bytes including
  // the trailing NUL, so a buffer of exactly `len` would be written one byte
  // past its end.
  std::string out(len + 1, '\0');
  size_t copied = 0;
  if (napi_get_value_string_utf8(env, value, out.data(), out.size(), &copied) != napi_ok) {
    return std::string();
  }
  out.resize(copied);
  return out;
}

static void *Resolve(const char *name) {
  void *sym = dlsym(g_api.handle, name);
  if (sym == nullptr) {
    OH_LOG_ERROR(LOG_APP, "dlsym %{public}s failed: %{public}s", name, dlerror());
  }
  return sym;
}

static bool LoadCore() {
  if (g_api.handle != nullptr) return true;
  g_api.handle = dlopen(kCoreLib, RTLD_NOW | RTLD_GLOBAL);
  if (g_api.handle == nullptr) {
    OH_LOG_ERROR(LOG_APP, "dlopen %{public}s failed: %{public}s", kCoreLib, dlerror());
    return false;
  }
  g_api.registerCallbacks =
      reinterpret_cast<void (*)(invoke_callback_func, event_listener_func,
                                protect_func, resolve_process_func,
                                release_object_func)>(Resolve("registerCallbacks"));
  g_api.setEventListener = reinterpret_cast<void (*)(void *)>(Resolve("setEventListener"));
  g_api.invokeAction = reinterpret_cast<void (*)(const char *, void *)>(Resolve("invokeAction"));
  g_api.initClashSync = reinterpret_cast<bool (*)(int, const char *)>(Resolve("initClashSync"));
  g_api.quickStartSync = reinterpret_cast<char *(*)(const char *, const char *, const char *)>(Resolve("quickStartSync"));
  g_api.startTUN = reinterpret_cast<bool (*)(int, void *)>(Resolve("startTUN"));
  g_api.stopTun = reinterpret_cast<void (*)()>(Resolve("stopTun"));
  g_api.getRunTime = reinterpret_cast<char *(*)()>(Resolve("getRunTime"));
  g_api.getAndroidVpnOptions = reinterpret_cast<char *(*)()>(Resolve("getAndroidVpnOptions"));
  g_api.getCurrentProfileName = reinterpret_cast<char *(*)()>(Resolve("getCurrentProfileName"));
  g_api.updateDns = reinterpret_cast<void (*)(const char *)>(Resolve("updateDns"));
  g_api.setState = reinterpret_cast<void (*)(const char *)>(Resolve("setState"));
  g_api.resetConnections = reinterpret_cast<void (*)()>(Resolve("resetConnections"));
  g_api.freeCString = reinterpret_cast<void (*)(char *)>(Resolve("freeCString"));

  if (g_api.invokeAction == nullptr || g_api.startTUN == nullptr ||
      g_api.registerCallbacks == nullptr || g_api.freeCString == nullptr) {
    dlclose(g_api.handle);
    g_api.handle = nullptr;
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// NAPI exports
// ---------------------------------------------------------------------------
// mihomo's log package writes to os.Stdout, which on OHOS is normally
// discarded — so every "startTUN error:" and "[Setup]" line was invisible and
// TUN bring-up failures could only be guessed at. Redirect the extension
// process' stdout/stderr (fd 1/2) into <home>/logs/core.log before the Go core
// is initialised; writes are unbuffered, so the file is always current.
static void RedirectStdioToFile(const std::string &homeDir) {
  if (homeDir.empty()) return;
  std::string dir = homeDir + "/logs";
  mkdir(dir.c_str(), 0777);
  std::string path = dir + "/core.log";
  int fd = open(path.c_str(), O_CREAT | O_WRONLY | O_APPEND, 0666);
  if (fd < 0) {
    OH_LOG_ERROR(LOG_APP, "cannot open core.log: %{public}d", errno);
    return;
  }
  dup2(fd, STDOUT_FILENO);
  dup2(fd, STDERR_FILENO);
  if (fd > STDERR_FILENO) close(fd);
  OH_LOG_INFO(LOG_APP, "core stdio -> %{public}s", path.c_str());
}

static napi_value InitCore(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  std::string homeDir = argc >= 1 ? FromNapiString(env, argv[0]) : "";

  RedirectStdioToFile(homeDir);
  if (!LoadCore()) return nullptr;

  g_api.registerCallbacks(TrampInvokeCallback, TrampEventListener, TrampProtect,
                          TrampResolveProcess, TrampReleaseObject);
  // Non-nil listener token enables Go's emitEvent path; payloads flow through
  // TrampEventListener into the dispatcher.
  g_api.setEventListener(g_listenerToken);

  // handleInitClash only sets package-level state — run it synchronously.
  bool ok = g_api.initClashSync != nullptr &&
            g_api.initClashSync(29, homeDir.c_str());

  napi_value out = nullptr;
  napi_get_boolean(env, ok, &out);
  return out;
}

static napi_value InvokeAction(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 1 || g_api.invokeAction == nullptr) return nullptr;
  std::string json = FromNapiString(env, argv[0]);
  char *p = strdup(json.c_str());
  // Result arrives via TrampInvokeCallback -> dispatcher as an actionResult
  // payload; CoreBridge.ets correlates by the echoed Action id.
  g_api.invokeAction(p, g_actionToken);
  free(p);
  return nullptr;
}

static napi_value QuickStart(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 3 || g_api.quickStartSync == nullptr) return nullptr;
  std::string init = FromNapiString(env, argv[0]);
  std::string params = FromNapiString(env, argv[1]);
  std::string state = FromNapiString(env, argv[2]);
  // Synchronous (see quickStartSync in core/lib_android.go): runs
  // initClash + setState + setupConfig inline. setupConfig is the slow part;
  // callers offload to a taskpool worker when needed.
  char *res = g_api.quickStartSync(init.c_str(), params.c_str(), state.c_str());
  std::string s = res != nullptr ? res : "";
  if (res != nullptr) g_api.freeCString(res);
  return ToNapiString(env, s);
}

static napi_value StartTun(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  int fd = 0;
  if (argc >= 1) napi_get_value_int32(env, argv[0], &fd);
  bool ok = g_api.startTUN != nullptr && g_api.startTUN(fd, g_tunToken);
  napi_value out = nullptr;
  napi_get_boolean(env, ok, &out);
  return out;
}

static napi_value StopTun(napi_env env, napi_callback_info info) {
  (void)info;
  if (g_api.stopTun != nullptr) g_api.stopTun();
  return nullptr;
}

static napi_value GetRunTime(napi_env env, napi_callback_info info) {
  (void)info;
  long ms = 0;
  if (g_api.getRunTime != nullptr) {
    char *s = g_api.getRunTime();
    if (s != nullptr) {
      ms = atol(s);
      g_api.freeCString(s);
    }
  }
  napi_value out = nullptr;
  napi_create_int64(env, ms, &out);
  return out;
}

static napi_value GetAndroidVpnOptions(napi_env env, napi_callback_info info) {
  (void)info;
  std::string s;
  if (g_api.getAndroidVpnOptions != nullptr) {
    char *raw = g_api.getAndroidVpnOptions();
    if (raw != nullptr) {
      s = raw;
      g_api.freeCString(raw);
    }
  }
  return ToNapiString(env, s);
}

static napi_value GetCurrentProfileName(napi_env env, napi_callback_info info) {
  (void)info;
  std::string s;
  if (g_api.getCurrentProfileName != nullptr) {
    char *raw = g_api.getCurrentProfileName();
    if (raw != nullptr) {
      s = raw;
      g_api.freeCString(raw);
    }
  }
  return ToNapiString(env, s);
}

static napi_value UpdateDns(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc >= 1 && g_api.updateDns != nullptr) {
    std::string v = FromNapiString(env, argv[0]);
    char *p = strdup(v.c_str());
    g_api.updateDns(p);
    free(p);
  }
  return nullptr;
}

static napi_value SetState(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc >= 1 && g_api.setState != nullptr) {
    std::string v = FromNapiString(env, argv[0]);
    char *p = strdup(v.c_str());
    g_api.setState(p);
    free(p);
  }
  return nullptr;
}

static napi_value ResetConnections(napi_env env, napi_callback_info info) {
  (void)info;
  if (g_api.resetConnections != nullptr) g_api.resetConnections();
  return nullptr;
}

static napi_value ShutdownCore(napi_env env, napi_callback_info info) {
  (void)info;
  if (g_api.handle == nullptr) return nullptr;
  // Fire the shutdown action; result is ignored (Dart destroy() does the same).
  if (g_api.invokeAction != nullptr) {
    const char *action = "{\"id\":\"__core_shutdown\",\"method\":\"shutdown\"}";
    g_api.invokeAction(action, g_actionToken);
  }
  napi_value out = nullptr;
  napi_get_boolean(env, true, &out);
  return out;
}

static napi_value SetEventSink(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc < 1) return nullptr;

  napi_value resource = nullptr;
  napi_create_string_utf8(env, "clashDispatcher", NAPI_AUTO_LENGTH, &resource);
  if (g_dispatcher != nullptr) {
    napi_release_threadsafe_function(g_dispatcher, napi_tsfn_abort);
    g_dispatcher = nullptr;
  }
  napi_create_threadsafe_function(env, argv[0], nullptr, resource, 0, 4,
                                  nullptr, nullptr, nullptr, CallDispatcher,
                                  &g_dispatcher);
  napi_value out = nullptr;
  napi_get_boolean(env, g_dispatcher != nullptr, &out);
  return out;
}

// ---------------------------------------------------------------------------
// Module registration
// ---------------------------------------------------------------------------
EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"initCore", nullptr, InitCore, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"invokeAction", nullptr, InvokeAction, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"quickStart", nullptr, QuickStart, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"startTun", nullptr, StartTun, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stopTun", nullptr, StopTun, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"getRunTime", nullptr, GetRunTime, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"getAndroidVpnOptions", nullptr, GetAndroidVpnOptions, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"getCurrentProfileName", nullptr, GetCurrentProfileName, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"updateDns", nullptr, UpdateDns, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setState", nullptr, SetState, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"resetConnections", nullptr, ResetConnections, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"shutdownCore", nullptr, ShutdownCore, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"notifyProtected", nullptr, NotifyProtected, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setEventSink", nullptr, SetEventSink, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module clashBridgeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "clash_bridge",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterClashBridgeModule(void) {
  napi_module_register(&clashBridgeModule);
}
