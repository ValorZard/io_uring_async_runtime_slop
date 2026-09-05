//go:build windows

package main

import (
	"os/exec"
	"syscall"
	"unsafe"
)

// PROCESS_MEMORY_COUNTERS.  Only PeakWorkingSetSize is read; the rest is
// mirrored so the structure is the size GetProcessMemoryInfo expects.
type processMemoryCounters struct {
	cb                         uint32
	pageFaultCount             uint32
	peakWorkingSetSize         uintptr
	workingSetSize             uintptr
	quotaPeakPagedPoolUsage    uintptr
	quotaPagedPoolUsage        uintptr
	quotaPeakNonPagedPoolUsage uintptr
	quotaNonPagedPoolUsage     uintptr
	pagefileUsage              uintptr
	peakPagefileUsage          uintptr
}

var (
	psapi                    = syscall.NewLazyDLL("psapi.dll")
	procGetProcessMemoryInfo = psapi.NewProc("GetProcessMemoryInfo")
	kernel32                 = syscall.NewLazyDLL("kernel32.dll")
	procOpenProcess          = kernel32.NewProc("OpenProcess")
	procCloseHandle          = kernel32.NewProc("CloseHandle")
)

const (
	processQueryInformation = 0x0400
	processVMRead           = 0x0010
)

// watchMemory opens a handle on the child now and reads its peak working
// set through that handle later.
//
// Both halves of that matter.  A process object answers
// GetProcessMemoryInfo after the process has exited, but only while some
// handle to it survives, and os/exec closes its own inside Wait -- so a
// handle opened afterwards, by pid, is opening whatever now has that pid,
// or nothing.  Opening one here and holding it past the exit is what makes
// the number the child's.
func watchMemory(cmd *exec.Cmd) func() int64 {
	handle, _, _ := procOpenProcess.Call(
		uintptr(processQueryInformation|processVMRead), 0,
		uintptr(uint32(cmd.Process.Pid)))

	return func() int64 {
		if handle == 0 {
			return 0
		}
		defer procCloseHandle.Call(handle)

		var counters processMemoryCounters
		counters.cb = uint32(unsafe.Sizeof(counters))
		ok, _, _ := procGetProcessMemoryInfo.Call(
			handle, uintptr(unsafe.Pointer(&counters)), uintptr(counters.cb))
		if ok == 0 {
			return 0
		}
		return int64(counters.peakWorkingSetSize / 1024)
	}
}
