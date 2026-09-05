// Package echo holds the shared pieces for the Go side of the comparison:
// the same 32-byte wire format the Ada demo and bench/tokio_echo speak, and
// the same CPU pinning the Ada runtime does with `CPU =>` aspects.
package echo

import (
	"os"
	"strconv"
	"strings"
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
