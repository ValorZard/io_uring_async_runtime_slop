//go:build linux

// The two things the comparison needs from the operating system on Linux,
// and the two places the Go side is not portable.  Both exist so the Go
// binaries are measured under the same conditions as the Ada ones, not
// because Go needs them.
package echo

import (
	"syscall"
	"unsafe"
)

// PinCPUSet restricts the calling OS thread to the given CPUs.  Called
// before any goroutine does real concurrent work, this is enough to pin
// the whole process: every OS thread the Go runtime later creates comes
// from clone(2), which inherits the calling thread's affinity mask, the
// same way the Ada runtime's per-task `CPU =>` aspect fixes each shard.
// Go has no per-worker on_thread_start hook the way tokio's runtime
// builder does, so this is "run only on these cores" rather than tokio's
// "pin worker N to core N" -- close enough for a fairness measure, not a
// correctness one.  Silently does nothing if the list is empty.
func PinCPUSet(cpus []int) {
	if len(cpus) == 0 {
		return
	}
	const bitsPerWord = 64
	const words = 16 // 1024 CPUs, the kernel's default cpu_set_t size
	var set [words]uint64
	for _, c := range cpus {
		if c < 0 || c >= words*bitsPerWord {
			continue
		}
		set[c/bitsPerWord] |= 1 << uint(c%bitsPerWord)
	}
	// sched_setaffinity(pid=0, ...) affects the calling thread.
	syscall.RawSyscall(syscall.SYS_SCHED_SETAFFINITY, 0, uintptr(len(set)*8), uintptr(unsafe.Pointer(&set[0])))
}

// RaiseDescriptorLimit raises RLIMIT_NOFILE to its hard limit and returns
// that limit, or 0 if it could not be read.
func RaiseDescriptorLimit() uint64 {
	var lim syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &lim); err != nil {
		return 0
	}
	lim.Cur = lim.Max
	_ = syscall.Setrlimit(syscall.RLIMIT_NOFILE, &lim)
	return lim.Max
}
