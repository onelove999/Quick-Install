package alerter

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"vpnguard/config"
)

type Qwen struct {
	cfg    *config.Config
	client *http.Client
}

func NewQwen(cfg *config.Config) *Qwen {
	return &Qwen{
		cfg:    cfg,
		client: &http.Client{Timeout: 60 * time.Second},
	}
}

// OpenAI-compatible request/response structures

type openaiMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type openaiRequest struct {
	Model       string          `json:"model"`
	Messages    []openaiMessage `json:"messages"`
	Temperature float64         `json:"temperature"`
}

type openaiResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
}

type openaiModelsResponse struct {
	Data []struct {
		ID string `json:"id"`
	} `json:"data"`
}

func (q *Qwen) Analyze(logs []string) (string, error) {
	if strings.TrimSpace(q.cfg.AI.QwenToken) == "" {
		return "", fmt.Errorf("qwen token is missing")
	}

	promptText := q.cfg.AI.Prompt + "\n\nЛоги для анализа:\n" + strings.Join(logs, "\n")

	reqBody := openaiRequest{
		Model: q.cfg.AI.QwenModel,
		Messages: []openaiMessage{
			{Role: "user", Content: promptText},
		},
		Temperature: 0.7,
	}

	payload, err := json.Marshal(reqBody)
	if err != nil {
		return "", fmt.Errorf("marshal json: %w", err)
	}

	url := strings.TrimRight(q.cfg.AI.QwenURL, "/") + "/chat/completions"
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewBuffer(payload))
	if err != nil {
		return "", fmt.Errorf("new request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+q.cfg.AI.QwenToken)

	resp, err := q.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("execute request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("api returned status %d: %s", resp.StatusCode, string(bodyBytes))
	}

	var result openaiResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("decode response: %w", err)
	}

	if len(result.Choices) == 0 || strings.TrimSpace(result.Choices[0].Message.Content) == "" {
		return "", fmt.Errorf("empty response from qwen")
	}

	return strings.TrimSpace(result.Choices[0].Message.Content), nil
}

func (q *Qwen) ListModels() ([]string, error) {
	if strings.TrimSpace(q.cfg.AI.QwenToken) == "" {
		return nil, fmt.Errorf("qwen token is missing")
	}

	url := strings.TrimRight(q.cfg.AI.QwenURL, "/") + "/models"
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("new request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+q.cfg.AI.QwenToken)

	resp, err := q.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("execute request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("api returned status %d: %s", resp.StatusCode, string(bodyBytes))
	}

	var result openaiModelsResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}

	models := make([]string, 0, len(result.Data))
	for _, m := range result.Data {
		models = append(models, m.ID)
	}
	return models, nil
}
