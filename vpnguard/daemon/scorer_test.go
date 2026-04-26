package daemon

import (
	"testing"
	"time"

	"vpnguard/config"
)

func TestScorerTriggersThreshold(t *testing.T) {
	cfg := &config.Config{}
	cfg.Scoring.Threshold = 60
	cfg.Scoring.WindowSeconds = 60
	cfg.Scoring.Cooldown = 120
	cfg.Scoring.Points.Domain = 1
	cfg.Scoring.Points.IP = 3
	cfg.Scoring.Points.Spam = 100
	cfg.Scoring.Points.LocalNet = 10
	cfg.Scoring.Points.SSH = 50
	cfg.Scoring.Points.SuspiciousPort = 30
	cfg.Scoring.SpamPorts = []string{"25"}
	cfg.Scoring.SuspiciousPorts = []string{"22", "23"}
	cfg.Scoring.LocalNets = []string{"192.168."}

	scorer := NewScorer(cfg)
	entry := &Entry{
		Timestamp:   time.Now(),
		SourceIP:    "1.2.3.4",
		Destination: "tcp:8.8.8.8:22",
		Email:       "42",
		Raw:         "test",
	}

	first := scorer.Add(entry)
	if first != nil {
		t.Fatalf("expected no alert after first hit")
	}

	entry.Timestamp = entry.Timestamp.Add(5 * time.Second)
	second := scorer.Add(entry)
	if second == nil {
		t.Fatalf("expected alert after threshold reached")
	}
	if second.Score != 100.0 {
		t.Fatalf("unexpected score: %g", second.Score)
	}
}
