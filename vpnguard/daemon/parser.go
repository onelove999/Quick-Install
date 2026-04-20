package daemon

import (
	"errors"
	"regexp"
	"strings"
	"time"
)

var emailRegexp = regexp.MustCompile(`email:\s*([^\s]+)`)

type Entry struct {
	Timestamp   time.Time
	RawTime     string
	SourceIP    string
	Destination string
	Email       string
	Raw         string
}

func ParseLine(line string) (*Entry, error) {
	line = strings.TrimSpace(line)
	if line == "" {
		return nil, errors.New("empty line")
	}
	if !strings.Contains(line, " accepted ") {
		return nil, errors.New("not an accepted entry")
	}

	parts := strings.Fields(line)
	acceptedIndex := -1
	for i, part := range parts {
		if part == "accepted" {
			acceptedIndex = i
			break
		}
	}
	if acceptedIndex < 1 || acceptedIndex+1 >= len(parts) {
		return nil, errors.New("malformed accepted record")
	}

	rawTime := firstChars(line, 19)
	ts, err := time.Parse("2006/01/02 15:04:05", rawTime)
	if err != nil {
		return nil, err
	}

	source := normalizeEndpoint(parts[acceptedIndex-1])
	dest := parts[acceptedIndex+1]
	email := ""
	if match := emailRegexp.FindStringSubmatch(line); len(match) == 2 {
		email = match[1]
	}

	return &Entry{
		Timestamp:   ts,
		RawTime:     rawTime,
		SourceIP:    extractHost(source),
		Destination: dest,
		Email:       email,
		Raw:         line,
	}, nil
}

func firstChars(value string, n int) string {
	if len(value) < n {
		return value
	}
	return value[:n]
}

func normalizeEndpoint(value string) string {
	value = strings.TrimSpace(value)
	value = strings.TrimPrefix(value, "tcp:")
	value = strings.TrimPrefix(value, "udp:")
	return value
}

func extractHost(endpoint string) string {
	endpoint = normalizeEndpoint(endpoint)
	if idx := strings.LastIndex(endpoint, ":"); idx != -1 {
		return endpoint[:idx]
	}
	return endpoint
}

func SplitDestination(destination string) (host, port string) {
	destination = normalizeEndpoint(destination)
	if idx := strings.LastIndex(destination, ":"); idx != -1 {
		return destination[:idx], destination[idx+1:]
	}
	return destination, ""
}

func IsIPAddress(host string) bool {
	if host == "" {
		return false
	}
	dot := false
	for _, r := range host {
		switch {
		case r >= '0' && r <= '9':
		case r == '.':
			dot = true
		default:
			return false
		}
	}
	return dot
}
