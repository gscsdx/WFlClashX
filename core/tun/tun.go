//go:build (android || openharmony) && cgo

package tun

import "C"
import (
	"core/state"
	"fmt"
	"github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"net"
	"net/netip"
)

type Props struct {
	Fd       int    `json:"fd"`
	Gateway  string `json:"gateway"`
	Gateway6 string `json:"gateway6"`
	Portal   string `json:"portal"`
	Portal6  string `json:"portal6"`
	Dns      string `json:"dns"`
	Dns6     string `json:"dns6"`
}

func Start(fd int, cfg LC.Tun) (listener *sing_tun.Listener, err error) {
	defer func() {
		if r := recover(); r != nil {
			log.Errorln("startTUN panic recovered: %v", r)
			listener = nil
			err = fmt.Errorf("tun init panic: %v", r)
		}
	}()
	// The OHOS port resolved the configured log level to "silent", which left the
	// Dart log view and the REST /logs stream empty and made the TUN path opaque.
	// Upgrade only that fully-muted case; an explicit level (error/warn/info/debug)
	// from the profile is left alone.
	if log.Level() == log.SILENT {
		log.SetLevel(log.INFO)
	}
	var prefix4 []netip.Prefix
	tempPrefix4, err := netip.ParsePrefix(state.DefaultIpv4Address)
	if err != nil {
		log.Errorln("startTUN error:", err)
		return nil, err
	}
	prefix4 = append(prefix4, tempPrefix4)

	var dnsHijack []string
	if len(cfg.DNSHijack) > 0 {
		dnsHijack = cfg.DNSHijack
	} else {
		dnsHijack = append(dnsHijack, net.JoinHostPort(state.GetDnsServerAddress(), "53"))
	}

	// OHOS: a VpnExtension fd has no kernel-side TCP interception (that needs
	// root + nftables redirect), so the "system" stack accepts UDP/QUIC but
	// silently drops every TCP flow — the browser would just hang. Force the
	// gVisor stack (TCP + UDP both handled in the netstack) unconditionally:
	// this core only ever runs behind an OHOS VpnExtension, and runtime.GOOS
	// does NOT report "openharmony" on the ohos_golang toolchain (the log line
	// below showed effective=Mixed on device, so a GOOS check is useless here).
	stack := constant.TunGvisor

	// The profile ships mtu: 9000 (mihomo's Android default), but the OHOS VPN
	// interface is fixed at 1500: gVisor would emit 9000-byte segments that the
	// interface drops, which looks exactly like "QUIC loads, TCP hangs". Clamp to
	// a conservative value that survives mobile-carrier paths (WireGuard-style).
	mtu := cfg.MTU
	if mtu == 0 || mtu > 1500 {
		mtu = 1420
	}

	log.Infoln("startTUN stack: requested=%s effective=%s mtu=%d (config mtu=%d)",
		cfg.Stack, stack, mtu, cfg.MTU)

	options := LC.Tun{
		Enable:                 true,
		FileDescriptor:         fd,
		Stack:                  stack,
		MTU:                    mtu,
		// GSO / recvmsgx expect a Linux tun device with virtio-net headers; a
		// VpnService fd has none, so keep the plain read/write path.
		GSO:                    false,
		RecvMsgX:               false,
		SendMsgX:               false,
		DNSHijack:              dnsHijack,
		Inet4Address:           prefix4,
		EndpointIndependentNat: cfg.EndpointIndependentNat,
		UDPTimeout:             cfg.UDPTimeout,
		DisableICMPForwarding:  cfg.DisableICMPForwarding,
	}

	listener, err = sing_tun.New(options, tunnel.Tunnel)
	if err != nil {
		log.Errorln("startTUN error:", err)
		return nil, err
	}

	return listener, nil
}
