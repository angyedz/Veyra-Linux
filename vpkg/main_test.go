package main

import (
	"os"
	"path/filepath"
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
}

func TestDispatch(t *testing.T) {
	useUserEnvironment(t, true)
	dir := t.TempDir()
	log := filepath.Join(dir, "commands")
	for _, name := range []string{"apk", "nix"} {
		script := "#!/bin/sh\nprintf '%s\\n' \"" + name + " $*\" >> \"$VPKG_TEST_LOG\"\n"
		if e := os.WriteFile(filepath.Join(dir, name), []byte(script), 0755); e != nil {
			t.Fatal(e)
		}
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	t.Setenv("VPKG_TEST_LOG", log)
	for _, tc := range []struct {
		cmd, source string
		args        []string
	}{
		{"install", "alpine", []string{"firefox"}},
		{"upgrade", "alpine", nil},
		{"install", "nix", []string{"helix"}},
		{"upgrade", "nix", nil},
	} {
		if e := dispatch(tc.cmd, tc.source, tc.args); e != nil {
			t.Fatal(e)
		}
	}
	b, e := os.ReadFile(log)
	if e != nil {
		t.Fatal(e)
	}
	for _, want := range []string{"apk add firefox", "apk upgrade", "nix profile install nixpkgs#helix", "nix profile upgrade --all"} {
		if !strings.Contains(string(b), want) {
			t.Fatalf("missing %q: %s", want, b)
		}
	}
}

func TestMissingArgs(t *testing.T) {
	useUserEnvironment(t, true)
	if dispatch("install", "alpine", nil) == nil {
		t.Fatal("accepted empty install")
	}
	if dispatch("remove", "nix", nil) == nil {
		t.Fatal("accepted empty remove")
	}
}

func TestBootControlIsNotPartOfVpkg(t *testing.T) {
	useUserEnvironment(t, true)
	for _, action := range []string{"deployments", "activate", "rollback"} {
		if err := dispatch(action, "apk", []string{"A"}); err == nil || !strings.Contains(err.Error(), "unsupported command") {
			t.Fatalf("vpkg accepted boot-control action %s: %v", action, err)
		}
	}
}
