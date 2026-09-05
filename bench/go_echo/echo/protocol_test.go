package echo

import "testing"

// The wire format is what every implementation in the comparison has to
// agree on byte for byte: a four-character tag, then the sequence
// right-aligned in the nine-column digit field, spaces everywhere else.
func TestBuildMatchesFixedLayout(t *testing.T) {
	cases := []struct {
		kind   Kind
		tag    string
		seq    uint32
		digits string
	}{
		{Ping, "PING", 1, "000000001"},
		{Pong, "PONG", 42, "000000042"},
		{Farewell, "BYE ", 0, "000000000"},
	}
	for _, c := range cases {
		want := c.tag + "  " + c.digits + "                 " // 4 + 2 + 9 + 17 = 32
		if len(want) != FrameSize {
			t.Fatalf("test bug: want is %d bytes, not %d", len(want), FrameSize)
		}
		var f Frame
		Build(c.kind, c.seq, &f)
		if got := string(f[:]); got != want {
			t.Errorf("Build(%v, %d) = %q, want %q", c.kind, c.seq, got, want)
		}
	}
}

func TestBuildClampsSequence(t *testing.T) {
	var f Frame
	Build(Ping, MaxSequence+1000, &f)
	_, seq := Parse(&f)
	if seq != MaxSequence {
		t.Errorf("sequence = %d, want %d", seq, MaxSequence)
	}
}

func TestParseRoundTrip(t *testing.T) {
	var f Frame
	for _, k := range []Kind{Ping, Pong, Farewell} {
		Build(k, 12345, &f)
		gotKind, gotSeq := Parse(&f)
		if gotKind != k || gotSeq != 12345 {
			t.Errorf("Parse(Build(%v, 12345)) = (%v, %d)", k, gotKind, gotSeq)
		}
	}
}

func TestParseRejectsMalformed(t *testing.T) {
	var f Frame
	for i := range f {
		f[i] = ' '
	}
	copy(f[0:4], "NOPE")
	if kind, _ := Parse(&f); kind != Malformed {
		t.Errorf("Parse(unknown tag) = %v, want Malformed", kind)
	}

	Build(Ping, 1, &f)
	f[DigitsFirst] = 'x'
	if kind, _ := Parse(&f); kind != Malformed {
		t.Errorf("Parse(non-digit) = %v, want Malformed", kind)
	}
}
