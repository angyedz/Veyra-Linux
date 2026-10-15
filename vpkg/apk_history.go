package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var apkHistoryPath = "/var/log/apk.log"
var vpkgAPKHistoryPath = "/var/log/vpkg/alpine-transactions.jsonl"

type apkTransactionEvent struct {
	ID       string   `json:"id"`
	At       string   `json:"at"`
	Phase    string   `json:"phase"`
	Action   string   `json:"action"`
	Packages []string `json:"packages,omitempty"`
}

func showAPKHistory() error {
	nativePresent, err := historyFileExists(apkHistoryPath)
	if err != nil {
		return fmt.Errorf("check APK transaction log: %w", err)
	}
	managedPresent, err := historyFileExists(vpkgAPKHistoryPath)
	if err != nil {
		return fmt.Errorf("check vpkg APK transaction log: %w", err)
	}
	if !nativePresent && !managedPresent {
		_, err := fmt.Fprintf(os.Stdout,
			"No APK transaction log found. This APK version may not provide /var/log/apk.log; vpkg records its own package operations in %s.\n",
			vpkgAPKHistoryPath)
		return err
	}
	if nativePresent {
		if err := printAPKHistory(apkHistoryPath, os.Stdout); err != nil {
			return err
		}
	}
	if managedPresent {
		if err := printVpkgAPKHistory(vpkgAPKHistoryPath, os.Stdout); err != nil {
			return err
		}
	}
	return nil
}

func historyFileExists(path string) (bool, error) {
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() {
		return false, fmt.Errorf("history path is not a regular file: %s", path)
	}
	return true, nil
}

func runAPKTransaction(action string, args ...string) error {
	var idBytes [12]byte
	if _, err := rand.Read(idBytes[:]); err != nil {
		return fmt.Errorf("prepare APK transaction history: %w", err)
	}
	id := time.Now().UTC().Format("20060102T150405.000000000Z") + "-" + hex.EncodeToString(idBytes[:])
	var operands []string
	if len(args) > 1 {
		operands = args[1:]
	}
	packages := make([]string, 0, len(operands))
	for _, pkg := range operands {
		if plainPackageName.MatchString(pkg) {
			packages = append(packages, pkg)
		} else {
			packages = append(packages, "[redacted]")
		}
	}
	started := apkTransactionEvent{
		ID: id, At: time.Now().UTC().Format(time.RFC3339Nano),
		Phase: "started", Action: action, Packages: packages,
	}
	if err := appendAPKHistoryEvent(vpkgAPKHistoryPath, started); err != nil {
		return fmt.Errorf("cannot start APK operation without recording its history: %w", err)
	}

	operationErr := commandRunner("apk", args...)
	phase := "succeeded"
	if operationErr != nil {
		phase = "failed"
	}
	finished := apkTransactionEvent{
		ID: id, At: time.Now().UTC().Format(time.RFC3339Nano),
		Phase: phase, Action: action, Packages: packages,
	}
	if historyErr := appendAPKHistoryEvent(vpkgAPKHistoryPath, finished); historyErr != nil {
		if operationErr != nil {
			return fmt.Errorf("%w (could not finalize APK history: %v)", operationErr, historyErr)
		}
		return fmt.Errorf("APK %s succeeded, but its history could not be finalized: %w", action, historyErr)
	}
	return operationErr
}

func appendAPKHistoryEvent(path string, event apkTransactionEvent) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	data, err := json.Marshal(event)
	if err != nil {
		file.Close()
		return err
	}
	data = append(data, '\n')
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

func printVpkgAPKHistory(path string, output io.Writer) error {
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open vpkg APK transaction log: %w", err)
	}
	defer file.Close()
	if _, err := fmt.Fprintf(output, "vpkg-managed APK operations (%s):\n", path); err != nil {
		return err
	}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	lines := 0
	for scanner.Scan() {
		var event apkTransactionEvent
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			return fmt.Errorf("decode vpkg APK history line %d: %w", lines+1, err)
		}
		if event.ID == "" || event.At == "" || event.Action == "" ||
			(event.Phase != "started" && event.Phase != "succeeded" && event.Phase != "failed") {
			return fmt.Errorf("invalid vpkg APK history line %d", lines+1)
		}
		if _, err := fmt.Fprintf(output, "  %s  %-9s %-8s %s\n",
			event.At, event.Phase, event.Action, strings.Join(event.Packages, " ")); err != nil {
			return err
		}
		lines++
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("read vpkg APK transaction log: %w", err)
	}
	if lines == 0 {
		_, err := fmt.Fprintln(output, "  (no vpkg-managed package operations recorded)")
		return err
	}
	return nil
}

func printAPKHistory(path string, output io.Writer) error {
	file, err := os.Open(path)
	if os.IsNotExist(err) {
		_, writeErr := fmt.Fprintf(output, "No APK transaction log found at %s.\n", path)
		return writeErr
	}
	if err != nil {
		return fmt.Errorf("open APK transaction log: %w", err)
	}
	defer file.Close()

	if _, err := fmt.Fprintf(output, "APK transaction log (%s, read-only):\n", path); err != nil {
		return err
	}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	lines := 0
	for scanner.Scan() {
		if _, err := fmt.Fprintln(output, scanner.Text()); err != nil {
			return err
		}
		lines++
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("read APK transaction log: %w", err)
	}
	if lines == 0 {
		_, err := fmt.Fprintln(output, "(no package transactions recorded)")
		return err
	}
	return nil
}
