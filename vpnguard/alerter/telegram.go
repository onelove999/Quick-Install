package alerter

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"vpnguard/config"
	"vpnguard/daemon"
)

type Telegram struct {
	cfg    *config.Config
	client *http.Client
}

func NewTelegram(cfg *config.Config) *Telegram {
	return &Telegram{
		cfg:    cfg,
		client: &http.Client{Timeout: 5 * time.Second},
	}
}

func (t *Telegram) SendAlert(nodeName string, alert *daemon.Alert) error {
	if strings.TrimSpace(t.cfg.Telegram.BotToken) == "" || strings.TrimSpace(t.cfg.Telegram.ChatID) == "" {
		return nil
	}

	message := fmt.Sprintf(
		"🚨 <b>VPN Guard</b> [%s]\n\nIP: <code>%s</code>\nEmail: <code>%s</code>\nTarget: <code>%s:%s</code>\nScore: <b>%d</b> (limit %d)\n\n<b>Breakdown:</b>\n%s",
		nodeName,
		alert.IP,
		emptyFallback(alert.Email, "unknown"),
		alert.Host,
		alert.Port,
		alert.Score,
		alert.Threshold,
		alert.Breakdown,
	)

	if err := t.sendMessage(message); err != nil {
		return err
	}
	if len(alert.RecentLines) == 0 {
		return nil
	}
	return t.sendDocument(alert)
}

func (t *Telegram) SendReport(nodeName, summary string, fullContent []byte) error {
	if strings.TrimSpace(t.cfg.Telegram.BotToken) == "" || strings.TrimSpace(t.cfg.Telegram.ChatID) == "" {
		return nil
	}

	header := fmt.Sprintf("📊 <b>Report: %s</b>\n\n", nodeName)
	if err := t.sendMessage(header + summary); err != nil {
		return err
	}

	tempFile := filepath.Join(os.TempDir(), fmt.Sprintf("report_%s_%s.txt", sanitizeFilename(nodeName), time.Now().Format("2006-01-02")))
	if err := os.WriteFile(tempFile, fullContent, 0o600); err != nil {
		return err
	}
	defer os.Remove(tempFile)

	return t.sendFileAsDocument(tempFile, "Full analytics report")
}

func (t *Telegram) sendFileAsDocument(filePath, caption string) error {
	file, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer file.Close()

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	if err := writer.WriteField("chat_id", t.cfg.Telegram.ChatID); err != nil {
		return err
	}
	if err := writer.WriteField("caption", caption); err != nil {
		return err
	}
	part, err := writer.CreateFormFile("document", filepath.Base(filePath))
	if err != nil {
		return err
	}
	if _, err := io.Copy(part, file); err != nil {
		return err
	}
	if err := writer.Close(); err != nil {
		return err
	}

	req, err := http.NewRequest(http.MethodPost, t.apiURL("sendDocument"), &body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", writer.FormDataContentType())

	resp, err := t.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("telegram sendDocument returned %s", resp.Status)
	}
	return nil
}

func (t *Telegram) sendMessage(text string) error {
	payload := map[string]string{
		"chat_id":                  t.cfg.Telegram.ChatID,
		"text":                     text,
		"parse_mode":               "HTML",
		"disable_web_page_preview": "true",
	}

	body, _ := json.Marshal(payload)
	req, err := http.NewRequest(http.MethodPost, t.apiURL("sendMessage"), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := t.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("telegram sendMessage returned %s", resp.Status)
	}
	return nil
}

func (t *Telegram) sendDocument(alert *daemon.Alert) error {
	tempFile := filepath.Join(os.TempDir(), fmt.Sprintf("vpnguard_%s.log", sanitizeFilename(alert.IP)))
	content := strings.Join(lastLines(alert.RecentLines, 30), "\n") + "\n"
	if err := os.WriteFile(tempFile, []byte(content), 0o600); err != nil {
		return err
	}
	defer os.Remove(tempFile)

	return t.sendFileAsDocument(tempFile, fmt.Sprintf("Recent log lines for %s", alert.IP))
}

func (t *Telegram) apiURL(method string) string {
	return fmt.Sprintf("https://api.telegram.org/bot%s/%s", t.cfg.Telegram.BotToken, method)
}

func sanitizeFilename(value string) string {
	replacer := strings.NewReplacer(":", "_", "/", "_", "\\", "_")
	return replacer.Replace(value)
}

func lastLines(lines []string, limit int) []string {
	if len(lines) <= limit {
		return lines
	}
	return lines[len(lines)-limit:]
}

func emptyFallback(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}
