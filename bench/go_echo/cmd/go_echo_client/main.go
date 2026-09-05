// go_echo_client -- the same load generator as examples/echo_client.adb
// and bench/tokio_echo's client.
//
//	./go_echo_client [host] [port] [connections] [rounds]
//
// One goroutine per connection, all in flight at once; each does `rounds`
// PING/PONG round trips, says BYE, and closes.  The reported figure is the
// Ada client's: total frames divided by wall time, where wall time covers
// connect, the rounds, and teardown.
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
	started    atomic.Uint64
	ok         atomic.Uint64
	failed     atomic.Uint64
	frames     atomic.Uint64
	mismatched atomic.Uint64
	live       atomic.Int64
	peakLive   atomic.Int64
}

func (s *stats) startedOne() {
	s.started.Add(1)
	live := s.live.Add(1)
	for {
		peak := s.peakLive.Load()
		if live <= peak || s.peakLive.CompareAndSwap(peak, live) {
			break
		}
	}
}

func (s *stats) finishedOne(frames uint64, ok bool, mismatch bool) {
	s.frames.Add(frames)
	if ok {
		s.ok.Add(1)
	} else {
		s.failed.Add(1)
	}
	if mismatch {
		s.mismatched.Add(1)
	}
	s.live.Add(-1)
}

func session(host string, port uint32, rounds uint32, st *stats) {
	var outgoing, incoming echo.Frame
	var frames uint64
	mismatch := false

	st.startedOne()

	conn, err := net.Dial("tcp", net.JoinHostPort(host, fmt.Sprintf("%d", port)))
	if err != nil {
		st.finishedOne(0, false, false)
		return
	}
	defer conn.Close()
	if tc, ok := conn.(*net.TCPConn); ok {
		// The Ada client's sockets come from Tcp_Socket, which sets
		// TCP_NODELAY.
		_ = tc.SetNoDelay(true)
	}

	ok := true
	var round uint32
	for round = 1; round <= rounds; round++ {
		echo.Build(echo.Ping, round, &outgoing)

		if _, err := conn.Write(outgoing[:]); err != nil {
			ok = false
			break
		}
		if _, err := io.ReadFull(conn, incoming[:]); err != nil {
			ok = false
			break
		}

		kind, sequence := echo.Parse(&incoming)
		if kind != echo.Pong || sequence != round {
			mismatch = true
			ok = false
			break
		}
		frames++
	}

	echo.Build(echo.Farewell, 0, &outgoing)
	_, _ = conn.Write(outgoing[:])

	st.finishedOne(frames, ok, mismatch)
}

func main() {
	args := os.Args[1:]
	host := "127.0.0.1"
	if len(args) > 0 {
		host = args[0]
	}
	port := echo.ArgOr(args, 1, 9099)
	connections := echo.ArgOr(args, 2, 1000)
	rounds := echo.ArgOr(args, 3, 8)

	cpus := echo.CPUList("IOUR_BENCH_CPUS")
	echo.PinCPUSet(cpus)
	if len(cpus) > 0 {
		runtime.GOMAXPROCS(len(cpus))
	}

	fdLimit := echo.RaiseDescriptorLimit()

	fmt.Printf(
		"go_echo_client: %s port %d, %d connections, %d rounds each\n",
		host, port, connections, rounds,
	)
	fmt.Printf("go_echo_client: %d GOMAXPROCS, descriptor limit %d\n", runtime.GOMAXPROCS(0), fdLimit)

	st := &stats{}
	start := time.Now()

	var wg sync.WaitGroup
	wg.Add(int(connections))
	for i := uint32(0); i < connections; i++ {
		go func() {
			defer wg.Done()
			session(host, port, rounds, st)
		}()
	}
	wg.Wait()

	elapsed := time.Since(start).Seconds()
	frames := st.frames.Load()
	succeeded := st.ok.Load()
	mismatched := st.mismatched.Load()

	fmt.Println()
	fmt.Printf(
		"go_echo_client: sessions started %d, succeeded %d, failed %d\n",
		st.started.Load(), succeeded, st.failed.Load(),
	)
	fmt.Printf(
		"go_echo_client: frames exchanged %d, protocol mismatches %d\n",
		frames, mismatched,
	)
	fmt.Printf("go_echo_client: peak concurrent sessions %d\n", st.peakLive.Load())
	fmt.Printf("go_echo_client: elapsed %.9f s\n", elapsed)
	if elapsed > 0.0 {
		fmt.Printf("go_echo_client: round trips per second %.8E\n", float64(frames)/elapsed)
	}

	if succeeded == uint64(connections) && mismatched == 0 {
		os.Exit(0)
	}
	os.Exit(1)
}
