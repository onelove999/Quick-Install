package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"vpnguard/alerter"
	"vpnguard/cli"
	"vpnguard/config"
	"vpnguard/daemon"
)

func main() {
	var (
		configPath  string
		interactive bool
		report      bool
		listModels  bool
	)

	flag.StringVar(&configPath, "config", "/app/vpnguard.yaml", "path to config file")
	flag.BoolVar(&interactive, "interactive", false, "run interactive log filtering")
	flag.BoolVar(&report, "report", false, "generate summary report")
	flag.BoolVar(&listModels, "list-models", false, "list available Qwen models")
	flag.Parse()

	cfg, err := config.Load(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "config error: %v\n", err)
		os.Exit(1)
	}

	tg := alerter.NewTelegram(cfg)

	switch {
	case listModels:
		qwen := alerter.NewQwen(cfg)
		models, err := qwen.ListModels()
		if err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("Available Qwen models:")
		for _, m := range models {
			marker := "  "
			if m == cfg.AI.QwenModel {
				marker = "→ "
			}
			fmt.Printf("%s%s\n", marker, m)
		}
	case interactive:
		if err := cli.RunInteractive(cfg, tg); err != nil {
			fmt.Fprintf(os.Stderr, "interactive mode failed: %v\n", err)
			os.Exit(1)
		}
	case report:
		if err := cli.RunReport(cfg, tg); err != nil {
			fmt.Fprintf(os.Stderr, "report mode failed: %v\n", err)
			os.Exit(1)
		}
	default:
		fmt.Printf("🛡️ VPN Guard starting (Node: %s)\n", cfg.NodeName)
		fmt.Printf("📍 Monitoring: %s\n", cfg.LogFile)

		if cfg.AI.Enabled {
			providers := []string{}
			if strings.TrimSpace(cfg.AI.QwenToken) != "" {
				providers = append(providers, fmt.Sprintf("Qwen %s", cfg.AI.QwenModel))
			}
			if strings.TrimSpace(cfg.AI.GeminiToken) != "" {
				providers = append(providers, "Gemini fallback")
			}
			if len(providers) > 0 {
				fmt.Printf("🤖 AI Analysis: Enabled (%s)\n", strings.Join(providers, " + "))
			} else {
				fmt.Println("🤖 AI Analysis: Enabled but no tokens configured")
			}
		} else {
			fmt.Println("🤖 AI Analysis: Disabled")
		}

		var ai daemon.AIAnalyzer
		if cfg.AI.Enabled {
			chain := alerter.NewAIChain(cfg)
			if chain.HasProviders() {
				ai = chain
			}
		}
		monitor := daemon.NewMonitor(cfg, tg, ai)
		if err := monitor.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "daemon failed: %v\n", err)
			os.Exit(1)
		}
	}
}
