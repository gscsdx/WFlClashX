//go:build openharmony && cgo

package main

import (
	"github.com/metacubex/mihomo/component/resolver"
)

// updateSystemDNS on OpenHarmony flushes the resolver cache. OpenHarmony routes DNS
// through the VPN tunnel managed by the VpnExtensionAbility, so we clear the cache
// and reset connections rather than patching the system resolver. No `cmfa` tag is
// required here, keeping the OHOS build free of Android-only mihomo patches.
func updateSystemDNS(servers []string) {
	resolver.ClearCache()
	resolver.ResetConnection()
}
