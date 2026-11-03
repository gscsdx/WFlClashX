import 'dart:io';

/// A selectable client identity for the outbound `User-Agent` header.
///
/// Providers sniff the UA to decide which config format — and which custom
/// response headers — to hand back, so a client they don't recognise can end up
/// with an empty or unusable profile. Presets let the user present the app as
/// one of the mainstream clients instead of waiting for provider support.
///
/// Only Clash/mihomo-family identities are listed on purpose: anything else
/// (Shadowrocket, Surge, v2rayN, sing-box, …) makes the provider answer with a
/// non-YAML payload this app cannot import, so offering those would only
/// produce broken profiles.
///
/// Version numbers are cosmetic — panels match the `name/` prefix, not the
/// number — but keep them plausible so version-gated features stay unlocked.
class UaPreset {
  const UaPreset(this.label, this.value, {this.isAppDefault = false});

  /// Brand name shown in the picker. Deliberately not localized — these are
  /// other products' names, not UI copy.
  final String label;

  /// The literal UA handed to the provider.
  final String value;

  /// True only for FlClash X's own identity: its value is rebuilt from the
  /// running app/core version, so it must never be stored or compared verbatim.
  final bool isAppDefault;

  /// True for the identity an unset `global-ua` resolves to, i.e. the fallback
  /// the picker should tag as "default".
  bool get isDefault => value == uaPresetDefault.value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is UaPreset && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => "UaPreset($label: $value)";
}

/// Prefix of the app's own UA, mirrored from `PackageInfoExtension.ua`. Used to
/// recognise an identity recorded by an older build of this same app.
const _appUaPrefix = "FlClash X/";

/// Default identity, sent whenever the user has not chosen one: `clash-verge`
/// is the name provider whitelists are most often written against on both
/// mobile and desktop, so a fresh install introduces itself as it instead of
/// waiting for each panel to learn FlClash X.
const uaPresetClashVerge = UaPreset("clash-verge", "clash-verge/v2.4.5");

/// The identity an unset (or cleared) `global-ua` resolves to.
const uaPresetDefault = uaPresetClashVerge;

/// mihomo's own UA. Provider whitelists are most often written against this,
/// and ClashX-Pro switched its subscription UA to it for exactly that reason.
const uaPresetMihomo = UaPreset("mihomo", "mihomo/1.19.28");

/// `clash.meta/<core version>`: what mihomo-derived clients (and the core
/// itself) send by default.
const uaPresetClashMeta = UaPreset("clash.meta", "clash.meta/1.19.28");

/// `ClashMetaForAndroid/<app-version>.Meta` — the exact shape CMFA sends; the
/// `.Meta` suffix is part of it (alpha builds use `.Meta-Alpha`) and panels
/// match the prefix case-insensitively.
const uaPresetClashMetaForAndroid = UaPreset(
  "ClashMetaForAndroid",
  "ClashMetaForAndroid/2.11.33.Meta",
);

/// Upstream FlClash also appends `clash-verge` to itself, so panels keyed on
/// either name answer it. Platform token follows the real OS, like upstream.
final uaPresetFlClash = UaPreset(
  "FlClash",
  "FlClash/v0.8.94 clash-verge Platform/${Platform.operatingSystem}",
);

/// Clash Party / Mihomo Party: `mihomo.party/v<version> (clash.meta)`.
const uaPresetMihomoParty = UaPreset(
  "Mihomo Party",
  "mihomo.party/v1.9.5 (clash.meta)",
);

/// The Android predecessor of mihomo clients; some older panels only know it.
const uaPresetClashForAndroid = UaPreset(
  "Clash for Android",
  "ClashForAndroid/2.5.12",
);

/// macOS classic. Its real UA carries an Alamofire suffix, but the prefix is
/// what panels read, and the shorter form avoids leaking a stale runner.
const uaPresetClashX = UaPreset("ClashX", "ClashX/1.118.0");

/// Chained identities (the trick DeckyClash ships as its recommended value):
/// the leading token is `clash.meta/`, which any panel matches, and the rest
/// satisfy whitelists keyed on another client. Last resort for a panel that
/// rejects every single-client preset above.
const uaPresetCombo = UaPreset(
  "Multi-client (combo)",
  "clash.meta/1.19.28 clash-verge/2.5.0 mihomo.party/v1.9.5 FlClash/v0.8.93",
);

/// FlClash X's own identity. Resolved per call so it always reflects the
/// running app/core version instead of freezing the version it was picked on.
UaPreset uaPresetAppOf(String appUa) =>
    UaPreset("FlClash X", appUa, isAppDefault: true);

/// Every selectable identity, fallback first, then the app's own, then the
/// rest ordered from "most generally accepted" to "niche".
List<UaPreset> uaPresetsOf(String appUa) => [
      uaPresetDefault,
      uaPresetAppOf(appUa),
      uaPresetMihomo,
      uaPresetClashMeta,
      uaPresetClashMetaForAndroid,
      uaPresetFlClash,
      uaPresetMihomoParty,
      uaPresetClashForAndroid,
      uaPresetClashX,
      uaPresetCombo,
    ];

/// Map a stored `global-ua` back onto a preset. An unrecognised value (a preset
/// that was renamed, a hand-edited one, or a value picked on another platform)
/// becomes its own entry rather than being reset — silently dropping the choice
/// would change what the provider sees on the next update.
UaPreset uaPresetOf(String? stored, List<UaPreset> presets) {
  final value = stored?.trim();
  if (value == null || value.isEmpty) {
    return uaPresetDefault;
  }
  if (value.startsWith(_appUaPrefix)) {
    // Recorded by an older build of this app, so the version token in it is
    // stale. Map it onto the live entry to keep the wire value current.
    return presets.firstWhere(
      (preset) => preset.isAppDefault,
      orElse: () => presets.first,
    );
  }
  return presets.firstWhere(
    (preset) => preset.value == value,
    orElse: () => UaPreset(value, value),
  );
}

/// Options for the picker: every preset, plus the stored value when it matches
/// none of them, so the current choice stays visible and selected.
List<UaPreset> uaOptionsOf(String? stored, String appUa) {
  final presets = uaPresetsOf(appUa);
  final current = uaPresetOf(stored, presets);
  return presets.contains(current) ? presets : [...presets, current];
}

/// The literal header value for a stored `global-ua`: applies the default when
/// nothing is stored and expands the app's own identity to the live version.
/// Both the app's downloads and the core's `global-ua` go through this, so the
/// two never disagree about who is asking.
String resolveUa(String? stored, String appUa) {
  final preset = uaPresetOf(stored, uaPresetsOf(appUa));
  return preset.isAppDefault ? appUa : preset.value;
}
