//go:build windows

// The Windows halves of the two platform-dependent helpers.  Both are here
// so the Go binaries are measured under the same conditions as the Ada
// ones: a fixed set of cores, and a descriptor ceiling the banner can
// report.
package echo

import "syscall"

var (
	kernel32               = syscall.NewLazyDLL("kernel32.dll")
	procGetCurrentProcess  = kernel32.NewProc("GetCurrentProcess")
	procSetProcessAffinity = kernel32.NewProc("SetProcessAffinityMask")
)

// PinCPUSet restricts the whole process to the given CPUs.
//
// Process-wide rather than per-thread, which is the same compromise the
// Linux half makes and for a related reason: Go has no per-worker
// on_thread_start hook the way tokio's runtime builder does, so this is
// "run only on these cores" rather than "pin worker N to core N".  Every
// thread the Go runtime creates afterwards inherits the process mask, so
// setting it before any goroutine does real work is enough.
//
// Silently does nothing if the list is empty, or names a CPU past the
// calling process's processor group.
func PinCPUSet(cpus []int) {
	if len(cpus) == 0 {
		return
	}
	var mask uintptr
	for _, c := range cpus {
		if c < 0 || c >= 64 {
			continue
		}
		mask |= 1 << uint(c)
	}
	if mask == 0 {
		return
	}
	handle, _, _ := procGetCurrentProcess.Call()
	_, _, _ = procSetProcessAffinity.Call(handle, mask)
}

// RaiseDescriptorLimit has nothing to raise.  Windows sets a per-process
// ceiling of 16,777,216 handles in the kernel and offers no knob for it,
// and nothing in between refuses a socket the way a 1024-descriptor soft
// limit does on Linux.  Reporting the real ceiling keeps the banner
// comparable with the other two servers'.
func RaiseDescriptorLimit() uint64 {
	return 16_777_216
}
