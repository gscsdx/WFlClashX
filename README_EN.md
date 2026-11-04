<div align="right">

[简体中文](README.md) · **English** · [Русский](README_RU.md)

</div>

# FlClashX

[![Release](https://img.shields.io/github/v/release/gscsdx/WFlClashX?style=flat-square&logo=github)](https://github.com/gscsdx/WFlClashX/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/gscsdx/WFlClashX/total?style=flat-square)](https://github.com/gscsdx/WFlClashX/releases)
[![Cloud build](https://img.shields.io/github/actions/workflow/status/gscsdx/WFlClashX/build.yml?style=flat-square&label=cloud%20build)](https://github.com/gscsdx/WFlClashX/actions)
[![License](https://img.shields.io/github/license/gscsdx/WFlClashX?style=flat-square)](LICENSE)

A multi-platform proxy client built on the [Clash.Meta (mihomo)](https://github.com/MetaCubeX/mihomo) core: **Flutter for the UI, Go for the core** — open source and ad-free.

This project is a fork of [FlClash](https://github.com/chen08209/FlClash) → [FlClashX](https://github.com/pluralplay/FlClashX), with two major additions:

1. **A native HarmonyOS NEXT port** — an ArkTS `VpnExtensionAbility` drives the same Go core over a NAPI bridge, with the TUN path reimplemented as a pure userspace gVisor stack;
2. **Fully automated cloud builds** — one GitHub Actions pipeline produces Android / Windows / Linux / macOS installers, with automated releases.

> Codename **Wormhole**: the pub package name is `wormhole` and the HarmonyOS bundle name is `com.wormhole.app`. Desktop and Android binaries/installers keep the upstream name `FlClashX`.

---

## Platform support

| Platform | Architectures | Artifacts | Status |
| --- | --- | --- | --- |
| **Android** | arm64-v8a / armeabi-v7a / x86_64 | APK (plus a universal build) | ✅ cloud build |
| **Windows** | amd64 / arm64 | ZIP + Inno Setup installer | ✅ cloud build |
| **Linux** | amd64 / arm64 | deb / rpm / AppImage | ✅ cloud build |
| **macOS** | amd64 / arm64 | DMG | ✅ cloud build |
| **HarmonyOS NEXT** | arm64 | HAP | ✅ local build (requires DevEco signing) |

Core versions: mihomo `v1.19.28`; the TUN stack is built on `metacubex/sing-tun v0.4.21` (the HarmonyOS port uses the vendored fork in this repo).

---

## Download

Grab the installer for your platform from [**Releases**](https://github.com/gscsdx/WFlClashX/releases/latest). Release `v0.4.3` ships 14 assets:

| Platform | Files |
| --- | --- |
| Android | `FlClashX-android-arm64-v8a.apk`, `-armeabi-v7a.apk`, `-x86_64.apk`, `-universal.apk` |
| Windows | `FlClashX-windows-amd64.zip` / `-setup.exe`, `FlClashX-windows-arm64.zip` / `-setup.exe` |
| Linux | `FlClashX-linux-amd64.AppImage` / `.deb` / `.rpm`, `FlClashX-linux-arm64.deb` |
| macOS | `FlClashX-macos-amd64.dmg`, `FlClashX-macos-arm64.dmg` |

### Signing notes (important)

The cloud build carries **no commercial signing certificate**, so:

- **Android** — APKs are debug-signed: installable for testing, **not publishable to stores**;
- **Windows** — unsigned; SmartScreen shows "Unknown publisher", choose *Run anyway*;
- **macOS** — the dmg is unsigned and not notarized; open it via **right-click → Open**, or run `xattr -cr /Applications/FlClashX.app`;
- **Linux** — deb/rpm are unsigned; `chmod +x` the AppImage first.

For production distribution you must supply your own certificates (Android keystore, Apple Developer ID, Windows code-signing certificate).

---

## Features

### Proxy core

- mihomo rule engine: rule / global / direct modes, subscriptions, proxy groups, latency tests, live connections and traffic stats;
- TUN mode (Windows / Linux / macOS / Android / HarmonyOS) and system-proxy mode (desktop);
- Per-app proxying (Android / HarmonyOS), process matching, DNS and GeoIP routing.

### Subscription panel integration (for [Remnawave](https://github.com/remnawave/panel))

- **HWID reporting** — sends a device fingerprint to the panel;
- **Announcements widget** — surfaces panel announcements on the home screen;
- **Meta-Info widget** — remaining traffic, expiry date and subscription name, highlighted within 3 days of expiry;
- **serviceInfo widget** — service name and custom logo; tapping opens the support link;
- **changeServerButton** — jumps straight to the proxies page;
- **Widget order controlled by the subscription** — see `flclashx-widgets` below.

### UX and UI

- Android 120 Hz support; Android TV remote-control improvements (paste button, group picker, QR profile transfer from phone);
- Native macOS menu-bar mode;
- Adjustable UI background transparency;
- Localization: 简体中文 / English / Русский.

### HarmonyOS NEXT port

- `VpnExtensionAbility` hosts the VPN extension process and talks to the UI process over RPC, with a restart budget when the core dies;
- The Go core is compiled as a `c-shared` library (`libclash_core.so`) and bridged via NAPI — no gomobile, no JVM;
- **The critical TUN adaptation**: OHOS returns `EACCES` for `fstat()` on the `VpnService` file descriptor, which prevents gVisor's fdbased endpoint from initializing. The port therefore uses a **pure userspace channel endpoint** and moves packets with raw `unix.Read/Write + unix.Poll` calls, sidestepping the netpoller's dependency on `fstat` (see `core/third_party/sing-tun/tun_linux_gvisor.go`);
- Architecture notes, the debugging log and verification data live in [**OHOS-DELIVERY.md**](OHOS-DELIVERY.md) (Chinese); environment and build steps in [ohos/README.md](ohos/README.md).

---

## Subscription-side customization

The client reads a handful of `flclashx-*` extension keys from the subscription's HTTP response headers and YAML config to customize the home and proxies screens.

### HTTP response headers

| Header | Purpose |
| --- | --- |
| `flclashx-servicename` | Service name (shown in the serviceInfo widget) |
| `flclashx-servicelogo` | Service logo (svg / png URL) |
| `flclashx-supporturl` | Support link opened by the serviceInfo widget |
| `flclashx-widgets` | Home widget order/visibility, comma separated |
| `flclashx-view` | Proxies page appearance |

Available `flclashx-widgets` values:

| Value | Widget | Value | Widget |
| --- | --- | --- | --- |
| `announce` | Announcements | `intranetIp` | Local IP |
| `networkSpeed` | Network speed | `memoryInfo` | Memory usage |
| `outboundModeV2` | Proxy mode (new) | `metainfo` | Subscription info |
| `outboundMode` | Proxy mode (legacy) | `changeServerButton` | Change server |
| `trafficUsage` | Traffic usage | `serviceInfo` | Service info |
| `networkDetection` | Exit IP / region | `tunButton` | TUN toggle (desktop) |
| `vpnButton` | VPN toggle (Android) | `systemProxyButton` | System proxy toggle (desktop) |

Example:

```
flclashx-widgets: announce,metainfo,outboundModeV2,networkDetection
```

### YAML keys

- `flclashx-override` (inside the `GLOBAL` proxy group): when `true`, global mode shows only that group's proxies in that exact order and hides the rule-mode service groups;
- `description` (any proxy group): replaces the default subtitle shown under the group name.

---

## Building from source

### Requirements

| Target | Dependencies |
| --- | --- |
| Common | Flutter (CI pins **3.41.7**), Dart SDK ≥ 3.5, Go ≥ 1.20 (CI uses **1.26**) |
| Android | Android SDK + NDK **28.0.13004108** |
| Windows | Visual Studio 2022 (Desktop C++ workload), Inno Setup 6 (installer) |
| Linux | `clang`, `cmake`, `ninja-build`, `libgtk-3-dev` |
| macOS | Xcode |
| HarmonyOS | DevEco Studio 5.0+, Flutter-OH SDK, HarmonyOS Go toolchain |

```bash
flutter pub get
```

### Desktop / Android

The single entry point is `setup.dart` at the repo root (it cross-compiles the Go core, runs `flutter build`, then packages):

```bash
# Usage: dart setup.dart <android|windows|linux|macos> [--arch amd64|arm64] [--env stable]
dart setup.dart android                  # Android APKs (all ABIs)
dart setup.dart windows --arch amd64
dart setup.dart linux   --arch arm64
dart setup.dart macos   --arch arm64 --env stable
```

Artifacts land in `dist/`. Common combinations also have Makefile shortcuts:

```bash
make android_app        # Android, all ABIs
make android_arm64      # Android arm64
make macos_arm64        # macOS arm64
make macLocal           # wipe dist/build, rebuild macOS arm64 (stable)
make cleanLocal         # remove dist and build
```

### HarmonyOS NEXT

```bash
# 1) Cross-compile the Go core → ohos/entry/libs/arm64-v8a/libclash_core.so
cd core
OHOS_GO=/path/to/ohos-go/bin/go \
OHOS_NDK=/path/to/sdk/default/openharmony/native \
  ./build_ohos.sh

# 2) Package the HAP
cd ..
flutter build hap --target-platform ohos-arm64 --release
# or hvigor only: cd ohos && hvigorw assembleHap
```

Caveats:

- You must use **Flutter-OH** (`gitee.com/openharmony-sig/flutter_flutter`), not upstream Flutter, and never run `flutter upgrade`;
- On first build, merge the Flutter-OH generated `har/`, `GeneratedPluginRegistrant.ets` and signing config into `ohos/`;
- **After changing the `.so` you must clear the native cache before packaging** (`ohos/entry/build/default/intermediates/{stripped_native_libs,libs}`), otherwise the old core gets bundled;
- Signing is configured in DevEco Studio (`File → Project Structure → Signing Configs`); the restricted ACL permission (`ACCESS_EXTENSIONAL_DEVICE_DRIVER`) must be declared in the profile's `allowed-acls`.

Full manuals: [ohos/README.md](ohos/README.md) and [OHOS-DELIVERY.md](OHOS-DELIVERY.md) (both Chinese).

---

## Cloud builds (GitHub Actions)

Four workflows ship in the repo; all of them run **without any secret**:

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `ci.yml` | push to main touching `lib/**`, `core/**`, `setup.dart`, `pubspec*` | Android smoke build (compile check) |
| `build.yml` | **manual** (Actions → build → Run workflow) | Android + Windows (amd64/arm64) + Linux (amd64/arm64) — 5 jobs |
| `macos.yml` | manual, or on changes to `setup.dart` / itself | macOS amd64 + arm64 DMGs |
| `release.yml` | push a `v*` tag | Builds all 7 targets and creates a GitHub Release |

Why macOS is a separate workflow: GitHub's macOS runners are heavily contended and queued jobs get cancelled (`The job was not acquired by Runner of type hosted`). Splitting them out of the 5-platform matrix dramatically improves the odds of getting a runner.

### Release procedure

```bash
git tag -a v0.4.3 -m "notes"
git push origin v0.4.3
```

Pushing the tag builds every platform and publishes a Release; a tag containing `-` (e.g. `v0.4.3-beta.1`) is published as a pre-release.

---

## Repository layout

```
lib/                    Flutter UI and app logic (pages, state, Clash control layer)
core/                   Go core wrapper (mihomo), build_ohos.sh, vendored sing-tun
  third_party/sing-tun/ HarmonyOS TUN fork (channel endpoint + raw fd I/O)
ohos/                   HarmonyOS NEXT project (ArkTS VpnExtensionAbility + NAPI bridge)
android/ windows/ linux/ macos/    Per-platform projects
arb/                    Localization (zh_CN / en / ja / ru)
setup.dart              Cross-platform build orchestrator (core build + flutter build + package)
services/helper/        Privileged helper service for desktop
.github/workflows/      CI: ci / build / macos / release
```

---

## Known limitations

- **HarmonyOS**: per-app ownership resolution (`ResolveProcess`) is not implemented; quick tiles, home-screen widgets and TV support are out of scope; the notification is a basic ongoing one;
- **Desktop**: TUN mode on Linux requires root or `CAP_NET_ADMIN`;
- **Signing**: no cloud artifact is commercially signed — supply your own certificates for store distribution;
- **macOS**: the app is not notarized; first launch needs a right-click open.

---

## Credits and license

- Core: [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) (Clash.Meta)
- TUN stack: [MetaCubeX/sing-tun](https://github.com/MetaCubeX/sing-tun)
- Upstream client: [chen08209/FlClash](https://github.com/chen08209/FlClash), [pluralplay/FlClashX](https://github.com/pluralplay/FlClashX)
- HarmonyOS Flutter support: [openharmony-sig/flutter_flutter](https://gitee.com/openharmony-sig/flutter_flutter)

Licensed under [GPL-3.0](LICENSE). Use this software in compliance with your local laws and regulations.
