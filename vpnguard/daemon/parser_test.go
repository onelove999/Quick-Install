package daemon

import "testing"

func TestParseLine(t *testing.T) {
	line := "2026/04/19 22:00:54.206608 from 178.67.194.50:2664 accepted tcp:www.google.com:443 [VLESS_TCP_REALITY_DE >> DIRECT] email: 294"
	entry, err := ParseLine(line)
	if err != nil {
		t.Fatalf("ParseLine returned error: %v", err)
	}
	if entry.SourceIP != "178.67.194.50" {
		t.Fatalf("unexpected source ip: %s", entry.SourceIP)
	}
	if entry.Email != "294" {
		t.Fatalf("unexpected email: %s", entry.Email)
	}
	host, port := SplitDestination(entry.Destination)
	if host != "www.google.com" || port != "443" {
		t.Fatalf("unexpected destination: %s:%s", host, port)
	}
}
