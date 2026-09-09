package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"sync/atomic"
	"time"
)

const body = "0123456789abcdef0123456789abcdef"

func argument(index, fallback int) int {
	if len(os.Args) <= index {
		return fallback
	}
	value, err := strconv.Atoi(os.Args[index])
	if err != nil || value < 0 {
		fmt.Fprintf(os.Stderr, "invalid argument %q\n", os.Args[index])
		os.Exit(2)
	}
	return value
}

func main() {
	port := argument(1, 8080)
	goal := argument(2, 0)
	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	var completed atomic.Uint64
	server := &http.Server{}
	server.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Connection", "close")
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		_, _ = w.Write([]byte(body))
		if goal != 0 && completed.Add(1) == uint64(goal) {
			go func() {
				time.Sleep(time.Millisecond)
				_ = server.Shutdown(context.Background())
			}()
		}
	})

	fmt.Printf("go_http_server: listening on port %d with %d GOMAXPROCS\n", port, runtime.GOMAXPROCS(0))
	if goal == 0 {
		fmt.Println("go_http_server: serving until killed")
	} else {
		fmt.Printf("go_http_server: will serve %d requests, then stop\n", goal)
	}
	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("go_http_server: requests completed %d\n", completed.Load())
}