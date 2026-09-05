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
// Nothing here is configured for the benchmark.  It is net.Listen and
// goroutines on the default GOMAXPROCS -- what a Go program does unless it
// is told otherwise -- and that is the point: the comparison is against
// what someone would deploy, not against a tuned copy of the Ada server's
// thread-per-core arrangement.  There used to be process affinity, a
// GOMAXPROCS override and a hand-rolled listen backlog here, all of it so
// this binary met the Ada one on the Ada one's terms.
package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
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

	listener, err := net.Listen("tcp4", fmt.Sprintf("0.0.0.0:%d", port))
	if err != nil {
		fmt.Printf("go_echo_server: cannot listen on port %d (%v)\n", port, err)
		os.Exit(1)
	}
	bound := port
	if tcpAddr, ok := listener.Addr().(*net.TCPAddr); ok {
		bound = uint32(tcpAddr.Port)
	}

	fmt.Printf(
		"go_echo_server: listening on port %d with %d GOMAXPROCS\n",
		bound, runtime.GOMAXPROCS(0),
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
