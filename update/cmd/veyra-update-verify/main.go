// veyra-update-verify validates signed release metadata before it can be
// consumed by a paired-generation updater.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"veyra-update"
)

const maxSignatureFile = 256

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "veyra-update-verify:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	flags := flag.NewFlagSet("veyra-update-verify", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	manifestPath := flags.String("manifest", "", "path to signed release JSON")
	signaturePath := flags.String("signature", "", "path to detached base64 Ed25519 signature")
	publicKeyPath := flags.String("public-key", "", "path to trusted base64 Ed25519 public key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || *manifestPath == "" || *signaturePath == "" || *publicKeyPath == "" {
		return errors.New("usage: veyra-update-verify --manifest FILE --signature FILE --public-key FILE")
	}
	document, err := readRegularFile(*manifestPath, 1<<20)
	if err != nil {
		return fmt.Errorf("read release manifest: %w", err)
	}
	signature, err := readRegularFile(*signaturePath, maxSignatureFile)
	if err != nil {
		return fmt.Errorf("read release signature: %w", err)
	}
	publicKey, err := readRegularFile(*publicKeyPath, maxSignatureFile)
	if err != nil {
		return fmt.Errorf("read trusted public key: %w", err)
	}
	manifest, err := update.VerifySignedManifest(document, signature, publicKey)
	if err != nil {
		return err
	}
	result := struct {
		Status       string `json:"status"`
		Release      string `json:"release"`
		Sequence     uint64 `json:"sequence"`
		Architecture string `json:"architecture"`
		SystemID     string `json:"system_id"`
		UserID       string `json:"user_id"`
		SystemCompat string `json:"system_compatibility"`
		UserCompat   string `json:"user_compatibility"`
	}{"verified", manifest.Release, manifest.Sequence, manifest.Architecture,
		manifest.System.ID, manifest.User.ID,
		manifest.System.Provides, manifest.User.Provides}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(result)
}

func readRegularFile(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return nil, err
	}
	pathInfo, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !opened.Mode().IsRegular() || opened.Size() > limit ||
		!pathInfo.Mode().IsRegular() || pathInfo.Mode()&os.ModeSymlink != 0 ||
		!os.SameFile(opened, pathInfo) {
		return nil, fmt.Errorf("%s must be a regular non-symlink file no larger than %d bytes", filepath.Clean(path), limit)
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%s exceeds %d bytes", filepath.Clean(path), limit)
	}
	return data, nil
}
