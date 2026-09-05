// runwait -- run a command, wait for it, and report what it cost.
//
//	runwait <report-file> [NAME=VALUE...] <command> [args...]
//
// Writes "user_seconds system_seconds peak_rss_kilobytes" to the report
// file when the child exits, and exits with the child's status.  Standard
// output and error pass straight through, so a caller can still watch the
// child's banner go by.
//
// Leading NAME=VALUE arguments set the child's environment, the way env(1)
// does.  That is not a convenience: putting `env` in front of the command
// instead would make env the process this measures, and on Windows -- where
// there is no exec, only spawn -- the server would be env's child and its
// CPU time would not be counted.  A benchmark that did that would report
// the wrapper's microseconds and call them the runtime's.
//
// RUNWAIT_TIMEOUT_S, if set, kills the child after that many seconds and
// exits 124 the way `timeout` would.  The timeout lives here rather than
// in a wrapper because only this process holds a handle on the child: a
// `timeout` outside it would kill this process on Windows without running
// anything, and leave the child holding the port.  A benchmark server that
// waits for connections which never arrived is exactly that case.
//
// This exists because `/usr/bin/time -f '%U %S %M'`, which the benchmark
// used to call, is a GNU coreutils program and has no Windows equivalent.
// Bash's own `time` builtin is not a substitute there: under MSYS it
// accounts only for MSYS processes, and reports zero user time for a
// native Windows child that has just burned a core for a second.
//
// Go is a slightly odd choice of language for a two-syscall program, and
// it is the right one here: os/exec already reports child CPU time on both
// systems through ProcessState, so the only part that needs writing twice
// is the peak resident set.  The benchmark needs a Go toolchain anyway.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: runwait <report-file> <command> [args...]")
		os.Exit(2)
	}
	report, argv := os.Args[1], os.Args[2:]

	// NAME=VALUE prefixes, as env(1) takes them.
	environment := os.Environ()
	for len(argv) > 1 && strings.Contains(argv[0], "=") &&
		!strings.ContainsAny(argv[0], `/\`) {
		environment = append(environment, argv[0])
		argv = argv[1:]
	}
	if len(argv) == 0 {
		fmt.Fprintln(os.Stderr, "runwait: no command")
		os.Exit(2)
	}

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = environment
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin

	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "runwait: %v\n", err)
		os.Exit(127)
	}

	// Windows needs a handle of its own on the child, opened now and held
	// past the exit: the peak working set is only readable while some
	// handle to the process object survives, and os/exec closes its own in
	// Wait.  On Linux this arranges nothing and the number comes from wait4.
	peakRSS := watchMemory(cmd)

	// A benchmark that gives up on a server kills this wrapper, and the
	// child would otherwise be left holding the port.  Pass the signal on.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-signals
		_ = cmd.Process.Kill()
	}()

	// The child's own deadline, if one was asked for.
	timedOut := make(chan struct{})
	if limit := timeoutSeconds(); limit > 0 {
		stop := time.AfterFunc(limit, func() {
			close(timedOut)
			_ = cmd.Process.Kill()
		})
		defer stop.Stop()
	}

	err := cmd.Wait()
	status := 0
	if err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			status = exit.ExitCode()
		} else {
			fmt.Fprintf(os.Stderr, "runwait: %v\n", err)
			status = 127
		}
	}

	select {
	case <-timedOut:
		status = 124
	default:
	}

	user := cmd.ProcessState.UserTime().Seconds()
	system := cmd.ProcessState.SystemTime().Seconds()
	fmt.Fprintf(mustCreate(report), "%.3f %.3f %d\n", user, system, peakRSS())

	os.Exit(status)
}

func timeoutSeconds() time.Duration {
	raw, ok := os.LookupEnv("RUNWAIT_TIMEOUT_S")
	if !ok {
		return 0
	}
	n, err := strconv.ParseFloat(raw, 64)
	if err != nil || n <= 0 {
		return 0
	}
	return time.Duration(n * float64(time.Second))
}

func mustCreate(path string) *os.File {
	f, err := os.Create(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "runwait: %v\n", err)
		os.Exit(127)
	}
	return f
}
