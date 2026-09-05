//go:build linux

package main

import (
	"fmt"
	"net"
	"os"
	"syscall"
)

// listenWithBacklog gives a listener the same backlog the Ada demo uses
// (Tcp_Listener's 4096).  net.Listen would give us the kernel's somaxconn
// default, and a short accept queue is the difference between a connect
// and a one-second SYN retransmit when a thousand clients arrive at once.
func listenWithBacklog(port int, backlog int) (net.Listener, error) {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_STREAM, 0)
	if err != nil {
		return nil, err
	}
	closed := false
	defer func() {
		if !closed {
			syscall.Close(fd)
		}
	}()

	if err := syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1); err != nil {
		return nil, err
	}
	if err := syscall.Bind(fd, &syscall.SockaddrInet4{Port: port}); err != nil {
		return nil, err
	}
	if err := syscall.Listen(fd, backlog); err != nil {
		return nil, err
	}

	file := os.NewFile(uintptr(fd), fmt.Sprintf("tcp-listen-%d", port))
	listener, err := net.FileListener(file)
	file.Close() // net.FileListener dups the descriptor.
	closed = true
	if err != nil {
		return nil, err
	}
	return listener, nil
}
