package config

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

type Config struct {
	NodeName string `yaml:"node_name"`
	LogFile  string `yaml:"log_file"`
	AlertLog string `yaml:"alert_log"`

	Telegram TelegramConfig `yaml:"telegram"`
	Scoring  ScoringConfig  `yaml:"scoring"`
	Whitelist WhitelistConfig `yaml:"whitelist"`
}

type TelegramConfig struct {
	BotToken string `yaml:"bot_token"`
	ChatID   string `yaml:"chat_id"`
}

type ScoringConfig struct {
	Threshold     int         `yaml:"threshold"`
	WindowSeconds int         `yaml:"window_seconds"`
	Cooldown      int         `yaml:"alert_cooldown"`
	Points        Points      `yaml:"points"`
	SpamPorts     []string    `yaml:"spam_ports"`
	SuspiciousPorts []string  `yaml:"suspicious_ports"`
	LocalNets     []string    `yaml:"local_nets"`
}

type Points struct {
	Domain         int `yaml:"domain"`
	IP             int `yaml:"ip"`
	Whitelist      int `yaml:"whitelist"`
	Spam           int `yaml:"spam"`
	LocalNet       int `yaml:"local_net"`
	SSH            int `yaml:"ssh"`
	SuspiciousPort int `yaml:"suspicious_port"`
}

type WhitelistConfig struct {
	Domains           []string `yaml:"domains"`
	TrustedIPPrefixes []string `yaml:"trusted_ip_prefixes"`
}

func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse yaml: %w", err)
	}

	applyDefaults(&cfg)
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func applyDefaults(cfg *Config) {
	if cfg.NodeName == "" {
		cfg.NodeName = "VPN Guard"
	}
	if cfg.LogFile == "" {
		cfg.LogFile = "/var/log/remnanode/access.log"
	}
	if cfg.AlertLog == "" {
		cfg.AlertLog = "/var/log/remnanode/guard_alerts.log"
	}

	if cfg.Scoring.Threshold == 0 {
		cfg.Scoring.Threshold = 800
	}
	if cfg.Scoring.WindowSeconds == 0 {
		cfg.Scoring.WindowSeconds = 60
	}
	if cfg.Scoring.Cooldown == 0 {
		cfg.Scoring.Cooldown = 120
	}
	if cfg.Scoring.Points.Domain == 0 {
		cfg.Scoring.Points.Domain = 1
	}
	if cfg.Scoring.Points.IP == 0 {
		cfg.Scoring.Points.IP = 3
	}
	if cfg.Scoring.Points.Spam == 0 {
		cfg.Scoring.Points.Spam = 100
	}
	if cfg.Scoring.Points.LocalNet == 0 {
		cfg.Scoring.Points.LocalNet = 10
	}
	if cfg.Scoring.Points.SSH == 0 {
		cfg.Scoring.Points.SSH = 50
	}
	if cfg.Scoring.Points.SuspiciousPort == 0 {
		cfg.Scoring.Points.SuspiciousPort = 30
	}

	if len(cfg.Scoring.SpamPorts) == 0 {
		cfg.Scoring.SpamPorts = []string{"25", "465", "587"}
	}
	if len(cfg.Scoring.SuspiciousPorts) == 0 {
		cfg.Scoring.SuspiciousPorts = []string{"22", "23", "445", "3389", "1433", "3306"}
	}
	if len(cfg.Scoring.LocalNets) == 0 {
		cfg.Scoring.LocalNets = []string{"192.168.", "10.", "172.16.", "127.0.0.1", "localhost"}
	}
	if len(cfg.Whitelist.Domains) == 0 {
		cfg.Whitelist.Domains = []string{
			"google", "youtube", "googlevideo", "gmail", "gstatic", "doubleclick", "android",
			"facebook", "fbcdn", "instagram", "whatsapp", "meta", "cdninstagram",
			"apple", "icloud", "itunes", "iphone", "push.apple.com",
			"tiktok", "tiktokcdn", "tiktokv",
			"netflix", "nflxvideo",
			"microsoft", "windowsupdate", "azure", "office",
			"amazon", "aws",
			"telegram", "spotify", "cloudflare",
			"yandex", "ya.ru", "kinopoisk", "vk.com", "ok.ru", "vkuser", "userapi", "mail.ru",
			"steam", "valve", "epicgames", "discord",
			"avito", "ozon", "wildberries", "wb.ru",
			"openai", "chatgpt", "anthropic", "claude", "gemini", "deepseek",
			"github", "githubusercontent", "copilot",
		}
	}
	if len(cfg.Whitelist.TrustedIPPrefixes) == 0 {
		cfg.Whitelist.TrustedIPPrefixes = []string{
			"149.154.", "91.108.", "5.28.", "91.105.", "95.161.",
			"2001:67c:", "2001:b28:",
			"173.194.", "74.125.", "142.250.", "142.251.",
			"162.159.", "199.103.", "35.214.",
			"104.16.", "104.17.", "104.18.", "104.19.", "104.20.", "104.21.",
			"172.64.", "172.67.", "199.232.",
			"92.223.", "185.106.",
			"87.240.", "95.163.", "93.186.",
		}
	}
}

func (c *Config) Validate() error {
	if strings.TrimSpace(c.LogFile) == "" {
		return errors.New("log_file is required")
	}
	if c.Scoring.Threshold <= 0 {
		return errors.New("scoring.threshold must be > 0")
	}
	if c.Scoring.WindowSeconds <= 0 {
		return errors.New("scoring.window_seconds must be > 0")
	}
	if c.Scoring.Cooldown < 0 {
		return errors.New("scoring.alert_cooldown must be >= 0")
	}
	return nil
}
