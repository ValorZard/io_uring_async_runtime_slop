//go:build windows

package main

import (
	"fmt"
	"net"
)

// listenWithBacklog on Windows is just net.Listen, and that is not a
// shortcut.  Go's Windows listener passes SOMAXCONN, which Winsock reads
// as "use the largest reasonable backlog for this provider" rather than as
// a number -- so it already asks for more than the 4096 the Ada demo
// requests, and there is nothing to raise.  The backlog argument is kept
// so the two halves have one signature, and ignored.
//
// The Linux half has to go through syscall.Socket to get past the
// kernel's somaxconn default, which is where a short accept queue turns a
// connect into a one-second SYN retransmit.
func listenWithBacklog(port int, backlog int) (net.Listener, error) {
	_ = backlog
	return net.Listen("tcp4", fmt.Sprintf("0.0.0.0:%d", port))
}
