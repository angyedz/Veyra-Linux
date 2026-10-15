package main

import (
	"reflect"
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
}

func TestDispatch(t *testing.T) {
	var got [][]string
	oldRunner := commandRunner
	commandRunner = func(name string, args ...string) error {
		got = append(got, append([]string{name}, args...))
		return nil
	}
	t.Cleanup(func() { commandRunner = oldRunner })
	for _, tc := range []struct {
		cmd, source string
		args        []string
	}{
		{"install", "alpine", []string{"firefox"}},
		{"upgrade", "alpine", nil},
		{"install", "nix", []string{"helix"}},
		{"upgrade", "nix", nil},
		{"upgrade", "alpine", []string{"--check"}},
		{"upgrade", "nix", []string{"--dry-run"}},
		{"update", "nix", nil},
		{"history", "nix", nil},
		{"rollback", "nix", nil},
		{"rollback", "nix", []string{"12"}},
	} {
		if e := dispatch(tc.cmd, tc.source, tc.args); e != nil {
			t.Fatal(e)
		}
	}
	want := [][]string{
		{"apk", "add", "firefox"},
		{"apk", "upgrade"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "install", "nixpkgs#helix"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "upgrade", "--all"},
		{"apk", "upgrade", "--simulate"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "upgrade", "--all", "--dry-run"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "flake", "metadata", "--refresh", "nixpkgs"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "history"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "rollback"},
		{"nix", "--extra-experimental-features", "nix-command flakes", "profile", "rollback", "--to", "12"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("commands = %#v, want %#v", got, want)
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
