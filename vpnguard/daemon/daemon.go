package daemon

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"

	"vpnguard/config"
)

type AlertSender interface {
	SendAlert(nodeName string, alert *Alert) error
}

type AIAnalyzer interface {
	Analyze(logs []string) (string, error)
}

type Monitor struct {
	cfg    *config.Config
	alerts AlertSender
	ai     AIAnalyzer
	scorer *Scorer
	logger *log.Logger
}

func NewMonitor(cfg *config.Config, alerts AlertSender, ai AIAnalyzer) *Monitor {
	return &Monitor{
		cfg:    cfg,
		alerts: alerts,
		ai:     ai,
		scorer: NewScorer(cfg),
		logger: log.New(os.Stdout, "vpnguard: ", log.LstdFlags),
	}
}

func (m *Monitor) Run() error {
	if err := os.MkdirAll(filepath.Dir(m.cfg.AlertLog), 0o755); err != nil {
		return err
	}

	go m.gcLoop()
	return m.tailFile()
}

func (m *Monitor) gcLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for now := range ticker.C {
		m.scorer.GC(now)
	}
}

func (m *Monitor) tailFile() error {
	dir := filepath.Dir(m.cfg.LogFile)
	fileName := filepath.Base(m.cfg.LogFile)
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer watcher.Close()

	if err := watcher.Add(dir); err != nil {
		return err
	}

	var file *os.File
	var offset int64

	openCurrent := func(seekEnd bool) error {
		if file != nil {
			_ = file.Close()
			file = nil
		}
		f, err := os.Open(m.cfg.LogFile)
		if err != nil {
			return err
		}
		file = f
		if seekEnd {
			info, err := file.Stat()
			if err != nil {
				return err
			}
			offset = info.Size()
			_, err = file.Seek(offset, 0)
			return err
		}
		offset = 0
		m.logger.Printf("opened log file: %s", fileName)
		return nil
	}

	if err := openCurrent(true); err != nil {
		m.logger.Printf("warning: could not open log file initially: %v", err)
	}

	pollTicker := time.NewTicker(2 * time.Second)
	defer pollTicker.Stop()

	for {
		if err := m.readNewLines(file, &offset); err != nil {
			m.logger.Printf("read error: %v", err)
			time.Sleep(2 * time.Second)
			if reopenErr := openCurrent(false); reopenErr != nil {
				m.logger.Printf("reopen error: %v", reopenErr)
			}
		}

		select {
		case event := <-watcher.Events:
			if filepath.Base(event.Name) == fileName {
				if event.Has(fsnotify.Remove) || event.Has(fsnotify.Rename) || event.Has(fsnotify.Create) {
					if err := openCurrent(false); err != nil {
						m.logger.Printf("reopen after rotate failed: %v", err)
					}
				}
			}
		case err := <-watcher.Errors:
			m.logger.Printf("watch error: %v", err)
		case <-pollTicker.C:
		}
	}
}

func (m *Monitor) readNewLines(file *os.File, offset *int64) error {
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if info.Size() < *offset {
		*offset = 0
	}
	if _, err := file.Seek(*offset, 0); err != nil {
		return err
	}

	reader := bufio.NewReader(file)

	for {
		lineBytes, err := reader.ReadBytes('\n')
		if len(lineBytes) > 0 && lineBytes[len(lineBytes)-1] == '\n' {
			*offset += int64(len(lineBytes))
			line := strings.TrimRight(string(lineBytes), "\r\n")

			if strings.Contains(line, "BLOCK") {
				continue
			}

			entry, parseErr := ParseLine(line)
			if parseErr == nil && entry.SourceIP != "" && entry.SourceIP != "127.0.0.1" && entry.SourceIP != "::1" {
				if alert := m.scorer.Add(entry); alert != nil {
					if recErr := m.recordAlert(alert); recErr != nil {
						m.logger.Printf("alert log error: %v", recErr)
					}
					go m.processAlertAsync(alert, entry.SourceIP)
				}
			}
		}

		if err != nil {
			if err != io.EOF {
				return err
			}
			return nil
		}
	}
}

func (m *Monitor) recordAlert(alert *Alert) error {
	f, err := os.OpenFile(m.cfg.AlertLog, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()

	_, err = fmt.Fprintf(
		f,
		"%s ALERT ip=%s email=%s score=%d target=%s:%s\n",
		time.Now().Format(time.RFC3339),
		alert.IP,
		alert.Email,
		alert.Score,
		alert.Host,
		alert.Port,
	)
	return err
}

func (m *Monitor) processAlertAsync(alert *Alert, ip string) {
	m.logger.Printf("ALERT triggered for %s (Score: %g). Starting processing...", ip, alert.Score)
	
	if m.ai != nil {
		m.logger.Printf("[%s] waiting 30s to collect more context for AI...", ip)
		time.Sleep(30 * time.Second)
		
		recentLogs := m.scorer.GetRecentLogs(ip)
		if len(recentLogs) > 0 {
			alert.RecentLines = recentLogs
		}
		
		aiResult, err := m.ai.Analyze(alert.RecentLines)
		if err != nil {
			m.logger.Printf("gemini api error: %v", err)
			alert.AIError = err.Error()
		} else {
			alert.AIResult = aiResult
		}
	}

	if tgErr := m.alerts.SendAlert(m.cfg.NodeName, alert); tgErr != nil {
		m.logger.Printf("telegram alert failed: %v", tgErr)
	}
}
