package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"sync"
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
	host := "127.0.0.1"
	if len(os.Args) > 1 {
		host = os.Args[1]
	}
	port := argument(2, 8080)
	connections := argument(3, 100)
	rounds := argument(4, 8)
	url := fmt.Sprintf("http://%s:%d/", host, port)
	client := &http.Client{Transport: &http.Transport{DisableKeepAlives: true}}

	var succeeded, failed atomic.Uint64
	started := time.Now()
	var workers sync.WaitGroup
	for connection := 0; connection < connections; connection++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for round := 0; round < rounds; round++ {
				request, err := http.NewRequest(http.MethodGet, url, nil)
				if err != nil {
					failed.Add(1)
					continue
				}
				request.Header.Set("Connection", "close")
				response, err := client.Do(request)
				if err != nil {
					failed.Add(1)
					continue
				}
				data, readErr := io.ReadAll(response.Body)
				response.Body.Close()
				if readErr != nil || response.StatusCode != http.StatusOK || string(data) != body {
					failed.Add(1)
				} else {
					succeeded.Add(1)
				}
			}
		}()
	}
	workers.Wait()
	elapsed := time.Since(started).Seconds()
	requests := succeeded.Load()
	fmt.Printf("go_http_client: %s port %d, %d connections, %d rounds each\n", host, port, connections, rounds)
	fmt.Printf("go_http_client: sessions started %d, succeeded %d, failed %d\n", connections, connections, failed.Load())
	fmt.Printf("go_http_client: frames exchanged %d\n", requests)
	fmt.Printf("go_http_client: elapsed %.9f s\n", elapsed)
	if elapsed > 0 {
		fmt.Printf("go_http_client: round trips per second %.8E\n", float64(requests)/elapsed)
	}
	if failed.Load() != 0 {
		os.Exit(1)
	}
}
