# FlClashX — HarmonyOS（鸿蒙）版本

基于 Flutter-OHOS（OpenHarmony SIG 的 Flutter 适配版）的混合架构移植版，最大化复用
`lib/` 下的全部 Dart 代码与 `core/` 的 Go (mihomo) 内核。

## 1. 架构总览（Android → OHOS 对应关系）

| Android | HarmonyOS | 说明 |
| --- | --- | --- |
| `:remote` 进程（AIDL 服务） | `ClashVpnExtensionAbility`（`type: "vpn"` 扩展进程） | Go 内核 + TUN 都住在该进程 |
| VpnService TUN fd | `vpnExtension.createVpnConnection().create(config)` 返回 fd | API 11+，`@ohos.net.vpnExtension` |
| Protect JNI 回调 | `connection.protect(fd)`（经 NAPI 事件转发） | 内核出站 socket 免绕行 |
| AIDL 双向通道 | 回环 TCP JSON-RPC（127.0.0.1:47471，换行分帧） | `ClashRpcServer` / `ClashRpcClient` |
| `MethodChannel('com.follow.clashx/service')` | 同名 MethodChannel，协议 1:1 保持 | Dart 侧 `ClashLib` 无需改动协议 |
| gomobile + JNI 回调 | c-shared `libclash_core.so` + NAPI trampoline | C 函数指针回调架构与 Android 共用（`core/android_bride.go` 构建标签已扩为 `android \|\| ohos`） |

```
Flutter (lib/) ──MethodChannel──> EntryAbility (UI 进程)
                                     │ ClashServiceChannel
                                     │ ClashRpcClient (回环 TCP)
                                     ▼
                        ClashVpnExtensionAbility (扩展进程)
                          ├─ ClashRpcServer
                          ├─ CoreBridge ──NAPI──> libclash_bridge.so ──dlopen──> libclash_core.so (mihomo)
                          └─ VpnConnection (TUN fd → CoreBridge.startTun)
```

## 2. 环境搭建

1. **DevEco Studio 5.0+**（含 HarmonyOS SDK，勾选 Native/C++ 组件）。
2. **Flutter-OH SDK**（不要用官方 Flutter，勿执行 `flutter upgrade`）：

   ```bash
   git clone https://gitee.com/openharmony-sig/flutter_flutter.git
   # 推荐 3.22.4-ohos 或 3.27.4-ohos 稳定分支
   cd flutter_flutter && git checkout 3.22.4-ohos && cd ..
   export PATH="$PWD/flutter_flutter/bin:$PATH"
   export TOOL_HOME=/path/to/DevEco-Studio/content  # DevEco 安装目录
   export DEVECO_SDK_HOME=$TOOL_HOME/sdk
   export PUB_HOSTED_URL=https://pub.flutter-io.cn
   export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
   flutter doctor   # 应识别到 ohos toolchain
   ```

3. **鸿蒙 Go 工具链**（`go tool dist list` 须包含 `openharmony/arm64`，
   见 gitee `openharmony-sig` 社区工具链或 Go 1.26+ 内置支持）。
4. 首次生成/合并工程骨架（Flutter-OH 生成 `har/` 与插件注册器）：

   ```bash
   # 在临时目录生成，再把 ohos/entry/har/、GeneratedPluginRegistrant.ets
   # 及生成版 build-profile.json5 的签名配置段合并进本仓库 ohos/ 目录
   flutter create --platforms ohos /tmp/ohos_scaffold
   ```

## 3. 构建步骤

```bash
# ① Go 内核 → ohos/entry/libs/arm64-v8a/libclash_core.so
cd core
OHOS_GO=/path/to/ohos-go/bin/go OHOS_NDK=/path/to/sdk/default/openharmony/native \
  ./build_ohos.sh

# ② HAP
cd ..
flutter pub get
flutter build hap --target-platform ohos-arm64 --release
# 或纯 hvigor：cd ohos && hvigorw assembleHap
```

## 4. Dart 三方插件适配

`pubspec.yaml` 的插件分四类处理：

**① 已有 OpenHarmony 适配分支**（gitcode `openharmony-tpc/flutter_packages`，
分支名以仓库实际 `br_*` 分支为准）。建议在鸿蒙开发分支中加
`dependency_overrides`（已确认存在的三个写明，其余按仓库列表核对）：

```yaml
dependency_overrides:
  path_provider:
    git:
      url: "https://gitcode.com/openharmony-tpc/flutter_packages.git"
      path: "packages/path_provider/path_provider"
      ref: "br_path_provider-v2.1.5_ohos"
  shared_preferences:
    git:
      url: "https://gitcode.com/openharmony-tpc/flutter_packages.git"
      path: "packages/shared_preferences/shared_preferences"
      ref: "br_shared_preferences-v2.5.4_ohos"
  url_launcher:
    git:
      url: "https://gitcode.com/openharmony-tpc/flutter_packages.git"
      path: "packages/url_launcher/url_launcher"
      ref: "br_url_launcher-v6.3.2_ohos"
```

同仓库通常还覆盖：`package_info_plus`、`device_info_plus`、`connectivity_plus`、
`network_info_plus`、`image_picker`、`webview_flutter`、`file_picker` 等，
适配清单见 openharmony-sig 的 docs（三方库兼容性列表，已收录 260+）。

**② 纯 Dart，无需改动**：`dio`、`http`、`shelf*`、`archive`、`crypto`、
`qr_flutter`、`webdav_client`、`lpinyin`、`emoji_regex`、`collection`、
`animations`、`freezed_annotation`、`json_annotation`、`flutter_riverpod*`、
`flutter_svg`、`re_editor`、`re_highlight`、`dynamic_color`、`intl` 等。

**③ 桌面专用，OHOS 上为 no-op**（调用点已按平台 gate，保持原依赖即可编译）：
`window_manager`、`desktop_multi_window`、`tray_manager`、`hotkey_manager`、
`launch_at_startup`、`screen_retriever`、`win32`、`win32_registry`、
`window_ext`、`uni_platform`、`flutter_displaymode`。

**④ 风险项（需验证或补实现）**：
- `flutter_js`：JS 引擎依赖原生实现，OHOS 侧需适配或改用纯 Dart JS 解释器。
- `mobile_scanner`：相机扫码，可用 OHOS Scan Kit 或 `image_picker` ohos 分支替代。
- `app_links`：深度链接改用 OHOS App Linking / want 隐式跳转。
- `defer_pointer`、`flutter_cache_manager`、`cached_network_image`：纯 Dart 居多，
  预计可直接编译，需真机回归。

## 5. 签名与权限

`module.json5` 已声明：`INTERNET`、`GET_NETWORK_INFO`、
`ACCESS_EXTENSIONAL_DEVICE_DRIVER`（**受限 ACL 权限**）、
`KEEP_BACKGROUND_RUNNING`、`NOTIFICATION_CONTROLLER`。

受限权限需在签名 Profile（`acls` → `allowed-acls`）中额外声明，且上架
AppGallery 时需向华为申请该 ACL 权限；本地调试可用 DevEco 自动签名 +
手工编辑 Profile 的 `allowed-acls` 数组。`type: "vpn"` 枚举若在旧版 SDK 的
module 校验器中报红，按华为论坛指引更新 `toolchains/modulecheck/module.json`。

首次 `vpnConnection.create()` 时系统弹出 VPN 授权对话框（对应 Android 的
`VpnService.prepare()`）。

## 6. 已知限制（v1）

- 分应用进程归属显示（`ResolveProcess`）未实现，返回空；分应用代理经由
  `VpnConfig.trusted/blockedApplications` 生效，语义与 Android accessControl 对齐。
- 快捷磁贴 / 桌面小组件 / TV 适配 / 系统代理（桌面语义）不在本版范围。
- 通知为常驻任务基础样式（标题 + 运行中），无停止按钮（停止走 UI）。
- `flutter_js` 等④类插件可能阻塞完整功能；见第 4 节。
- `:remote` 崩溃重启语义通过 RPC 断连 → `crash` 推送实现，与 Dart 侧
  `ClashLib._handleCrashRestart` 的 5 次退避预算兼容。

## 7. 目录说明

```
ohos/
├── AppScope/                     # 应用级配置与图标
├── build_profile.json5           # 工程级构建配置（签名段由 DevEco 生成）
├── entry/
│   ├── libs/arm64-v8a/           # core/build_ohos.sh 产物 libclash_core.so 放这里
│   └── src/main/
│       ├── module.json5          # 权限 + EntryAbility + VPN 扩展声明
│       ├── ets/entryability/     # Flutter 宿主（注册 MethodChannel）
│       ├── ets/services/         # CoreBridge / RPC 服务器与客户端 / Channel
│       ├── ets/vpn/              # ClashVpnExtensionAbility（内核 + TUN 宿主）
│       └── cpp/                  # NAPI 桥接（dlopen Go core + 线程安全回调）
core/build_ohos.sh                # Go 内核 openharmony/arm64 交叉编译脚本
```

## 8. 待验证清单（拿到设备/环境后）

1. `flutter build hap` 通过（插件④类按第 4 节处理）。
2. ✅ `core/build_ohos.sh` 已在 `GOOS=openharmony/arm64` 下验证通过，产物
   `libclash_core.so`（AArch64 共享库，含 `registerCallbacks` 等导出 C API）可被
   NAPI `dlopen`。mihomo 依赖链**无需**给 sing-tun 等打 ohos 构建标签补丁；仅把
   `cmfa` 专属的 DNS patch 改为按平台分发（`core/dns_android.go` /
   `core/dns_openharmony.go`），OHOS 构建不再需要 `-tags cmfa`。
3. 回环 RPC 启动时序：`startAbility` → `onCreate` → server ready → 首个 `init`。
4. VPN 授权对话框 → `create` fd → `startTun` → TUN 联通。
5. `protect` 路径（内核出站 socket 免绕行）在真实订阅下无环路。
