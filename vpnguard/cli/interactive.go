package cli

import (
	"bufio"
	"compress/gzip"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"vpnguard/config"
	"vpnguard/daemon"
)

func RunInteractive(cfg *config.Config) error {
	files, err := collectLogFiles(cfg.LogFile)
	if err != nil {
		return err
	}
	if len(files) == 0 {
		return fmt.Errorf("no log files found near %s", cfg.LogFile)
	}

	reader := bufio.NewReader(os.Stdin)
	selected, err := chooseFiles(reader, files)
	if err != nil {
		return err
	}

	fmt.Println("Search by:")
	fmt.Println("1) none")
	fmt.Println("2) email")
	fmt.Println("3) source IP")
	fmt.Println("4) destination host")
	fmt.Println("5) custom text")
	filterKind := prompt(reader, "Choice: ")
	filterValue := ""
	switch filterKind {
	case "2":
		filterValue = prompt(reader, "Email: ")
	case "3":
		filterValue = prompt(reader, "Source IP: ")
	case "4":
		filterValue = prompt(reader, "Destination substring: ")
	case "5":
		filterValue = prompt(reader, "Text: ")
	}

	fmt.Println("Extract:")
	fmt.Println("1) full line")
	fmt.Println("2) destination")
	fmt.Println("3) source IP")
	fmt.Println("4) email")
	extractKind := prompt(reader, "Choice: ")

	dedup := strings.ToLower(prompt(reader, "Deduplicate? [Y/n]: ")) != "n"
	results := make([]string, 0)

	for _, file := range selected {
		err := readLines(file, func(line string) error {
			if !matchesFilter(line, filterKind, filterValue) {
				return nil
			}
			item := extractValue(line, extractKind)
			if item != "" {
				results = append(results, item)
			}
			return nil
		})
		if err != nil {
			return err
		}
	}

	if dedup {
		set := make(map[string]struct{}, len(results))
		for _, item := range results {
			set[item] = struct{}{}
		}
		results = results[:0]
		for item := range set {
			results = append(results, item)
		}
		sort.Strings(results)
	}

	fmt.Printf("\nFound %d records.\n", len(results))
	for _, item := range results {
		fmt.Println(item)
	}

	outPath := prompt(reader, "\nOutput file [result.txt]: ")
	if strings.TrimSpace(outPath) == "" {
		outPath = "result.txt"
	}
	return os.WriteFile(outPath, []byte(strings.Join(results, "\n")+"\n"), 0o644)
}

func collectLogFiles(primary string) ([]string, error) {
	dir := filepath.Dir(primary)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}

	files := make([]string, 0)
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if strings.Contains(name, ".log") || strings.HasSuffix(name, ".gz") {
			files = append(files, filepath.Join(dir, name))
		}
	}
	sort.Strings(files)
	return files, nil
}

func chooseFiles(reader *bufio.Reader, files []string) ([]string, error) {
	fmt.Println("Available logs:")
	for idx, file := range files {
		fmt.Printf("%d) %s\n", idx, filepath.Base(file))
	}
	fmt.Printf("%d) all files\n", len(files))

	choice := prompt(reader, "Choice: ")
	if choice == fmt.Sprintf("%d", len(files)) {
		return files, nil
	}
	index := 0
	fmt.Sscanf(choice, "%d", &index)
	if index < 0 || index >= len(files) {
		return nil, fmt.Errorf("invalid file choice")
	}
	return []string{files[index]}, nil
}

func matchesFilter(line, kind, value string) bool {
	switch kind {
	case "2":
		return strings.Contains(line, "email: "+value)
	case "3":
		entry, err := daemon.ParseLine(line)
		return err == nil && entry.SourceIP == value
	case "4":
		return strings.Contains(line, value)
	case "5":
		return strings.Contains(line, value)
	default:
		return true
	}
}

func extractValue(line, kind string) string {
	entry, err := daemon.ParseLine(line)
	if err != nil && kind != "1" {
		return ""
	}
	switch kind {
	case "2":
		host, _ := daemon.SplitDestination(entry.Destination)
		return host
	case "3":
		return entry.SourceIP
	case "4":
		return entry.Email
	default:
		return strings.TrimSpace(line)
	}
}

func readLines(path string, handler func(string) error) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()

	var scanner *bufio.Scanner
	if strings.HasSuffix(path, ".gz") {
		gz, err := gzip.NewReader(file)
		if err != nil {
			return err
		}
		defer gz.Close()
		scanner = bufio.NewScanner(gz)
	} else {
		scanner = bufio.NewScanner(file)
	}

	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024)
	for scanner.Scan() {
		if err := handler(scanner.Text()); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func prompt(reader *bufio.Reader, label string) string {
	fmt.Print(label)
	text, _ := reader.ReadString('\n')
	return strings.TrimSpace(text)
}
