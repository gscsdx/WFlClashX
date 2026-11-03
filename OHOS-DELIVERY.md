# Wormhole 鸿蒙版（OHOS）

>  ｜ 包名：com.wormhole.app ｜ 真机：华为 (HarmonyOS 5.x)
>
> 本文档覆盖从「应用可运行」到「VPN 全链路可用」的三项攻坚成果：**TUN TCP 链路打通**、**后台保活（锁屏存活）**、**构建链修复**。目标读者：接手本项目的工程师。

---

## 1. 当前能力状态

| 能力 | 状态 | 验证方式 |
|---|---|---|
| 应用运行（Flutter UI + Go mihomo 内核） | ✅ | 真机启动、订阅导入、仪表盘 |
| TUN 隧道建立（VPN 授权、tun fd 传递） | ✅ | `ifconfig vpn-tun` UP |
| **TCP 全链路**（应用 → TUN → gVisor → mihomo → 节点 → 外网） | ✅ | 浏览器实测 baidu(DIRECT)/google(🇸🇬节点) 完整渲染 |
| UDP（DNS/QUIC） | ✅ | DNS 解析、QUIC 走 GeoIP 规则 |
| **后台保活（锁屏存活）** | ✅ | 锁屏 10 分钟实测：双进程存活、流量持续 |
| hvigor-only 构建链 | ✅ | `rebuild_hvigor.bat` EXIT_CODE=0 |
| Flutter 全量构建链 | ⚠️ | hvigor-only 兜底稳定；全量链（pub/ohpm）见 §7 |
| 上架（AppGallery） | ⏳ | ACL 权限申请未启动，见 §7 |

---

## 2. 进程与保活架构

```
┌─ 主进程 com.follow.clashx (UI) ──────────────────────────┐
│  EntryAbility (FlutterAbility)                            │
│   ├─ Flutter Engine / Dart (ClashLib)                     │
│   ├─ ClashServiceChannel  ← MethodChannel: Dart ⇄ ArkTS   │
│   │    ├─ start 成功(fd>0) → KeepAliveManager.enable()    │
│   │    ├─ stop/shutdown    → KeepAliveManager.disable()   │
│   │    └─ updateNotificationParams → 同步标题              │
│   └─ KeepAliveManager ★长时任务持有者（仅 UIAbility 可申请）│
│        startBackgroundRunning(context, ['dataTransfer'],  │
│                                wantAgent→EntryAbility)    │
│        + 每 60s 实况窗进度通知（防 10 分钟回收）            │
└──────────────────┬────────────────────────────────────────┘
                   │ loopback JSON-RPC (ClashRpcClient ⇄ Server)
┌─ 扩展进程 com.follow.clashx:vpn ──────────────────────────┐
│  ClashVpnExtensionAbility (VpnExtensionAbility)           │
│   ├─ CoreBridge (NAPI → Go mihomo core)                   │
│   ├─ vpnConnection.create() → tun fd → CoreBridge.startTun│
│   ├─ ClashRpcServer (事件推送/protect 回路)                │
│   └─ 普通状态通知（需用户开通知权限）                       │
└───────────────────────────────────────────────────────────┘
```

**设计要点**：系统只允许 UIAbility 申请长时任务（扩展进程调用返回 401），因此长时任务由主进程持有；VPN 扩展进程靠主进程任务 + 系统对活跃 TUN 的策略存活。

---

## 3. 变更清单

### 3.1 TUN TCP 链路（gVisor 适配层）

| 文件 | 变更 |
|---|---|
| `core/tun/tun.go` | 无条件强制 `constant.TunGvisor`（运行时 `runtime.GOOS`≠"openharmony"，自动选栈会落到 mixed→TCP 必死）；MTU 夹紧至 1420；日志级别仅在 SILENT 时提升为 INFO |
| `core/third_party/sing-tun/`（新增 vendored fork） | `go.mod` 加 `replace github.com/metacubex/sing-tun => ./third_party/sing-tun` |
| `core/third_party/sing-tun/tun_linux_gvisor.go` | **核心修复**：gVisor `fdbased` 端点因 OHOS 对 VpnService fd `fstat()` 返回 EACCES(13) 而无法创建 → 改用纯用户态 `channel.New(1024, mtu, "")` + 自写 `pumpChannelEndpoint` 双向搬运；`rawRead/rawWrite` 用 `unix.Read/Write + unix.Poll`（os.File 因 fstat 失败进不了 netpoller）；outbound 循环用 `ReadContext`，nil ≠ 关闭（channel.Read 是非阻塞 select，队列空也返回 nil），退出仅由 `pumpStop`/ctx 触发 |
| `core/third_party/sing-tun/tun_linux.go` | `NativeTun` 增加 `pumpStop chan struct{}`，`Close()` 中关闭 |
| `core/hub.go` | `uiActive` 日志门控保持原样（调试期临时禁用已还原） |
| `core/lib_mobile.go` | `handleStartTun` 内自动 `handleStartLog()`（Dart 从不调用，导致日志流全空的真实 bug，保留） |

### 3.2 后台保活

| 文件 | 变更 |
|---|---|
| `ohos/entry/src/main/ets/services/KeepAliveManager.ets` | **新增**：主进程长时任务单例（enable/disable/60s 实况窗通知） |
| `ohos/entry/src/main/ets/services/ClashServiceChannel.ets` | `start`(fd>0)→enable；`stop`/`shutdown`→disable；`updateNotificationParams` 同步标题 |
| `ohos/entry/src/main/ets/vpn/ClashVpnExtensionAbility.ets` | 移除扩展侧 `startBackgroundRunning`（401 无效调用）；保留普通状态通知 |
| `ohos/entry/src/main/module.json5` | `backgroundModes: ["dataTransfer"]` 移至 `abilities[EntryAbility]`（**API 12 schema 不允许配在 extensionAbilities**，那是 API 15+ 标签；官方 VPN 示例即配在 UIAbility） |
| `ohos/entry/src/main/cpp/clash_bridge.cpp` | 删除调试用 `ProbeTunFd` |

### 3.3 构建链

| 文件/环境 | 变更 |
|---|---|
| `rebuild_hvigor.bat` | `cd` 改到 `D:\Desktop\WFlClashX\ohos`（原指向 WorkBuddy C 盘镜像——镜像不完整且 pub-cache 相对路径解析错误）；PATH 增加 `%JAVA_HOME%\bin`（PackageHap `spawn java ENOENT`） |
| `C:\Users\Administrator\.ohos\config\material\` | 清理混写的旧批签名材料（每子目录须恰好 1 个文件；备份在 `_diag/material-backup-20261103/`） |

---

## 4. 根因速查（踩坑记录）

| 症状 | 根因 | 修复 |
|---|---|---|
| TCP 全断（浏览器 SYN_SENT 黑洞） | 三层叠加：栈选错(mixed) + fdbased 端点 fstat EACCES + MTU 9000 超接口 | 强制 gVisor + channel 端点 + MTU 1420（§3.1） |
| 注入成功但零回包（queued 涨到 174） | `channel.Endpoint.Read()` 是非阻塞 select，队列空即 nil，被误判为已关闭→outbound 启动即退出 | `ReadContext` + `pumpStop`（§3.1） |
| 保活失败 16000151 | ① 废弃字段 `operationType/wantAgentFlags` → wantAgent 无效；② HAP 里根本没有 backgroundModes（API 12 schema 拒绝 extensionAbilities 配置，旧构建用了镜像里的旧文件） | `actionType/actionFlags` + backgroundModes 移至 EntryAbility |
| 保活失败 401 | 系统只允许 UIAbility 申请长时任务，扩展进程调用必拒 | 主进程 KeepAliveManager（§2/§3.2） |
| 锁屏 ~10 分钟 VPN 断 | DATA_TRANSFER 长时任务要求「进度更新 + 真实流量」，否则系统回收 | 每 60s 实况窗进度通知（官方 VPN 方案，论坛帖 0204188825713661027） |
| 构建 00303149 / pub-cache 路径错误 | bat 的 cd 指向 C 盘 WorkBuddy 镜像 | cd 到 D 盘真实工程 |
| PackageHap `spawn java ENOENT` | PATH 缺 JBR | PATH 加 `%JAVA_HOME%\bin` |
| SignHap "Signing material error" | DevEco 两次自动签名的材料混写（hvigor 要求 material 每目录恰好 1 文件） | 删旧批（有备份）；再遇此错先查 `material/{fd/0,fd/1,fd/2,ac,ce}` 文件数 |
| 扩展通知 1600004 | 应用通知权限被用户关闭 | 系统设置 → 通知 → FlClashX 开启（不影响保活） |

---

## 5. 构建与部署手册

环境：DevEco/SDK 在 `D:\HarmonyOS\DevEco`，OHOS Go 工具链 `D:\HarmonyOS\ohos_golang`，hdc 在 `D:\HarmonyOS\DevEco\sdk\default\openharmony\toolchains`。

### 5.1 仅改 Go 内核（.so）

```bash
cd /d/Desktop/WFlClashX/core
OHOS_GO=/d/HarmonyOS/ohos_golang/bin/go \
OHOS_NDK=/d/HarmonyOS/DevEco/sdk/default/openharmony/native bash build_ohos.sh
# 改了 .so 必须清 native 缓存再打包：
rm -rf ../ohos/entry/build/default/intermediates/{stripped_native_libs,libs}
# 然后走 5.3
```

### 5.2 仅改 ArkTS/配置

直接走 5.3。

### 5.3 打 HAP + 装机

```powershell
D:\Desktop\WFlClashX\rebuild_hvigor.bat        # 产物 build_hap.log，EXIT_CODE=0 为成功
```
```bash
export PATH=$PATH:/d/HarmonyOS/DevEco/sdk/default/openharmony/toolchains
cd /d/Desktop/WFlClashX
MSYS_NO_PATHCONV=1 hdc install -r ohos/entry/build/default/outputs/default/entry-default-signed.hap
MSYS_NO_PATHCONV=1 hdc shell "aa force-stop com.follow.clashx; aa start -b com.follow.clashx -a EntryAbility"
# UI 点连接 (660,2380)；浏览器验证：
MSYS_NO_PATHCONV=1 hdc shell "aa start -U 'https://www.google.com/search?q=test'"  # 可能弹选择打开方式 (400,1690)
```

### 5.4 健康检查

```bash
MSYS_NO_PATHCONV=1 hdc shell "ifconfig vpn-tun | head -2"         # 隧道存在 + RX/TX 增长
MSYS_NO_PATHCONV=1 hdc shell "hilog -x | grep FlClashX-KeepAlive" # "continuous task started id=N"
MSYS_NO_PATHCONV=1 hdc shell "hilog -x | grep onContinuousTaskStart"  # 系统确认接管
MSYS_NO_PATHCONV=1 hdc shell "ps -ef | grep clashx"               # 主进程 + :vpn 扩展进程
```

---

## 6. 验证记录

### TCP 链路
- baidu.com 完整渲染（DIRECT 规则）；google.com/search 完整渲染
- REST /connections：24 条连接、7 条 TCP 全有真实数据；`www.google.com:443` down=40,135 B

### 后台保活，锁屏 10 分钟）

| 时点 | 主进程 | 扩展进程 | vpn-tun RX |
|---|---|---|---|
| 锁屏 | pid 43804 ✓ | pid 43931 ✓ | 300 |
| T+2min | ✓ | ✓ | 300 |
| T+6min | ✓ | ✓ | 699 |
| T+10min | ✓ | ✓ | 1756 |

唤醒后连接计时持续（00:15:04 未中断）；系统侧 `onContinuousTaskStart com.follow.clashxEntryAbility0`、应用侧 `continuous task started id=8` 双重确认。

---

## 7. 已知限制与后续路线

1. **应用通知权限**当前被用户关闭——扩展侧普通状态通知发不出（1600004），实况窗保活不受影响。上架前默认引导开启。
2. **DATA_TRANSFER 策略依赖**：保活依赖「60s 实况通知 + 真实流量」双条件，已在代码内实现；若华为后续调整策略需复查（监听 `continuousTaskStateChange` 可第一时间感知取消）。
3. **Flutter 全量构建链**：`flutter pub get` 的 pub 缓存跨盘（D 盘 SDK/C 盘默认缓存）问题仍在，当前 hvigor-only 路径（复用 flutter_assets）完全够用；若需全量构建，统一 `PUB_CACHE` 环境变量到 D 盘即可。
4. **上架 AppGallery 前置**（见 `ohos/README.md` Signing 节）：ACL 权限 `ACCESS_EXTENSIONAL_DEVICE_DRIVER`、`KEEP_BACKGROUND_RUNNING` 需在 Profile `allowed-acls` 与华为审批中同时落实；`type: "vpn"` 旧 SDK 枚举问题已在 DevEco 侧解决。
5. **mihomo external-controller** 端口未固定在 9090，排障时先从 `/proc/net/tcp` 确认实际端口再做 fport。
6. **后续迭代建议**：连接断线自动重连的 UI 提示；节点健康检查在锁屏期间的节流（省电）；发布版签名（当前 debug 签名）。

---
