package daemon

import (
	"bufio"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/fsnotify/fsnotify"

	"vpnguard/config"
)

type AlertSender interface {
	SendAlert(nodeName string, alert *Alert) error
}

type Monitor struct {
	cfg    *config.Config
	alerts AlertSender
	scorer *Scorer
	logger *log.Logger
}

func NewMonitor(cfg *config.Config, alerts AlertSender) *Monitor {
	return &Monitor{
		cfg:    cfg,
		alerts: alerts,
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
		return nil
	}

	if err := openCurrent(true); err != nil {
		return fmt.Errorf("open log file: %w", err)
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

	scanner := bufio.NewScanner(file)
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024)

	for scanner.Scan() {
		line := scanner.Text()
		*offset += int64(len(scanner.Bytes()) + 1)
		entry, err := ParseLine(line)
		if err != nil || entry.SourceIP == "" || entry.SourceIP == "127.0.0.1" || entry.SourceIP == "::1" {
			continue
		}
		if alert := m.scorer.Add(entry); alert != nil {
			if err := m.recordAlert(alert); err != nil {
				m.logger.Printf("alert log error: %v", err)
			}
			if err := m.alerts.SendAlert(m.cfg.NodeName, alert); err != nil {
				m.logger.Printf("telegram alert failed: %v", err)
			}
		}
	}
	return scanner.Err()
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
