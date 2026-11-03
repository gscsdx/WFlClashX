//go:build android && cgo

package main

import (
	"github.com/metacubex/mihomo/dns"
)

// updateSystemDNS applies the given DNS servers as the system resolver and flushes
// the resolver cache. This relies on the `cmfa`-tagged DNS patch in mihomo, which
// is provided by the Android build (built with `-tags cmfa`).
func updateSystemDNS(servers []string) {
	dns.UpdateSystemDNS(servers)
	dns.FlushCacheWithDefaultResolver()
}
