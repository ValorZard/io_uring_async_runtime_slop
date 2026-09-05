//go:build linux

package main

import (
	"os/exec"
	"syscall"
)

// watchMemory has nothing to arrange in advance: wait4 reports the peak
// resident set with the exit status, which is where `/usr/bin/time -f %M`
// gets its number too.
func watchMemory(cmd *exec.Cmd) func() int64 {
	return func() int64 {
		if usage, ok := cmd.ProcessState.SysUsage().(*syscall.Rusage); ok {
			return usage.Maxrss
		}
		return 0
	}
}
