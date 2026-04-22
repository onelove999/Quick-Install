package main

import (
	"flag"
	"fmt"
	"os"

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
	)

	flag.StringVar(&configPath, "config", "/app/vpnguard.yaml", "path to config file")
	flag.BoolVar(&interactive, "interactive", false, "run interactive log filtering")
	flag.BoolVar(&report, "report", false, "generate summary report")
	flag.Parse()

	cfg, err := config.Load(configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "config error: %v\n", err)
		os.Exit(1)
	}

	tg := alerter.NewTelegram(cfg)

	switch {
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
			fmt.Println("🤖 AI Analysis: Enabled (Gemini 2.5 Flash)")
		} else {
			fmt.Println("🤖 AI Analysis: Disabled")
		}

		var ai daemon.AIAnalyzer
		if cfg.AI.Enabled {
			ai = alerter.NewGemini(cfg)
		}
		monitor := daemon.NewMonitor(cfg, tg, ai)
		if err := monitor.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "daemon failed: %v\n", err)
			os.Exit(1)
		}
	}
}
