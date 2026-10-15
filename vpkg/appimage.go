package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

type appImageTransaction struct {
	ID             string
	Created        string
	Home           string
	Name           string
	AppPath        string
	DesktopPath    string
	AppExisted     bool
	DesktopExisted bool
	AppBackup      string
	DesktopBackup  string
	AppSHA256      string
	DesktopSHA256  string
	RolledBack     bool
}

func installAppImage(source string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("find home directory: %w", err)
	}
	path, err := installAppImageAt(source, home)
	if err != nil {
		return err
	}
	fmt.Println("Installed AppImage without executing it:", path)
	return nil
}

func installAppImageAt(source, home string) (string, error) {
	if !strings.EqualFold(filepath.Ext(source), ".AppImage") {
		return "", fmt.Errorf("expected an .AppImage file")
	}
	sourceInfo, err := os.Lstat(source)
	if err != nil {
		return "", fmt.Errorf("open AppImage: %w", err)
	}
	if !sourceInfo.Mode().IsRegular() {
		return "", fmt.Errorf("AppImage must be a regular file, not a symlink or special file")
	}
	home, err = filepath.Abs(home)
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}
	home, err = filepath.EvalSymlinks(home)
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}
	appDir := filepath.Join(home, ".local", "opt", "veyra-appimages")
	desktopDir := filepath.Join(home, ".local", "share", "applications")
	historyRoot := filepath.Join(home, ".local", "share", "vpkg", "appimage-history")
	for _, dir := range []string{appDir, desktopDir, historyRoot} {
		if err := ensureHomeDirectory(home, dir); err != nil {
			return "", err
		}
	}
	if err := recoverAppImageTransactions(home); err != nil {
		return "", err
	}

	base := filepath.Base(source)
	appPath := filepath.Join(appDir, base)
	if strings.ContainsAny(appPath, "\r\n") {
		return "", fmt.Errorf("AppImage path contains a line break and cannot be registered safely")
	}
	if err := rejectNonRegularPath(appPath); err != nil {
		return "", err
	}
	name := strings.TrimSuffix(base, filepath.Ext(base))
	slug := appImageSlug(name)
	if slug == "" {
		return "", fmt.Errorf("AppImage filename does not contain a usable name")
	}
	desktopPath := filepath.Join(desktopDir, "veyra-"+slug+".desktop")
	if err := rejectNonRegularPath(desktopPath); err != nil {
		return "", err
	}

	appTemp, err := os.CreateTemp(appDir, ".vpkg-appimage-")
	if err != nil {
		return "", fmt.Errorf("stage AppImage: %w", err)
	}
	appTempPath := appTemp.Name()
	defer os.Remove(appTempPath)
	input, err := os.Open(source)
	if err != nil {
		_ = appTemp.Close()
		return "", fmt.Errorf("read AppImage: %w", err)
	}
	_, copyErr := io.Copy(appTemp, input)
	inputErr := input.Close()
	if copyErr != nil {
		_ = appTemp.Close()
		return "", fmt.Errorf("copy AppImage: %w", copyErr)
	}
	if inputErr != nil {
		_ = appTemp.Close()
		return "", fmt.Errorf("close AppImage: %w", inputErr)
	}
	if err := appTemp.Chmod(0o755); err != nil {
		_ = appTemp.Close()
		return "", fmt.Errorf("set AppImage permissions: %w", err)
	}
	if err := appTemp.Sync(); err != nil {
		_ = appTemp.Close()
		return "", fmt.Errorf("sync AppImage: %w", err)
	}
	if err := appTemp.Close(); err != nil {
		return "", fmt.Errorf("close staged AppImage: %w", err)
	}
	if err := validateAppImageFormat(appTempPath); err != nil {
		return "", err
	}
	info, err := inspectELF(appTempPath)
	if err != nil {
		return "", fmt.Errorf("invalid AppImage: %w", err)
	}
	if info.architecture != runtimeArchitecture() {
		return "", fmt.Errorf("AppImage architecture %s does not match this system (%s)",
			info.architecture, runtimeArchitecture())
	}

	desktopTemp, err := os.CreateTemp(desktopDir, ".vpkg-desktop-")
	if err != nil {
		return "", fmt.Errorf("stage desktop entry: %w", err)
	}
	desktopTempPath := desktopTemp.Name()
	defer os.Remove(desktopTempPath)
	if _, err := io.WriteString(desktopTemp, appImageDesktopEntry(name, appPath)); err != nil {
		_ = desktopTemp.Close()
		return "", fmt.Errorf("write desktop entry: %w", err)
	}
	if err := desktopTemp.Chmod(0o644); err != nil {
		_ = desktopTemp.Close()
		return "", fmt.Errorf("set desktop entry permissions: %w", err)
	}
	if err := desktopTemp.Sync(); err != nil {
		_ = desktopTemp.Close()
		return "", fmt.Errorf("sync desktop entry: %w", err)
	}
	if err := desktopTemp.Close(); err != nil {
		return "", fmt.Errorf("close staged desktop entry: %w", err)
	}

	backupDir, err := os.MkdirTemp(historyRoot, ".pending-")
	if err != nil {
		return "", err
	}
	keepBackup := false
	defer func() {
		if !keepBackup {
			_ = os.RemoveAll(backupDir)
		}
	}()
	appExisted, err := backupRegularPath(appPath, filepath.Join(backupDir, "app"))
	if err != nil {
		return "", err
	}
	desktopExisted, err := backupRegularPath(desktopPath, filepath.Join(backupDir, "desktop"))
	if err != nil {
		return "", err
	}
	tx := appImageTransaction{
		ID:      time.Now().UTC().Format("20060102T150405.000000000Z") + "-" + strings.TrimPrefix(filepath.Base(backupDir), ".pending-"),
		Created: time.Now().UTC().Format(time.RFC3339Nano),
		Home:    home,
		Name:    name, AppPath: appPath, DesktopPath: desktopPath,
		AppExisted: appExisted, DesktopExisted: desktopExisted,
		AppBackup: "app", DesktopBackup: "desktop",
	}
	tx.AppSHA256, err = sha256File(appTempPath)
	if err != nil {
		return "", err
	}
	tx.DesktopSHA256, err = sha256File(desktopTempPath)
	if err != nil {
		return "", err
	}
	if err := writeAppImageManifest(filepath.Join(backupDir, "manifest.json"), tx); err != nil {
		return "", err
	}
	if err := os.Rename(appTempPath, appPath); err != nil {
		return "", fmt.Errorf("install AppImage: %w", err)
	}
	if err := os.Rename(desktopTempPath, desktopPath); err != nil {
		if restoreErr := restoreAppImageTransaction(tx, backupDir); restoreErr != nil {
			keepBackup = true
			return "", fmt.Errorf("install desktop entry: %v; recovery data remains at %s: %w",
				err, backupDir, restoreErr)
		}
		return "", fmt.Errorf("install desktop entry: %w", err)
	}
	finalDir := filepath.Join(historyRoot, tx.ID)
	if err := os.Rename(backupDir, finalDir); err != nil {
		if restoreErr := restoreAppImageTransaction(tx, backupDir); restoreErr != nil {
			keepBackup = true
			return "", fmt.Errorf("save AppImage history: %v; recovery data remains at %s: %w",
				err, backupDir, restoreErr)
		}
		return "", fmt.Errorf("save AppImage history: %w", err)
	}
	keepBackup = true
	return appPath, nil
}

func validateAppImageFormat(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("read AppImage header: %w", err)
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		return fmt.Errorf("read AppImage metadata: %w", err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("AppImage must be a regular file")
	}

	var marker [3]byte
	if _, err := f.ReadAt(marker[:], 8); err == nil {
		if bytes.Equal(marker[:], []byte{'A', 'I', 1}) || bytes.Equal(marker[:], []byte{'A', 'I', 2}) {
			return nil
		}
	}

	// Older Type 1 images can omit the recommended AI\x01 marker. Their ISO
	// 9660 primary volume descriptor remains at sector 16, byte offset 32768.
	var descriptor [7]byte
	if _, err := f.ReadAt(descriptor[:], 32768); err == nil &&
		descriptor[0] == 1 && bytes.Equal(descriptor[1:6], []byte("CD001")) && descriptor[6] == 1 {
		return nil
	}
	return fmt.Errorf("invalid AppImage: missing Type 1/2 marker and ISO 9660 descriptor")
}

func appImageDesktopEntry(name, path string) string {
	name = strings.NewReplacer("\\", "\\\\", "\n", " ", "\r", " ", "\t", " ").Replace(name)
	return "[Desktop Entry]\nType=Application\nName=" + name + "\nExec=" +
		desktopExecQuote(path) + "\nTerminal=false\nCategories=Utility;\n"
}

func desktopExecQuote(value string) string {
	replacer := strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "$", "\\$", "%", "%%")
	value = replacer.Replace(value)
	value = strings.ReplaceAll(value, string(rune(96)), "\\"+string(rune(96)))
	return "\"" + value + "\""
}

func appImageSlug(name string) string {
	var builder strings.Builder
	for _, char := range name {
		switch {
		case char >= 'a' && char <= 'z', char >= 'A' && char <= 'Z',
			char >= '0' && char <= '9', char == '.', char == '-', char == '_':
			builder.WriteRune(char)
		case char == ' ':
			builder.WriteByte('-')
		}
	}
	return strings.Trim(builder.String(), ".-_")
}

func runtimeArchitecture() string {
	switch runtime.GOARCH {
	case "amd64":
		return "x86_64"
	case "arm64":
		return "aarch64"
	default:
		return runtime.GOARCH
	}
}

func ensureHomeDirectory(home, path string) error {
	realHome, err := filepath.EvalSymlinks(home)
	if err != nil {
		return fmt.Errorf("resolve home directory: %w", err)
	}
	absHome, err := filepath.Abs(home)
	if err != nil {
		return err
	}
	absPath, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	rel, err := filepath.Rel(absHome, absPath)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return fmt.Errorf("AppImage directory resolves outside the home directory")
	}
	current := absHome
	for _, part := range strings.Split(rel, string(os.PathSeparator)) {
		if part == "" || part == "." {
			continue
		}
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		if os.IsNotExist(err) {
			if err := os.Mkdir(current, 0o755); err != nil && !os.IsExist(err) {
				return fmt.Errorf("create AppImage directory: %w", err)
			}
			info, err = os.Lstat(current)
		}
		if err != nil {
			return err
		}
		resolved := current
		if info.Mode()&os.ModeSymlink != 0 {
			resolved, err = filepath.EvalSymlinks(current)
			if err != nil {
				return err
			}
		}
		relToHome, relErr := filepath.Rel(realHome, resolved)
		if relErr != nil || relToHome == ".." ||
			strings.HasPrefix(relToHome, ".."+string(os.PathSeparator)) {
			return fmt.Errorf("AppImage directory resolves outside the home directory")
		}
		if !info.IsDir() {
			return fmt.Errorf("AppImage path component is not a directory: %s", current)
		}
		current = resolved
	}
	return nil
}

func rejectNonRegularPath(path string) error {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("refusing to replace non-regular AppImage target: %s", path)
	}
	return nil
}

func backupRegularPath(source, backup string) (bool, error) {
	info, err := os.Lstat(source)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !info.Mode().IsRegular() {
		return false, fmt.Errorf("refusing to replace non-regular AppImage target: %s", source)
	}
	input, err := os.Open(source)
	if err != nil {
		return false, err
	}
	defer input.Close()
	output, err := os.OpenFile(backup, os.O_CREATE|os.O_EXCL|os.O_WRONLY, info.Mode().Perm())
	if err != nil {
		return false, err
	}
	_, copyErr := io.Copy(output, input)
	syncErr := output.Sync()
	closeErr := output.Close()
	if copyErr != nil {
		return false, copyErr
	}
	if syncErr != nil {
		return false, syncErr
	}
	if closeErr != nil {
		return false, closeErr
	}
	return true, nil
}

func restoreRegularPath(target, backup string, existed bool) error {
	if !existed {
		err := os.Remove(target)
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(target), ".vpkg-recovery-")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	_ = temp.Close()
	_ = os.Remove(tempPath)
	input, err := os.Open(backup)
	if err != nil {
		return err
	}
	info, err := input.Stat()
	if err != nil {
		_ = input.Close()
		return err
	}
	output, err := os.OpenFile(tempPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, info.Mode().Perm())
	if err != nil {
		_ = input.Close()
		return err
	}
	_, copyErr := io.Copy(output, input)
	inputErr := input.Close()
	closeErr := output.Close()
	if copyErr != nil {
		_ = os.Remove(tempPath)
		return copyErr
	}
	if inputErr != nil {
		_ = os.Remove(tempPath)
		return inputErr
	}
	if closeErr != nil {
		_ = os.Remove(tempPath)
		return closeErr
	}
	return os.Rename(tempPath, target)
}

func sha256File(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func writeAppImageManifest(path string, tx appImageTransaction) error {
	data, err := json.MarshalIndent(tx, "", "  ")
	if err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".vpkg-manifest-")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if _, err := temp.Write(append(data, '\n')); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(tempPath, path)
}

func appImageHistory(home string) ([]appImageTransaction, error) {
	root := filepath.Join(home, ".local", "share", "vpkg", "appimage-history")
	items, err := os.ReadDir(root)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var entries []appImageTransaction
	for _, item := range items {
		if !item.IsDir() || strings.HasPrefix(item.Name(), ".pending-") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, item.Name(), "manifest.json"))
		if err != nil {
			return nil, fmt.Errorf("read AppImage history %s: %w", item.Name(), err)
		}
		var tx appImageTransaction
		if err := json.Unmarshal(data, &tx); err != nil {
			return nil, fmt.Errorf("parse AppImage history %s: %w", item.Name(), err)
		}
		tx.ID = item.Name()
		entries = append(entries, tx)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Created > entries[j].Created })
	return entries, nil
}

func showAppImageHistory() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	if err := recoverAppImageTransactions(home); err != nil {
		return err
	}
	entries, err := appImageHistory(home)
	if err != nil {
		return err
	}
	for _, tx := range entries {
		state := "active"
		if tx.RolledBack {
			state = "rolled back"
		}
		fmt.Printf("%s  %s  %s\n", tx.ID, state, tx.Name)
	}
	return nil
}

func rollbackLatestAppImage(home string) error {
	if err := recoverAppImageTransactions(home); err != nil {
		return err
	}
	entries, err := appImageHistory(home)
	if err != nil {
		return err
	}
	var latest *appImageTransaction
	for i := range entries {
		if !entries[i].RolledBack {
			latest = &entries[i]
			break
		}
	}
	if latest == nil {
		return fmt.Errorf("no active AppImage transaction to roll back")
	}
	if err := verifyAppImageState(*latest); err != nil {
		return err
	}
	historyDir := filepath.Join(home, ".local", "share", "vpkg", "appimage-history", latest.ID)
	if latest.AppExisted {
		if _, err := os.Stat(filepath.Join(historyDir, latest.AppBackup)); err != nil {
			return fmt.Errorf("AppImage rollback backup is missing: %w", err)
		}
	}
	if latest.DesktopExisted {
		if _, err := os.Stat(filepath.Join(historyDir, latest.DesktopBackup)); err != nil {
			return fmt.Errorf("desktop rollback backup is missing: %w", err)
		}
	}
	if err := restoreAppImageTransaction(*latest, historyDir); err != nil {
		return err
	}
	latest.RolledBack = true
	return writeAppImageManifest(filepath.Join(historyDir, "manifest.json"), *latest)
}

func verifyAppImageState(tx appImageTransaction) error {
	for _, item := range []struct{ path, expected string }{
		{tx.AppPath, tx.AppSHA256},
		{tx.DesktopPath, tx.DesktopSHA256},
	} {
		info, err := os.Lstat(item.path)
		if err != nil {
			return fmt.Errorf("rollback refused; managed file is unavailable: %s: %w", item.path, err)
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("rollback refused; managed file is not a regular file: %s", item.path)
		}
		got, err := sha256File(item.path)
		if err != nil {
			return fmt.Errorf("rollback refused; managed file is unavailable: %s: %w", item.path, err)
		}
		if got != item.expected {
			return fmt.Errorf("rollback refused; managed file changed since update: %s", item.path)
		}
	}
	return nil
}

func restoreAppImageTransaction(tx appImageTransaction, historyDir string) error {
	if err := validateAppImageTransaction(tx, historyDir); err != nil {
		return err
	}
	changes := []struct {
		path, backup string
		existed      bool
	}{
		{tx.AppPath, tx.AppBackup, tx.AppExisted},
		{tx.DesktopPath, tx.DesktopBackup, tx.DesktopExisted},
	}
	safety, err := os.MkdirTemp(filepath.Dir(historyDir), ".vpkg-restore-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(safety)
	type current struct {
		path, backup string
		existed      bool
	}
	var snapshots []current
	for i, change := range changes {
		backup := filepath.Join(safety, fmt.Sprint(i))
		existed, err := backupRegularPath(change.path, backup)
		if err != nil {
			return err
		}
		snapshots = append(snapshots, current{change.path, backup, existed})
	}
	restoreCurrent := func() {
		for _, snapshot := range snapshots {
			_ = restoreRegularPath(snapshot.path, snapshot.backup, snapshot.existed)
		}
	}
	for _, change := range changes {
		if err := restoreRegularPath(change.path, filepath.Join(historyDir, change.backup), change.existed); err != nil {
			restoreCurrent()
			return err
		}
	}
	return nil
}

func recoverAppImageTransactions(home string) error {
	root := filepath.Join(home, ".local", "share", "vpkg", "appimage-history")
	items, err := os.ReadDir(root)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, item := range items {
		if !item.IsDir() || !strings.HasPrefix(item.Name(), ".pending-") {
			continue
		}
		dir := filepath.Join(root, item.Name())
		data, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
		if os.IsNotExist(err) {
			if err := os.RemoveAll(dir); err != nil {
				return err
			}
			continue
		}
		if err != nil {
			return err
		}
		var tx appImageTransaction
		if err := json.Unmarshal(data, &tx); err != nil {
			return fmt.Errorf("read interrupted AppImage transaction %s: %w", item.Name(), err)
		}
		tx.ID = item.Name()
		if err := restoreAppImageTransaction(tx, dir); err != nil {
			return fmt.Errorf("recover interrupted AppImage transaction %s: %w", item.Name(), err)
		}
		if err := os.RemoveAll(dir); err != nil {
			return err
		}
	}
	return nil
}

func validateAppImageTransaction(tx appImageTransaction, historyDir string) error {
	if tx.Home == "" || tx.Name == "" {
		return fmt.Errorf("invalid AppImage transaction metadata")
	}
	home, err := filepath.EvalSymlinks(tx.Home)
	if err != nil {
		return err
	}
	appRoot := filepath.Join(home, ".local", "opt", "veyra-appimages")
	desktopRoot := filepath.Join(home, ".local", "share", "applications")
	historyRoot := filepath.Join(home, ".local", "share", "vpkg", "appimage-history")
	for _, root := range []string{appRoot, desktopRoot, historyRoot} {
		resolved, err := filepath.EvalSymlinks(root)
		if err != nil {
			return err
		}
		if filepath.Clean(resolved) != filepath.Clean(root) {
			return fmt.Errorf("AppImage managed directories must not be symlinks")
		}
	}
	if !directChild(appRoot, tx.AppPath) ||
		!strings.EqualFold(filepath.Ext(tx.AppPath), ".AppImage") {
		return fmt.Errorf("invalid AppImage history path")
	}
	expectedDesktop := filepath.Join(desktopRoot, "veyra-"+appImageSlug(tx.Name)+".desktop")
	if filepath.Clean(expectedDesktop) != filepath.Clean(tx.DesktopPath) ||
		!directChild(desktopRoot, tx.DesktopPath) {
		return fmt.Errorf("invalid AppImage desktop history path")
	}
	if !directChild(historyRoot, historyDir) ||
		filepath.Clean(filepath.Dir(historyDir)) != filepath.Clean(historyRoot) {
		return fmt.Errorf("invalid AppImage history directory")
	}
	if tx.AppBackup != "app" || tx.DesktopBackup != "desktop" {
		return fmt.Errorf("invalid AppImage rollback backup path")
	}
	return nil
}

func directChild(root, path string) bool {
	rel, err := filepath.Rel(filepath.Clean(root), filepath.Clean(path))
	return err == nil && rel != "." && rel != ".." &&
		!strings.HasPrefix(rel, ".."+string(os.PathSeparator)) &&
		!strings.Contains(rel, string(os.PathSeparator))
}
