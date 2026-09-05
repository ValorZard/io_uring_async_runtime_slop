// Package echo holds the shared pieces for the Go side of the comparison:
// the same 32-byte wire format the Ada demo and bench/tokio_echo speak, and
// the same CPU pinning the Ada runtime does with `CPU =>` aspects.
package echo

import (
	"os"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

const (
	FrameSize   = 32
	DigitsFirst = 6
	DigitsLast  = 14
	MaxSequence = 999_999_999
)

type Frame = [FrameSize]byte

type Kind int

const (
	Ping Kind = iota
	Pong
	Farewell
	Malformed
)

func tag(k Kind) string {
	switch k {
	case Ping:
		return "PING"
	case Pong:
		return "PONG"
	case Farewell:
		return "BYE "
	default:
		return "????"
	}
}

// Build writes byte-for-byte what Echo_Protocol.Build produces: the
// four-character tag, then the sequence right-aligned in the digit field,
// spaces elsewhere.
func Build(kind Kind, sequence uint32, into *Frame) {
	for i := range into {
		into[i] = ' '
	}
	copy(into[0:4], tag(kind))

	rest := sequence
	if rest > MaxSequence {
		rest = MaxSequence
	}
	for i := DigitsLast; i >= DigitsFirst; i-- {
		into[i] = byte('0' + rest%10)
		rest /= 10
	}
}

func Parse(from *Frame) (Kind, uint32) {
	var kind Kind
	switch string(from[0:4]) {
	case "PING":
		kind = Ping
	case "PONG":
		kind = Pong
	case "BYE ":
		kind = Farewell
	default:
		return Malformed, 0
	}

	var value uint32
	for i := DigitsFirst; i <= DigitsLast; i++ {
		d := from[i]
		if d < '0' || d > '9' {
			return Malformed, 0
		}
		value = value*10 + uint32(d-'0')
	}
	return kind, value
}

// CPUList parses a "1,2,3,4" CPU list out of an environment variable.
func CPUList(name string) []int {
	raw, ok := os.LookupEnv(name)
	if !ok || strings.TrimSpace(raw) == "" {
		return nil
	}
	var out []int
	for _, piece := range strings.Split(raw, ",") {
		piece = strings.TrimSpace(piece)
		if piece == "" {
			continue
		}
		if n, err := strconv.Atoi(piece); err == nil && n >= 0 {
			out = append(out, n)
		}
	}
	return out
}

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

// ArgOr reads a positional argument (0-indexed, after the program name),
// falling back when it is missing or not a number.
func ArgOr(args []string, index int, fallback uint32) uint32 {
	if index >= len(args) {
		return fallback
	}
	n, err := strconv.ParseUint(args[index], 10, 32)
	if err != nil {
		return fallback
	}
	return uint32(n)
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
