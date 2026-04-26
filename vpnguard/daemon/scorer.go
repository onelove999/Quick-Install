package daemon

import (
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"vpnguard/config"
)

type ScoreEvent struct {
	Time     time.Time
	Points   float64
	Category string
	Raw      string
}

type IPState struct {
	Events         []ScoreEvent
	LastAlert      time.Time
	LastSeen       time.Time
	RecentLogLines []string
}

type Alert struct {
	IP          string
	Email       string
	Host        string
	Port        string
	Score       float64
	Threshold   float64
	Breakdown   string
	RecentLines []string
	AIResult    string
	AIError     string
}

type Scorer struct {
	cfg    *config.Config
	mu     sync.Mutex
	states map[string]*IPState
}

func NewScorer(cfg *config.Config) *Scorer {
	return &Scorer{
		cfg:    cfg,
		states: make(map[string]*IPState),
	}
}

func (s *Scorer) Add(entry *Entry) *Alert {
	if entry == nil || entry.SourceIP == "" {
		return nil
	}

	host, port := SplitDestination(entry.Destination)
	category, points := s.classify(host, port)
	if points <= 0.0 {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	state := s.ensureState(entry.SourceIP)
	now := entry.Timestamp
	state.LastSeen = now
	state.RecentLogLines = append(state.RecentLogLines, entry.Raw)
	if len(state.RecentLogLines) > 5000 {
		state.RecentLogLines = append([]string(nil), state.RecentLogLines[len(state.RecentLogLines)-5000:]...)
	}

	state.Events = append(state.Events, ScoreEvent{
		Time:     now,
		Points:   points,
		Category: category,
		Raw:      entry.Raw,
	})
	s.pruneEvents(state, now)

	// Flood detection: count total events in window
	totalEvents := len(state.Events)
	floodExtra := 0.0
	if s.cfg.Scoring.FloodThreshold > 0 && totalEvents > s.cfg.Scoring.FloodThreshold {
		floodExtra = float64(totalEvents-s.cfg.Scoring.FloodThreshold) * s.cfg.Scoring.Points.Flood
	}

	score := 0.0
	breakdown := map[string]struct {
		count int
		total float64
	}{}
	for _, event := range state.Events {
		score += event.Points
		item := breakdown[event.Category]
		item.count++
		item.total += event.Points
		breakdown[event.Category] = item
	}

	// Add flood penalty
	if floodExtra > 0 {
		score += floodExtra
		item := breakdown["flood"]
		item.count = totalEvents - s.cfg.Scoring.FloodThreshold
		item.total = floodExtra
		breakdown["flood"] = item
	}

	if score < s.cfg.Scoring.Threshold {
		return nil
	}
	if !state.LastAlert.IsZero() && now.Sub(state.LastAlert) < time.Duration(s.cfg.Scoring.Cooldown)*time.Second {
		return nil
	}

	state.LastAlert = now
	return &Alert{
		IP:          entry.SourceIP,
		Email:       entry.Email,
		Host:        host,
		Port:        port,
		Score:       score,
		Threshold:   s.cfg.Scoring.Threshold,
		Breakdown:   formatBreakdown(breakdown),
		RecentLines: append([]string(nil), state.RecentLogLines...),
	}
}

func (s *Scorer) GetRecentLogs(ip string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, ok := s.states[ip]
	if !ok {
		return nil
	}
	return append([]string(nil), state.RecentLogLines...)
}

func (s *Scorer) GC(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()

	maxIdle := time.Duration(s.cfg.Scoring.WindowSeconds*4) * time.Second
	for ip, state := range s.states {
		s.pruneEvents(state, now)
		if len(state.Events) == 0 && now.Sub(state.LastSeen) > maxIdle {
			delete(s.states, ip)
		}
	}
}

func (s *Scorer) ensureState(ip string) *IPState {
	state, ok := s.states[ip]
	if !ok {
		state = &IPState{}
		s.states[ip] = state
	}
	return state
}

func (s *Scorer) pruneEvents(state *IPState, now time.Time) {
	windowStart := now.Add(-time.Duration(s.cfg.Scoring.WindowSeconds) * time.Second)
	filtered := state.Events[:0]
	for _, event := range state.Events {
		if !event.Time.Before(windowStart) {
			filtered = append(filtered, event)
		}
	}
	state.Events = filtered
}

func (s *Scorer) classify(host, port string) (string, float64) {
	if port == "53" || port == "853" {
		return "dns", 0.0
	}
	if s.isSpamPort(port) {
		return "spam", s.cfg.Scoring.Points.Spam
	}
	if port == "22" {
		return "ssh", s.cfg.Scoring.Points.SSH
	}
	if s.isSuspiciousPort(port) {
		return "suspicious_port", s.cfg.Scoring.Points.SuspiciousPort
	}
	if IsIPAddress(host) && s.isLocalNet(host) {
		return "local_net", s.cfg.Scoring.Points.LocalNet
	}
	if s.isWhitelisted(host) {
		return "whitelist", s.cfg.Scoring.Points.Whitelist
	}
	if IsIPAddress(host) {
		return "ip", s.cfg.Scoring.Points.IP
	}
	return "domain", s.cfg.Scoring.Points.Domain
}

func (s *Scorer) isSpamPort(port string) bool {
	for _, item := range s.cfg.Scoring.SpamPorts {
		if item == port {
			return true
		}
	}
	return false
}

func (s *Scorer) isSuspiciousPort(port string) bool {
	for _, item := range s.cfg.Scoring.SuspiciousPorts {
		if item == port {
			return true
		}
	}
	return false
}

func (s *Scorer) isLocalNet(host string) bool {
	for _, prefix := range s.cfg.Scoring.LocalNets {
		if strings.HasPrefix(host, prefix) {
			return true
		}
	}
	return false
}

func (s *Scorer) isWhitelisted(host string) bool {
	host = strings.ToLower(host)
	for _, domain := range s.cfg.Whitelist.Domains {
		if strings.Contains(host, strings.ToLower(domain)) {
			return true
		}
	}
	if IsIPAddress(host) {
		for _, prefix := range s.cfg.Whitelist.TrustedIPPrefixes {
			if strings.HasPrefix(host, prefix) {
				return true
			}
		}
	}
	return false
}

func formatBreakdown(breakdown map[string]struct {
	count int
	total float64
}) string {
	type row struct {
		name  string
		count int
		total float64
	}
	rows := make([]row, 0, len(breakdown))
	for name, item := range breakdown {
		rows = append(rows, row{name: name, count: item.count, total: item.total})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].total == rows[j].total {
			return rows[i].name < rows[j].name
		}
		return rows[i].total > rows[j].total
	})

	labels := map[string]string{
		"spam":            "Spam ports",
		"ssh":             "SSH",
		"suspicious_port": "Suspicious ports",
		"local_net":       "Local networks",
		"ip":              "IP traffic",
		"domain":          "Domain traffic",
		"whitelist":       "Whitelist",
		"flood":           "🔥 Flood",
	}

	lines := make([]string, 0, len(rows))
	for _, row := range rows {
		label := labels[row.name]
		if label == "" {
			label = row.name
		}
		lines = append(lines, fmt.Sprintf("  %s: %d hits (+%g)", label, row.count, row.total))
	}
	return strings.Join(lines, "\n")
}
