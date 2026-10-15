package main

import (
	"os"
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
	glenvFetchDepsPath = "/test/fetch-deps.py"
	commandRunner = func(name string, args ...string) error {
		got = append(got, append([]string{name}, args...))
		return nil
	}
	t.Cleanup(func() {
		commandRunner = oldRunner
		glenvFetchDepsPath = oldGlenvPath
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
