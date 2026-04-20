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

	switch {
	case interactive:
		if err := cli.RunInteractive(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "interactive mode failed: %v\n", err)
			os.Exit(1)
		}
	case report:
		if err := cli.RunReport(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "report mode failed: %v\n", err)
			os.Exit(1)
		}
	default:
		tg := alerter.NewTelegram(cfg)
		monitor := daemon.NewMonitor(cfg, tg)
		if err := monitor.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "daemon failed: %v\n", err)
			os.Exit(1)
		}
	}
}
