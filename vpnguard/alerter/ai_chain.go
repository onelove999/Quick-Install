package alerter

import (
	"fmt"
	"log"
	"os"
	"strings"

	"vpnguard/config"
)

// AIChain implements daemon.AIAnalyzer with provider fallback:
// Qwen (try) → Qwen (retry) → Gemini (fallback)
type AIChain struct {
	qwen   *Qwen
	gemini *Gemini
	logger *log.Logger
}

func NewAIChain(cfg *config.Config) *AIChain {
	chain := &AIChain{
		logger: log.New(os.Stdout, "vpnguard: ", log.LstdFlags),
	}

	if strings.TrimSpace(cfg.AI.QwenToken) != "" {
		chain.qwen = NewQwen(cfg)
		chain.logger.Printf("AI provider registered: Qwen (%s)", cfg.AI.QwenModel)
	}

	if strings.TrimSpace(cfg.AI.GeminiToken) != "" {
		chain.gemini = NewGemini(cfg)
		chain.logger.Println("AI provider registered: Gemini (fallback)")
	}

	return chain
}

func (c *AIChain) Analyze(logs []string) (string, error) {
	// 1. Try Qwen
	if c.qwen != nil {
		result, err := c.qwen.Analyze(logs)
		if err == nil {
			return "[Qwen] " + result, nil
		}
		c.logger.Printf("qwen attempt 1 failed: %v", err)

		// 2. Retry Qwen
		result, err = c.qwen.Analyze(logs)
		if err == nil {
			return "[Qwen] " + result, nil
		}
		c.logger.Printf("qwen attempt 2 failed: %v", err)
	}

	// 3. Fallback to Gemini
	if c.gemini != nil {
		result, err := c.gemini.Analyze(logs)
		if err == nil {
			return "[Gemini] " + result, nil
		}
		c.logger.Printf("gemini fallback failed: %v", err)
		return "", fmt.Errorf("all AI providers failed (last: gemini: %w)", err)
	}

	return "", fmt.Errorf("all AI providers failed, no fallback available")
}

func (c *AIChain) HasProviders() bool {
	return c.qwen != nil || c.gemini != nil
}
