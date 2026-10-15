package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestInstallAppImageCopiesAndRegistersWithoutRunning(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home with spaces")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(root, "Demo App.AppImage")
	if err := writeAppImageFixture(source, "/lib64/ld-linux-x86-64.so.2", 2); err != nil {
		t.Fatal(err)
	}

	installed, err := installAppImageAt(source, home)
	if err != nil {
		t.Fatal(err)
	}
	if installed != filepath.Join(home, ".local", "opt", "veyra-appimages", "Demo App.AppImage") {
		t.Fatalf("installed path = %q", installed)
	}
	if _, err := os.Stat(installed); err != nil {
		t.Fatalf("AppImage was not copied: %v", err)
	}
	mode, err := os.Stat(installed)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && mode.Mode().Perm()&0o111 == 0 {
		t.Fatalf("installed AppImage is not executable: %v", mode.Mode())
	}
	desktopPath := filepath.Join(home, ".local", "share", "applications", "veyra-Demo-App.desktop")
	desktop, err := os.ReadFile(desktopPath)
	if err != nil {
		t.Fatalf("desktop entry was not created: %v", err)
	}
	if !strings.Contains(string(desktop), "Exec="+desktopExecQuote(installed)) {
		t.Fatalf("desktop entry does not quote installed path: %s", desktop)
	}
}

func TestInstallAppImageRejectsWrongFormatAndSymlink(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	textFile := filepath.Join(root, "not-an-appimage.AppImage")
	if err := os.WriteFile(textFile, []byte("not ELF"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := installAppImageAt(textFile, home); err == nil {
		t.Fatal("accepted a non-ELF AppImage")
	}
	plainELF := filepath.Join(root, "plain-elf.AppImage")
	if err := writeELFFixture(plainELF, "/lib64/ld-linux-x86-64.so.2"); err != nil {
		t.Fatal(err)
	}
	if _, err := installAppImageAt(plainELF, home); err == nil || !strings.Contains(err.Error(), "missing Type 1/2 marker") {
		t.Fatalf("accepted a plain ELF with an AppImage extension: %v", err)
	}
	link := filepath.Join(root, "linked.AppImage")
	if err := os.Symlink(textFile, link); err != nil {
		t.Skipf("symlink creation unavailable: %v", err)
	}
	if _, err := installAppImageAt(link, home); err == nil {
		t.Fatal("accepted a symlink AppImage")
	}
}

func TestValidateAppImageAcceptsLegacyType1ISODescriptor(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.AppImage")
	if err := writeELFFixture(path, "/lib64/ld-linux-x86-64.so.2"); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, writeErr := f.WriteAt([]byte{1, 'C', 'D', '0', '0', '1', 1}, 32768)
	closeErr := f.Close()
	if writeErr != nil {
		t.Fatal(writeErr)
	}
	if closeErr != nil {
		t.Fatal(closeErr)
	}
	if err := validateAppImageFormat(path); err != nil {
		t.Fatalf("rejected legacy Type 1 image: %v", err)
	}
}

func TestAppImageDesktopEntryEscapesExecValue(t *testing.T) {
	entry := appImageDesktopEntry("A\nName", "/home/user/a \"b\".AppImage")
	if strings.Contains(entry, "Name=A\nName") {
		t.Fatalf("desktop name contains an injected line: %s", entry)
	}
	if !strings.Contains(entry, "Exec=\"/home/user/a \\\"b\\\".AppImage\"") {
		t.Fatalf("desktop Exec value is not escaped: %s", entry)
	}
}

func TestAppImageUpdateHistoryAndRollback(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(root, "Editor.AppImage")
	if err := writeAppImageFixture(source, "/lib64/ld-linux-x86-64.so.2", 1); err != nil {
		t.Fatal(err)
	}
	first, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	installed, err := installAppImageAt(source, home)
	if err != nil {
		t.Fatal(err)
	}
	second := append(append([]byte(nil), first...), []byte("second build")...)
	if err := os.WriteFile(source, second, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := installAppImageAt(source, home); err != nil {
		t.Fatal(err)
	}
	entries, err := appImageHistory(home)
	if err != nil || len(entries) != 2 {
		t.Fatalf("history entries = %d, error = %v", len(entries), err)
	}
	if err := rollbackLatestAppImage(home); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(installed)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(first) {
		t.Fatal("rollback did not restore the previous AppImage")
	}
	entries, err = appImageHistory(home)
	if err != nil || !entries[0].RolledBack {
		t.Fatalf("latest history state = %#v, error = %v", entries, err)
	}
	if err := rollbackLatestAppImage(home); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(installed); !os.IsNotExist(err) {
		t.Fatalf("rollback of initial install left AppImage: %v", err)
	}
}

func TestAppImageRollbackRefusesModifiedFile(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(root, "Editor.AppImage")
	if err := writeAppImageFixture(source, "/lib64/ld-linux-x86-64.so.2", 2); err != nil {
		t.Fatal(err)
	}
	installed, err := installAppImageAt(source, home)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(installed, []byte("user change"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := rollbackLatestAppImage(home); err == nil {
		t.Fatal("rollback accepted a modified AppImage")
	}
}

func writeAppImageFixture(path, interpreter string, imageType byte) error {
	if err := writeELFFixture(path, interpreter); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	if imageType == 1 || imageType == 2 {
		_, err = f.WriteAt([]byte{'A', 'I', imageType}, 8)
		return err
	}
	return os.ErrInvalid
}
