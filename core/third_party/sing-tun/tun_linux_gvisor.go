//go:build with_gvisor && linux

package tun

import (
	"context"
	"fmt"
	"os"

	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/rawfile"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/link/channel"
	"github.com/metacubex/gvisor/pkg/tcpip/link/fdbased"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	E "github.com/metacubex/sing/common/exceptions"
	"github.com/metacubex/sing-tun/internal/gtcpip/checksum"

	"golang.org/x/sys/unix"
)

func init() {
	fdbased.BufConfig = []int{65535}
}

var _ GVisorTun = (*NativeTun)(nil)

func (t *NativeTun) WritePacket(pkt *stack.PacketBuffer) (int, error) {
	var vnetHdrBuf []byte
	if t.vnetHdr {
		vnetHdr := virtioNetHdr{}
		if pkt.GSOOptions.Type != stack.GSONone {
			vnetHdr.hdrLen = uint16(pkt.HeaderSize())
			if pkt.GSOOptions.NeedsCsum {
				vnetHdr.flags = unix.VIRTIO_NET_HDR_F_NEEDS_CSUM
				vnetHdr.csumStart = pkt.GSOOptions.L3HdrLen
				vnetHdr.csumOffset = pkt.GSOOptions.CsumOffset
			}
			if uint16(pkt.Data().Size()) > pkt.GSOOptions.MSS {
				switch pkt.GSOOptions.Type {
				case stack.GSOTCPv4:
					vnetHdr.gsoType = unix.VIRTIO_NET_HDR_GSO_TCPV4
				case stack.GSOTCPv6:
					vnetHdr.gsoType = unix.VIRTIO_NET_HDR_GSO_TCPV6
				default:
					panic(fmt.Sprintf("Unknown gso type: %v", pkt.GSOOptions.Type))
				}
				vnetHdr.gsoSize = pkt.GSOOptions.MSS
			}
		}
		vnetHdrBuf = make([]byte, virtioNetHdrLen)
		err := vnetHdr.encode(vnetHdrBuf)
		if err != nil {
			return 0, err
		}
	}
	views := pkt.AsSlices()
	numIovecs := len(views)
	if len(vnetHdrBuf) != 0 {
		numIovecs++
	}

	// Allocate small iovec arrays on the stack.
	var iovecsArr [8]unix.Iovec
	iovecs := iovecsArr[:0]
	if numIovecs > len(iovecsArr) {
		iovecs = make([]unix.Iovec, 0, numIovecs)
	}

	if len(vnetHdrBuf) > 0 {
		iovec := unix.Iovec{
			Base: &vnetHdrBuf[0],
		}
		iovec.SetLen(len(vnetHdrBuf))
		iovecs = append(iovecs, iovec)
	}

	var dataLen int
	for _, packetSlice := range views {
		dataLen += len(packetSlice)
		iovec := unix.Iovec{
			Base: &packetSlice[0],
		}
		iovec.SetLen(len(packetSlice))
		iovecs = append(iovecs, iovec)
	}
	errno := rawfile.NonBlockingWriteIovec(t.tunFd, iovecs)
	if errno == 0 {
		return dataLen, nil
	} else {
		return 0, errno
	}
}

func (t *NativeTun) NewEndpoint() (stack.LinkEndpoint, stack.NICOptions, error) {
	if t.vnetHdr {
		ep, err := fdbased.New(&fdbased.Options{
			FDs:               []int{t.tunFd},
			MTU:               t.options.MTU,
			GSOMaxSize:        gsoMaxSize,
			GRO:               true,
			RXChecksumOffload: true,
			TXChecksumOffload: t.txChecksumOffload,
		})
		if err != nil {
			return nil, stack.NICOptions{}, err
		}
		return ep, stack.NICOptions{}, nil
	}
	// PATCH (FlClashX / OpenHarmony): gVisor's fdbased endpoint calls
	// isSocketFD(fd) -> unix.Fstat(fd) during setup, and OHOS answers EACCES
	// (errno 13) for a VpnService fd (dup() fails the same way, so the denial is
	// on the file object, not the descriptor). gVisor therefore refuses to start
	// and TCP dies with "unix.Fstat(..) failed: permission denied".
	//
	// Fall back to a pure userspace channel endpoint pumped with plain
	// read()/write() on the fd — exactly the mechanism this package already uses
	// for UDP in the Mixed stack, which works on OHOS.
	endpoint := channel.New(1024, t.options.MTU, "")
	go t.pumpChannelEndpoint(endpoint)
	return endpoint, stack.NICOptions{}, nil
}

// rawRead / rawWrite talk to the tun fd with plain syscalls instead of
// os.File: Go's os.File decides whether it can park on the netpoller by
// fstat()ing the descriptor, and OHOS denies fstat() on a VpnService fd — so
// os.File degrades to a non-pollable file and every read on a non-blocking fd
// fails with EAGAIN. Polling by hand makes the fd usable either way.
func (t *NativeTun) rawRead(buf []byte) (int, error) {
	fds := []unix.PollFd{{Fd: int32(t.tunFd), Events: unix.POLLIN}}
	for {
		n, err := unix.Read(t.tunFd, buf)
		if err == nil {
			return n, nil
		}
		switch err {
		case unix.EINTR:
			continue
		case unix.EAGAIN:
			if _, perr := unix.Poll(fds, -1); perr != nil && perr != unix.EINTR {
				return 0, perr
			}
			if fds[0].Revents&(unix.POLLHUP|unix.POLLNVAL|unix.POLLERR) != 0 {
				return 0, os.ErrClosed
			}
			continue
		case unix.EBADF:
			return 0, os.ErrClosed
		default:
			return 0, err
		}
	}
}

func (t *NativeTun) rawWrite(p []byte) error {
	fds := []unix.PollFd{{Fd: int32(t.tunFd), Events: unix.POLLOUT}}
	for {
		_, err := unix.Write(t.tunFd, p)
		if err == nil {
			return nil
		}
		switch err {
		case unix.EINTR:
			continue
		case unix.EAGAIN:
			if _, perr := unix.Poll(fds, -1); perr != nil && perr != unix.EINTR {
				return perr
			}
			if fds[0].Revents&(unix.POLLHUP|unix.POLLNVAL|unix.POLLERR) != 0 {
				return os.ErrClosed
			}
			continue
		case unix.EBADF:
			return os.ErrClosed
		default:
			return err
		}
	}
}

// pumpChannelEndpoint bridges gVisor's channel link endpoint and the tun fd.
// It mirrors the packet loops in stack_mixed.go (proven on OHOS), but carries
// every protocol instead of UDP only, so the TCP forwarder sees the segments.
func (t *NativeTun) pumpChannelEndpoint(endpoint *channel.Endpoint) {
	// readCtx is cancelled when the tun device closes, which unblocks the
	// outbound ReadContext below.
	readCtx, cancelRead := context.WithCancel(context.Background())
	defer cancelRead()
	go func() {
		<-t.pumpStop
		cancelRead()
	}()

	// netstack -> tun
	go func() {
		var written, failed int
		for {
			// channel queue's Read is NON-BLOCKING: nil only means "queue is
			// empty right now" (netstack may not have produced anything yet,
			// especially before the NIC is attached). Treat nil as "keep
			// waiting"; exit only when the device closes (pumpStop).
			pkt := endpoint.ReadContext(readCtx)
			if pkt == nil {
				select {
				case <-t.pumpStop:
					hlog("pump: outbound stopped (written=%d failed=%d)", written, failed)
					return
				case <-readCtx.Done():
					hlog("pump: outbound stopped (written=%d failed=%d)", written, failed)
					return
				}
			}
			view := pkt.ToView()
			data := view.AsSlice()
			err := t.rawWrite(data)
			view.Release()
			pkt.DecRef()
			if err != nil {
				failed++
				if failed <= 5 || failed%100 == 0 {
					hlog("pump: write failed (%d so far): %v", failed, err)
				}
				if E.IsClosed(err) {
					return
				}
				continue
			}
			written++
			if written%2000 == 0 {
				hlog("pump: outbound alive (written=%d failed=%d)", written, failed)
			}
		}
	}()

	// tun -> netstack
	buf := make([]byte, int(t.options.MTU)+1024)
	var total, v4, v6, other, readErr int
	for {
		n, err := t.rawRead(buf)
		if err != nil {
			if E.IsClosed(err) {
				return
			}
			readErr++
			if readErr <= 5 || readErr%100 == 0 {
				hlog("pump: read failed (%d so far): %v", readErr, err)
			}
			continue
		}
		if n < header.IPv4MinimumSize {
			continue
		}
		raw := buf[:n]
		data := make([]byte, n)
		copy(data, raw)
		pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{
			Payload: buffer.MakeWithData(data),
		})
		switch raw[0] >> 4 {
		case 4:
			v4++
			endpoint.InjectInbound(header.IPv4ProtocolNumber, pkt)
		case 6:
			v6++
			endpoint.InjectInbound(header.IPv6ProtocolNumber, pkt)
		default:
			other++
		}
		pkt.DecRef()
		total++
		if total%5000 == 0 {
			hlog("pump: inbound alive (total %d, v4 %d, v6 %d, queued %d)",
				total, v4, v6, endpoint.NumQueued())
		}
	}
}

// ipv4ChecksumValid reports whether an IPv4 packet's L4 checksum verifies.
// gVisor drops segments whose checksum is wrong without logging, so this probe
// distinguishes "the stack ignored us" from "the stack rejected the packet".
func ipv4ChecksumValid(pkt []byte, ipProto int) bool {
	if len(pkt) < 20 || pkt[0]>>4 != 4 {
		return false
	}
	if ipProto != 6 && ipProto != 17 {
		return false
	}
	ihl := int(pkt[0]&0x0f) * 4
	if ihl < 20 || len(pkt) < ihl+8 {
		return false
	}
	payload := pkt[ihl:]
	if ipProto == 17 && payload[6] == 0 && payload[7] == 0 {
		// A zero UDP checksum means "not computed" and is legal for IPv4.
		return true
	}
	pseudo := make([]byte, 12)
	copy(pseudo[0:4], pkt[12:16])
	copy(pseudo[4:8], pkt[16:20])
	pseudo[9] = byte(ipProto)
	pseudo[10] = byte(len(payload) >> 8)
	pseudo[11] = byte(len(payload))
	sum := checksum.Checksum(payload, 0)
	sum = checksum.Checksum(pseudo, sum)
	return sum == 0xffff
}
