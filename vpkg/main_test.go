package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	s, p, e := parse([]string{"firefox", "--from", "nix"})
	if e != nil || s != "nix" || len(p) != 1 || p[0] != "firefox" {
		t.Fatalf("parse: %s %v %v", s, p, e)
	}
	for _, bad := range [][]string{{"--from", "invalid"}, {"--bad"}, {"--from"}} {
		if _, _, e := parse(bad); e == nil {
			t.Fatalf("accepted %v", bad)
		}
	}
	s, p, e = parse([]string{"--dry-run", "--from=nix"})
	if e != nil || s != "nix" || !reflect.DeepEqual(p, []string{"--dry-run"}) {
		t.Fatalf("parse dry-run: %s %v %v", s, p, e)
	}
	s, p, e = parse([]string{"Demo.AppImage", "--from=appimage"})
	if e != nil || s != "appimage" || !reflect.DeepEqual(p, []string{"Demo.AppImage"}) {
		t.Fatalf("parse AppImage: %s %v %v", s, p, e)
	}
	s, p, e = parse([]string{"./demo.deb", "--from", "glenv"})
	if e != nil || s != "glenv" || !reflect.DeepEqual(p, []string{"./demo.deb"}) {
		t.Fatalf("parse glenv: %s %v %v", s, p, e)
	}
}

func TestDispatch(t *testing.T) {
	var got [][]string
	oldRunner := commandRunner
	oldGlenvPath := glenvFetchDepsPath
	oldVpkgAPKHistoryPath := vpkgAPKHistoryPath
	glenvFetchDepsPath = "/test/fetch-deps.py"
	vpkgAPKHistoryPath = filepath.Join(t.TempDir(), "alpine-history.jsonl")
	commandRunner = func(name string, args ...string) error {
		got = append(got, append([]string{name}, args...))
		return nil
	}
	t.Cleanup(func() {
		commandRunner = oldRunner
		glenvFetchDepsPath = oldGlenvPath
		vpkgAPKHistoryPath = oldVpkgAPKHistoryPath
	})
	for _, tc := range []struct {
		cmd, source string
		args        []string
	}{
		{"install", "alpine", []string{"firefox"}},
		{"upgrade", "alpine", nil},
		{"install", "nix", []string{"helix"}},
		{"install", "nix", []string{"ripgrep", "wezterm"}},
		{"upgrade", "nix", nil},
		{"upgrade", "alpine", []string{"--check"}},
		{"upgrade", "nix", []string{"--dry-run"}},
		{"update", "nix", nil},
		{"history", "nix", nil},
		{"rollback", "nix", nil},
		{"rollback", "nix", []string{"12"}},
		{"install", "glenv", []string{"firefox"}},
		{"install", "glenv", []string{"./pkg.deb"}},
		{"update", "glenv", nil},
		{"upgrade", "glenv", nil},
		{"upgrade", "glenv", []string{"--dry-run"}},
		{"history", "glenv", nil},
		{"rollback", "glenv", []string{"txid"}},
	} {
		if e := dispatch(tc.cmd, tc.source, tc.args); e != nil {
			t.Fatal(e)
		}
	}
	want := [][]string{
		{"apk", "add", "firefox"},
		{"apk", "upgrade"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "install", "nixpkgs#helix"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "install", "nixpkgs#ripgrep", "nixpkgs#wezterm"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "upgrade", "--all"},
		{"apk", "upgrade", "--simulate"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "upgrade", "--all", "--dry-run"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "flake", "metadata", "--refresh", "nixpkgs"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "history"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "rollback"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "rollback", "--to", "12"},
		{"python3", "/test/fetch-deps.py", "--update", "firefox"},
		{"python3", "/test/fetch-deps.py", "--deb-file", "./pkg.deb"},
		{"python3", "/test/fetch-deps.py", "--update-index"},
		{"python3", "/test/fetch-deps.py", "upgrade"},
		{"python3", "/test/fetch-deps.py", "upgrade", "--dry-run"},
		{"python3", "/test/fetch-deps.py", "history"},
		{"python3", "/test/fetch-deps.py", "rollback", "txid"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("commands = %#v, want %#v", got, want)
	}
}

func TestPrintAPKHistory(t *testing.T) {
	path := t.TempDir() + "/apk.log"
	if err := os.WriteFile(path, []byte("2026-10-15 12:00:00 add vpkg\n2026-10-15 12:01:00 upgrade nix\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var output strings.Builder
	if err := printAPKHistory(path, &output); err != nil {
		t.Fatal(err)
	}
	got := output.String()
	for _, want := range []string{"read-only", "add vpkg", "upgrade nix"} {
		if !strings.Contains(got, want) {
			t.Errorf("history output %q does not contain %q", got, want)
		}
	}
}

func TestRunAPKTransactionWritesManagedHistory(t *testing.T) {
	oldRunner := commandRunner
	oldPath := vpkgAPKHistoryPath
	commandRunner = func(name string, args ...string) error {
		if name != "apk" || !reflect.DeepEqual(args, []string{"upgrade"}) {
			t.Fatalf("command = %s %#v", name, args)
		}
		return nil
	}
	vpkgAPKHistoryPath = filepath.Join(t.TempDir(), "history", "alpine.jsonl")
	t.Cleanup(func() {
		commandRunner = oldRunner
		vpkgAPKHistoryPath = oldPath
	})
	if err := runAPKTransaction("upgrade", "upgrade"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(vpkgAPKHistoryPath)
	if err != nil {
		t.Fatal(err)
	}
	var events []apkTransactionEvent
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		var event apkTransactionEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatal(err)
		}
		events = append(events, event)
	}
	if len(events) != 2 || events[0].ID == "" || events[0].ID != events[1].ID ||
		events[0].Phase != "started" || events[1].Phase != "succeeded" ||
		events[0].Action != "upgrade" || events[1].Action != "upgrade" {
		t.Fatalf("transaction events = %#v", events)
	}
}

func TestRunAPKTransactionRedactsUnsafePackageOperands(t *testing.T) {
	oldRunner := commandRunner
	oldPath := vpkgAPKHistoryPath
	commandRunner = func(string, ...string) error { return nil }
	vpkgAPKHistoryPath = filepath.Join(t.TempDir(), "history.jsonl")
	t.Cleanup(func() {
		commandRunner = oldRunner
		vpkgAPKHistoryPath = oldPath
	})
	if err := runAPKTransaction("install", "add", "firefox", "https://user:secret@example.invalid/pkg.apk"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(vpkgAPKHistoryPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "secret") || !strings.Contains(string(data), "[redacted]") {
		t.Fatalf("history did not safely redact package operand: %s", data)
	}
}

func TestRunAPKTransactionDoesNotProceedWithoutHistoryStorage(t *testing.T) {
	oldRunner := commandRunner
	oldPath := vpkgAPKHistoryPath
	blocker := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blocker, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	vpkgAPKHistoryPath = filepath.Join(blocker, "history.jsonl")
	called := false
	commandRunner = func(string, ...string) error {
		called = true
		return nil
	}
	t.Cleanup(func() {
		commandRunner = oldRunner
		vpkgAPKHistoryPath = oldPath
	})
	if err := runAPKTransaction("upgrade", "upgrade"); err == nil {
		t.Fatal("ran APK operation without durable history storage")
	}
	if called {
		t.Fatal("ran APK operation after history storage failed")
	}
}

func TestRunAPKTransactionRecordsCommandFailure(t *testing.T) {
	oldRunner := commandRunner
	oldPath := vpkgAPKHistoryPath
	vpkgAPKHistoryPath = filepath.Join(t.TempDir(), "history.jsonl")
	wantErr := errors.New("upgrade failed")
	commandRunner = func(string, ...string) error { return wantErr }
	t.Cleanup(func() {
		commandRunner = oldRunner
		vpkgAPKHistoryPath = oldPath
	})
	if err := runAPKTransaction("upgrade", "upgrade"); !errors.Is(err, wantErr) {
		t.Fatalf("upgrade error = %v, want original command error", err)
	}
	data, err := os.ReadFile(vpkgAPKHistoryPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(data), `"phase":"failed"`) != 1 {
		t.Fatalf("failed operation not recorded: %s", data)
	}
}

func TestPrintVpkgAPKHistory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "alpine.jsonl")
	for _, event := range []apkTransactionEvent{
		{ID: "tx-1", At: "2026-10-15T12:00:00Z", Phase: "started", Action: "upgrade"},
		{ID: "tx-1", At: "2026-10-15T12:01:00Z", Phase: "succeeded", Action: "upgrade"},
	} {
		if err := appendAPKHistoryEvent(path, event); err != nil {
			t.Fatal(err)
		}
	}
	var output strings.Builder
	if err := printVpkgAPKHistory(path, &output); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"vpkg-managed APK operations", "started", "succeeded", "upgrade"} {
		if !strings.Contains(output.String(), want) {
			t.Errorf("history output %q does not contain %q", output.String(), want)
		}
	}
}

func TestAPKRollbackIsExplicitlyUnsupported(t *testing.T) {
	err := dispatch("rollback", "alpine", nil)
	if err == nil || !strings.Contains(err.Error(), "cannot safely roll back") {
		t.Fatalf("rollback error = %v, want explicit safe limitation", err)
	}
}

func TestGlenvRejectsUnsupportedArguments(t *testing.T) {
	if err := dispatch("install", "glenv", []string{"pkg.deb", "other.deb"}); err == nil {
		t.Fatal("accepted multiple local .deb files")
	}
}

func TestRollbackRejectsInvalidProfileVersion(t *testing.T) {
	for _, value := range []string{"0", "latest", "-1", "1.5"} {
		if err := dispatch("rollback", "nix", []string{value}); err == nil {
			t.Errorf("rollback accepted invalid profile version %q", value)
		}
	}
}

func TestMissingArgs(t *testing.T) {
	if dispatch("install", "alpine", nil) == nil {
		t.Fatal("accepted empty install")
	}
	if dispatch("remove", "nix", nil) == nil {
		t.Fatal("accepted empty remove")
	}
}

func TestDispatchAppImageRequiresOneFile(t *testing.T) {
	oldInstaller := appImageInstaller
	var installed string
	appImageInstaller = func(path string) error {
		installed = path
		return nil
	}
	t.Cleanup(func() { appImageInstaller = oldInstaller })

	if err := dispatch("install", "appimage", []string{"./Demo.AppImage"}); err != nil {
		t.Fatal(err)
	}
	if installed != "./Demo.AppImage" {
		t.Fatalf("installer received %q", installed)
	}
	if err := dispatch("remove", "appimage", []string{"Demo.AppImage"}); err == nil {
		t.Fatal("accepted an unsupported AppImage action")
	}
	if err := dispatch("install", "appimage", nil); err == nil {
		t.Fatal("accepted an empty AppImage install")
	}
}
