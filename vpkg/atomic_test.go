package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func useUserEnvironment(t *testing.T, enabled bool) {
	t.Helper()
	old := userEnvironmentMarker
	userEnvironmentMarker = filepath.Join(t.TempDir(), "user-environment")
	t.Cleanup(func() { userEnvironmentMarker = old })
	if enabled {
		if err := os.WriteFile(userEnvironmentMarker, []byte("user-v1\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestVpkgRequiresUserEnvironment(t *testing.T) {
	useUserEnvironment(t, false)
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	for _, name := range []string{"apk", "nix"} {
		script := "#!/bin/sh\nprintf '%s\\n' \"" + name + " $*\" >> \"$VPKG_TEST_LOG\"\n"
		if err := os.WriteFile(filepath.Join(dir, name), []byte(script), 0755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	t.Setenv("VPKG_TEST_LOG", log)
	for _, action := range []string{"install", "remove", "update", "upgrade", "search", "list"} {
		if err := dispatch(action, "apk", []string{"firefox"}); err == nil ||
			!strings.Contains(err.Error(), "only runs inside the Veyra user environment") {
			t.Fatalf("%s did not refuse host-environment use: %v", action, err)
		}
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Fatalf("backend ran outside user environment; log stat error: %v", err)
	}
}

func TestVpkgRejectsInvalidUserEnvironmentMarker(t *testing.T) {
	useUserEnvironment(t, false)
	if err := os.WriteFile(userEnvironmentMarker, []byte("system-v1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := dispatch("list", "apk", nil); err == nil || !strings.Contains(err.Error(), "invalid Veyra user-environment marker") {
		t.Fatalf("invalid marker was accepted: %v", err)
	}
}

func TestNativeEnginePreferred(t *testing.T) {
	useUserEnvironment(t, true)
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	t.Setenv("VPKG_TEST_LOG", log)
	for _, name := range []string{"apk", "vpkg-engine"} {
		script := "#!/bin/sh\nprintf '%s\\n' \"" + name + " $*\" >> \"$VPKG_TEST_LOG\"\n"
		if err := os.WriteFile(filepath.Join(dir, name), []byte(script), 0755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	if err := dispatch("search", "alpine", []string{"plasma"}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "vpkg-engine search plasma\n" {
		t.Fatalf("did not use native engine: %q", data)
	}
}
