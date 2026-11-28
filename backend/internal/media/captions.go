package media

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"connectrpc.com/connect"
	"google.golang.org/api/speech/v1"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	mediav1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/media/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

const (
	maxCaptionAudioBytes = 180 * 1024 // fits the 256 KiB request cap even with JSON base64
	maxCaptionAudioTime  = 55 * time.Second
)

var captionLanguage = regexp.MustCompile(`^[a-z]{2,3}(?:-[a-zA-Z0-9]{2,8}){0,3}$`)

type CaptionRecognizer interface {
	Recognize(context.Context, []byte, string, time.Duration) ([]*mediav1.VideoCaptionCue, error)
}

func (s *Server) TranscribeVideoAudio(ctx context.Context, req *connect.Request[mediav1.TranscribeVideoAudioRequest]) (*connect.Response[mediav1.TranscribeVideoAudioResponse], error) {
	if _, err := s.guard(ctx); err != nil {
		return nil, err
	}
	if s.captions == nil {
		return nil, apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "Automatic captions are unavailable. You can import a caption file.")
	}
	audio, language := req.Msg.GetOggOpus(), req.Msg.GetLanguageCode()
	if !captionLanguage.MatchString(language) {
		return nil, apierr.Validation("language_code", "Choose a valid caption language.")
	}
	duration := opusDuration(audio)
	if duration <= 0 || duration > maxCaptionAudioTime {
		return nil, apierr.Validation("ogg_opus", "Choose a mono Ogg Opus segment up to 55 seconds.")
	}
	ctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	cues, err := s.captions.Recognize(ctx, audio, language, duration)
	if err != nil {
		// Provider diagnostics can include request details. Keep audio and
		// transcripts out of public errors and application logs.
		return nil, apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "Could not generate captions. Try again or import a caption file.")
	}
	return connect.NewResponse(&mediav1.TranscribeVideoAudioResponse{Cues: cues}), nil
}

// opusDuration reads the single Ogg stream's final granule position. Opus
// counts granules at 48 kHz, independently of the input sample rate.
func opusDuration(audio []byte) time.Duration {
	if len(audio) < 47 || len(audio) > maxCaptionAudioBytes {
		return 0
	}
	var serial uint32
	var preSkip uint64
	var granule uint64
	for first := true; len(audio) > 0; first = false {
		if len(audio) < 27 || string(audio[:4]) != "OggS" || audio[4] != 0 {
			return 0
		}
		pageSerial := binary.LittleEndian.Uint32(audio[14:18])
		header := 27 + int(audio[26])
		if header > len(audio) {
			return 0
		}
		next := header
		for _, lacing := range audio[27:header] {
			next += int(lacing)
		}
		if next > len(audio) {
			return 0
		}
		if first {
			if audio[5]&2 == 0 || next-header < 19 ||
				string(audio[header:header+8]) != "OpusHead" || audio[header+9] != 1 {
				return 0
			}
			serial = pageSerial
			preSkip = uint64(binary.LittleEndian.Uint16(audio[header+10 : header+12]))
		} else if pageSerial != serial || audio[5]&2 != 0 {
			return 0
		}
		last := next == len(audio)
		if (audio[5]&4 != 0) != last {
			return 0
		}
		granule = binary.LittleEndian.Uint64(audio[6:14])
		audio = audio[next:]
	}
	if granule <= preSkip || granule-preSkip > uint64(maxCaptionAudioTime/time.Second)*48000 {
		return 0
	}
	return time.Duration(granule-preSkip) * time.Second / 48000
}

// GoogleCaptions uses Application Default Credentials. The service is only
// attached to the route when VIDEO_CAPTIONS is enabled.
type GoogleCaptions struct{}

func (GoogleCaptions) Recognize(ctx context.Context, audio []byte, language string, duration time.Duration) ([]*mediav1.VideoCaptionCue, error) {
	client, err := speech.NewService(ctx)
	if err != nil {
		return nil, err
	}
	resp, err := client.Speech.Recognize(&speech.RecognizeRequest{
		Audio: &speech.RecognitionAudio{Content: base64.StdEncoding.EncodeToString(audio)},
		Config: &speech.RecognitionConfig{
			Encoding: "OGG_OPUS", SampleRateHertz: 16000, LanguageCode: language,
			EnableWordTimeOffsets: true, EnableAutomaticPunctuation: true,
		},
	}).Context(ctx).Do()
	if err != nil {
		return nil, err
	}
	return timedCues(resp.Results, duration), nil
}

func timedCues(results []*speech.SpeechRecognitionResult, duration time.Duration) []*mediav1.VideoCaptionCue {
	var cues []*mediav1.VideoCaptionCue
	var segmentStart, segmentEnd time.Duration
	var line string
	flush := func() {
		if line == "" {
			return
		}
		cues = append(cues, &mediav1.VideoCaptionCue{
			StartMs: int32(segmentStart.Milliseconds()), // duration is bounded at validation
			EndMs:   int32(segmentEnd.Milliseconds()),
			Text:    line,
		})
		line = ""
	}
	for _, result := range results {
		if len(result.Alternatives) == 0 {
			continue
		}
		for _, word := range result.Alternatives[0].Words {
			start, _ := time.ParseDuration(word.StartTime)
			end, err := time.ParseDuration(word.EndTime)
			start = max(start, segmentEnd)
			end = min(end, duration)
			text := strings.TrimSpace(word.Word)
			if err != nil || end.Milliseconds() <= start.Milliseconds() ||
				text == "" || utf8.RuneCountInString(text) > 100 {
				continue
			}
			if line != "" && (end-segmentStart > 5*time.Second ||
				start-segmentEnd > time.Second || utf8.RuneCountInString(line+" "+text) > 100) {
				flush()
			}
			if line == "" {
				segmentStart = start
				line = text
			} else {
				line += " " + text
			}
			segmentEnd = end
		}
	}
	flush()
	return cues
}
