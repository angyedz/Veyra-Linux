package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
)

const apkHistoryPath = "/var/log/apk.log"

func showAPKHistory() error {
	return printAPKHistory(apkHistoryPath, os.Stdout)
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
