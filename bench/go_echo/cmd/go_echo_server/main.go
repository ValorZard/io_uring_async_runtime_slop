// go_echo_server -- the same server as examples/echo_server.adb, on Go's
// goroutine-per-connection model.
//
//	./go_echo_server [port] [connections-to-serve]
//
// Structure is deliberately the same shape as the Ada one: a single
// acceptor that starts one goroutine per connection, and each connection
// reads a 32-byte frame, answers PONG, and stops on BYE.  A
// connections-to-serve of 0 means run until killed.
//
// IOUR_BENCH_CPUS ("1,2,3,4") is read the same way the tokio binaries read
// it, restricting the process to that CPU set before any goroutine does
// real work and setting GOMAXPROCS to match -- see echo.PinCPUSet for why
// that is the Go equivalent of tokio's per-worker pinning, not the same
// thing.
package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"go_echo/echo"
)

type stats struct {
	accepted  atomic.Uint64
	completed atomic.Uint64
	frames    atomic.Uint64
	errors    atomic.Uint64
	live      atomic.Int64
	peakLive  atomic.Int64
}

func (s *stats) acceptedOne() {
	s.accepted.Add(1)
	live := s.live.Add(1)
	for {
		peak := s.peakLive.Load()
		if live <= peak || s.peakLive.CompareAndSwap(peak, live) {
			break
		}
	}
}

// completedOne reports whether this was the connection the server was
// counting to.
func (s *stats) completedOne(frames uint64, failed bool, goal uint64) bool {
	s.frames.Add(frames)
	if failed {
		s.errors.Add(1)
	}
	s.live.Add(-1)
	done := s.completed.Add(1)
	return goal > 0 && done >= goal
}

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

// serve is one connection, start to finish: read a frame, answer PONG,
// repeat until BYE or the peer vanishes.
func serve(conn net.Conn, st *stats, goal uint64, closeListener func()) {
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		// The Ada client's sockets come from Tcp_Socket, which sets
		// TCP_NODELAY.
		_ = tc.SetNoDelay(true)
	}

	var request, response echo.Frame
	var frames uint64
	failed := false

	for {
		if _, err := io.ReadFull(conn, request[:]); err != nil {
			break // peer closed, or closed mid-frame
		}

		kind, sequence := echo.Parse(&request)
		if kind == echo.Farewell {
			break
		}
		if kind != echo.Ping {
			failed = true
			break
		}

		echo.Build(echo.Pong, sequence, &response)
		if _, err := conn.Write(response[:]); err != nil {
			// A peer that vanished mid-conversation is ordinary, not an
			// error worth counting -- same call the other two make.
			break
		}
		frames++
	}

	if st.completedOne(frames, failed, goal) {
		closeListener()
	}
}

func main() {
	args := os.Args[1:]
	port := echo.ArgOr(args, 0, 9099)
	goal := uint64(echo.ArgOr(args, 1, 0))

	cpus := echo.CPUList("IOUR_BENCH_CPUS")
	echo.PinCPUSet(cpus)
	if len(cpus) > 0 {
		runtime.GOMAXPROCS(len(cpus))
	}

	fdLimit := echo.RaiseDescriptorLimit()

	listener, err := listenWithBacklog(int(port), 4096)
	if err != nil {
		fmt.Printf("go_echo_server: cannot listen on port %d (%v)\n", port, err)
		os.Exit(1)
	}
	bound := port
	if tcpAddr, ok := listener.Addr().(*net.TCPAddr); ok {
		bound = uint32(tcpAddr.Port)
	}

	fmt.Printf(
		"go_echo_server: listening on port %d with %d GOMAXPROCS, descriptor limit %d\n",
		bound, runtime.GOMAXPROCS(0), fdLimit,
	)
	if goal > 0 {
		fmt.Printf("go_echo_server: will serve %d connections, then stop\n", goal)
	} else {
		fmt.Println("go_echo_server: serving until killed")
	}

	st := &stats{}
	var closeOnce sync.Once
	closeListener := func() { closeOnce.Do(func() { listener.Close() }) }

	for {
		if goal > 0 && st.accepted.Load() >= goal {
			break
		}
		conn, err := listener.Accept()
		if err != nil {
			break // listener closed, from us or an external signal
		}
		st.acceptedOne()
		go serve(conn, st, goal, closeListener)
	}

	// The acceptor stopped because the goal was reached (or the listener
	// was closed by the last handler racing us here); wait for the last
	// handlers, exactly as the Ada server waits for shutdown.
	if goal > 0 {
		for st.completed.Load() < goal {
			time.Sleep(time.Millisecond)
		}
	}
	closeListener()

	errors := st.errors.Load()
	fmt.Println()
	fmt.Printf(
		"go_echo_server: accepted %d, completed %d, rejected 0\n",
		st.accepted.Load(), st.completed.Load(),
	)
	fmt.Printf(
		"go_echo_server: frames echoed %d, protocol errors %d\n",
		st.frames.Load(), errors,
	)
	fmt.Printf("go_echo_server: peak concurrent connections %d\n", st.peakLive.Load())

	if errors == 0 {
		os.Exit(0)
	}
	os.Exit(1)
}
