package media

import (
	"encoding/binary"
	"testing"
	"time"

	"google.golang.org/api/speech/v1"
)

func TestCaptionAudioDuration(t *testing.T) {
	head := append([]byte("OpusHead"), 1, 1, 0x38, 1, 0x80, 0x3e, 0, 0, 0, 0, 0)
	pages := func(granule uint64) []byte {
		return append(captionPage(2, 0, head), captionPage(4, granule, []byte{1, 2})...)
	}
	if got := opusDuration(pages(48000 + 312)); got != time.Second {
		t.Fatalf("duration = %v, want 1s", got)
	}
	if got := opusDuration(pages(56*48000 + 312)); got != 0 {
		t.Fatalf("overlong stream accepted: %v", got)
	}
	truncated := pages(48000 + 312)
	if got := opusDuration(truncated[:len(truncated)-1]); got != 0 {
		t.Fatalf("malformed stream accepted: %v", got)
	}
}

func captionPage(flags byte, granule uint64, body []byte) []byte {
	page := make([]byte, 28)
	copy(page, "OggS")
	page[5], page[26], page[27] = flags, 1, byte(len(body))
	binary.LittleEndian.PutUint64(page[6:14], granule)
	return append(page, body...)
}

func TestGoogleWordOffsetsProduceTimedCues(t *testing.T) {
	results := []*speech.SpeechRecognitionResult{{
		Alternatives: []*speech.SpeechRecognitionAlternative{{
			Words: []*speech.WordInfo{
				{Word: "Welcome", StartTime: "0s", EndTime: "0.4s"},
				{Word: "back.", StartTime: "0.4s", EndTime: "0.8s"},
				{Word: "Hello.", StartTime: "2.1s", EndTime: "2.8s"},
			},
		}},
	}}
	got := timedCues(results, 2500*time.Millisecond)
	if len(got) != 2 || got[0].Text != "Welcome back." ||
		got[0].StartMs != 0 || got[0].EndMs != 800 ||
		got[1].StartMs != 2100 || got[1].EndMs != 2500 {
		t.Fatalf("unexpected cues: %v", got)
	}
}
