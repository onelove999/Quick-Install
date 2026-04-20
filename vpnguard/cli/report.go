package cli

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strings"

	"vpnguard/alerter"
	"vpnguard/config"
	"vpnguard/daemon"
)

type offenderScore struct {
	Email string
	IP    string
	Score int
}

func RunReport(cfg *config.Config, tg *alerter.Telegram) error {
	files, err := collectLogFiles(cfg.LogFile)
	if err != nil {
		return err
	}
	if len(files) == 0 {
		return fmt.Errorf("no log files found near %s", cfg.LogFile)
	}

	stats := map[string]int{"tcp": 0, "udp": 0, "total": 0}
	blocked := map[string]int{}
	emailIPs := map[string]map[string]struct{}{}
	suspiciousPorts := map[string]int{}
	offenders := map[string]int{}
	scorer := daemon.NewScorer(cfg)

	for _, file := range files {
		err := readLines(file, func(line string) error {
			stats["total"]++
			if strings.Contains(line, "tcp:") {
				stats["tcp"]++
			}
			if strings.Contains(line, "udp:") {
				stats["udp"]++
			}
			if strings.Contains(line, "-> BLOCK") || strings.Contains(line, ">> BLOCK") {
				entry, err := daemon.ParseLine(line)
				if err == nil {
					host, _ := daemon.SplitDestination(entry.Destination)
					blocked[host]++
				}
			}

			entry, err := daemon.ParseLine(line)
			if err != nil {
				return nil
			}

			if entry.Email != "" {
				if _, ok := emailIPs[entry.Email]; !ok {
					emailIPs[entry.Email] = map[string]struct{}{}
				}
				emailIPs[entry.Email][entry.SourceIP] = struct{}{}
			}

			host, port := daemon.SplitDestination(entry.Destination)
			_ = host
			if isSuspicious(cfg, port) {
				suspiciousPorts[port]++
			}
			if alert := scorer.Add(entry); alert != nil {
				key := fmt.Sprintf("%s|%s", alert.Email, alert.IP)
				offenders[key] = alert.Score
			}
			return nil
		})
		if err != nil {
			return err
		}
	}

	reportLines := make([]string, 0, 64)
	reportLines = append(reportLines, "=== VPN Guard Report ===", "")
	reportLines = append(reportLines,
		fmt.Sprintf("Total lines: %d", stats["total"]),
		fmt.Sprintf("TCP: %d", stats["tcp"]),
		fmt.Sprintf("UDP: %d", stats["udp"]),
		"",
		"Top blocked destinations:",
	)
	reportLines = append(reportLines, topMap(blocked, 10)...)

	reportLines = append(reportLines, "", "Emails with many unique IPs:")
	reportLines = append(reportLines, summarizeEmailIPs(emailIPs)...)

	reportLines = append(reportLines, "", "Top suspicious ports:")
	reportLines = append(reportLines, topMap(suspiciousPorts, 10)...)

	reportLines = append(reportLines, "", "Top offenders by score:")
	reportLines = append(reportLines, topOffenders(offenders, 10)...)

	output := strings.Join(reportLines, "\n") + "\n"
	fmt.Println(output)

	reader := bufio.NewReader(os.Stdin)
	outPath := prompt(reader, "Output file [report.txt]: ")
	if strings.TrimSpace(outPath) == "" {
		outPath = "report.txt"
	}
	if err := os.WriteFile(outPath, []byte(output), 0o644); err != nil {
		return err
	}
	fmt.Printf("Report saved to %s\n", outPath)

	var sendTg string
	for {
		sendTg = strings.ToLower(prompt(reader, "Send report to Telegram? [y/n]: "))
		if sendTg == "y" || sendTg == "n" {
			break
		}
		fmt.Println("Please enter 'y' (Yes) or 'n' (No).")
	}

	if sendTg == "y" {
		fmt.Println("Sending to Telegram...")
		summary := extractSummary(reportLines)
		if err := tg.SendReport(cfg.NodeName, summary, []byte(output)); err != nil {
			return fmt.Errorf("send telegram: %w", err)
		}
		fmt.Println("Sent successfully.")
	}
	return nil
}

func extractSummary(lines []string) string {
	var summary []string
	capture := true
	for _, line := range lines {
		if strings.Contains(line, "Emails with many unique IPs") {
			capture = false
		}
		if capture && line != "" && !strings.Contains(line, "===") {
			summary = append(summary, line)
		}
	}
	if len(summary) > 15 {
		summary = summary[:15]
		summary = append(summary, "...")
	}
	return strings.Join(summary, "\n")
}

func isSuspicious(cfg *config.Config, port string) bool {
	for _, item := range cfg.Scoring.SuspiciousPorts {
		if item == port {
			return true
		}
	}
	return false
}

func topMap(items map[string]int, limit int) []string {
	if len(items) == 0 {
		return []string{"- no data"}
	}

	type pair struct {
		Key   string
		Value int
	}
	rows := make([]pair, 0, len(items))
	for key, value := range items {
		rows = append(rows, pair{Key: key, Value: value})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Value == rows[j].Value {
			return rows[i].Key < rows[j].Key
		}
		return rows[i].Value > rows[j].Value
	})
	if len(rows) > limit {
		rows = rows[:limit]
	}

	out := make([]string, 0, len(rows))
	for _, row := range rows {
		out = append(out, fmt.Sprintf("- %s: %d", row.Key, row.Value))
	}
	return out
}

func summarizeEmailIPs(emailIPs map[string]map[string]struct{}) []string {
	if len(emailIPs) == 0 {
		return []string{"- no data"}
	}

	type pair struct {
		Email string
		Count int
	}
	rows := make([]pair, 0, len(emailIPs))
	for email, ips := range emailIPs {
		rows = append(rows, pair{Email: email, Count: len(ips)})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Count == rows[j].Count {
			return rows[i].Email < rows[j].Email
		}
		return rows[i].Count > rows[j].Count
	})

	limit := 10
	if len(rows) > limit {
		rows = rows[:limit]
	}
	out := make([]string, 0, len(rows))
	for _, row := range rows {
		label := "normal"
		switch {
		case row.Count > 35:
			label = "anomaly"
		case row.Count > 10:
			label = "suspicious"
		case row.Count > 2:
			label = "notice"
		}
		out = append(out, fmt.Sprintf("- %s: %d unique IPs (%s)", row.Email, row.Count, label))
	}
	return out
}

func topOffenders(items map[string]int, limit int) []string {
	if len(items) == 0 {
		return []string{"- no alerts triggered in historical replay"}
	}
	rows := make([]offenderScore, 0, len(items))
	for key, score := range items {
		parts := strings.SplitN(key, "|", 2)
		email := ""
		ip := key
		if len(parts) == 2 {
			email = parts[0]
			ip = parts[1]
		}
		rows = append(rows, offenderScore{Email: email, IP: ip, Score: score})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Score == rows[j].Score {
			return rows[i].IP < rows[j].IP
		}
		return rows[i].Score > rows[j].Score
	})
	if len(rows) > limit {
		rows = rows[:limit]
	}
	out := make([]string, 0, len(rows))
	for _, row := range rows {
		out = append(out, fmt.Sprintf("- %s (%s): %d", row.IP, empty(row.Email, "unknown"), row.Score))
	}
	return out
}

func empty(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}
