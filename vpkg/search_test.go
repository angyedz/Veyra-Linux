package main

import (
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestParseDefaultsToAutomaticSourceSelection(t *testing.T) {
	source, packages, err := parse([]string{"firefox"})
	if err != nil || source != "auto" || !reflect.DeepEqual(packages, []string{"firefox"}) {
		t.Fatalf("parse default source: %s %v %v", source, packages, err)
	}
}

func TestAutomaticInstallPrefersAPKRepositories(t *testing.T) {
	oldSearch, oldRunner := packageSearchRunner, commandRunner
	oldNixConfirm, oldAPKConfirm := nixInstallConfirmer, apkInstallConfirmer
	t.Cleanup(func() {
		packageSearchRunner = oldSearch
		commandRunner = oldRunner
		nixInstallConfirmer, apkInstallConfirmer = oldNixConfirm, oldAPKConfirm
	})
	var commands [][]string
	packageSearchRunner = func(source, query string, exact bool) ([]packageMatch, error) {
		if !exact || query != "firefox" {
			t.Fatalf("unexpected search query: %s %q exact=%t", source, query, exact)
		}
		if source == "apk" {
			return []packageMatch{{Source: "Alpine/Veyra APK", Name: "firefox"}}, nil
		}
		return []packageMatch{{Source: "Nix", Name: "firefox", Attribute: "firefox"}}, nil
	}
	nixInstallConfirmer = func([]packageMatch) (bool, error) {
		t.Fatal("Nix confirmation should not run when APK contains the package")
		return false, nil
	}
	apkInstallConfirmer = func(candidates []packageMatch) (bool, error) {
		if !reflect.DeepEqual(candidates, []packageMatch{{Source: "Alpine/Veyra APK", Name: "firefox"}}) {
			t.Fatalf("APK confirmation candidates = %#v", candidates)
		}
		return true, nil
	}
	commandRunner = func(name string, args ...string) error {
		commands = append(commands, append([]string{name}, args...))
		return nil
	}
	if err := dispatch("install", "auto", []string{"firefox"}); err != nil {
		t.Fatal(err)
	}
	want := [][]string{{"apk", "add", "--simulate", "firefox"}, {"apk", "add", "firefox"}}
	if !reflect.DeepEqual(commands, want) {
		t.Fatalf("commands = %#v, want %#v", commands, want)
	}
}

func TestAutomaticNixInstallRequiresAndUsesConfirmation(t *testing.T) {
	oldSearch, oldRunner := packageSearchRunner, commandRunner
	oldConfirm := nixInstallConfirmer
	t.Cleanup(func() {
		packageSearchRunner = oldSearch
		commandRunner = oldRunner
		nixInstallConfirmer = oldConfirm
	})
	packageSearchRunner = func(source, query string, exact bool) ([]packageMatch, error) {
		if source == "apk" {
			return nil, nil
		}
		return []packageMatch{{
			Source: "Nix", Name: query, Version: "1.2", Attribute: "firefox-bin",
		}}, nil
	}
	var commands [][]string
	commandRunner = func(name string, args ...string) error {
		commands = append(commands, append([]string{name}, args...))
		return nil
	}
	nixInstallConfirmer = func(candidates []packageMatch) (bool, error) {
		if len(candidates) != 1 || candidates[0].Name != "firefox" || candidates[0].Attribute != "firefox-bin" {
			t.Fatalf("confirmation candidates = %#v", candidates)
		}
		return false, nil
	}
	if err := dispatch("install", "auto", []string{"firefox"}); err == nil {
		t.Fatal("installed a Nix candidate without approval")
	}
	if len(commands) != 0 {
		t.Fatalf("ran commands after decline: %#v", commands)
	}
	nixInstallConfirmer = func([]packageMatch) (bool, error) { return true, nil }
	if err := dispatch("install", "auto", []string{"firefox"}); err != nil {
		t.Fatal(err)
	}
	want := [][]string{{
		"nix", "--extra-experimental-features", "nix-command flakes",
		"profile", "install", "nixpkgs#firefox-bin",
	}}
	if !reflect.DeepEqual(commands, want) {
		t.Fatalf("commands = %#v, want %#v", commands, want)
	}
}

func TestAutomaticNixInstallShowsAndInstallsEveryCandidate(t *testing.T) {
	oldSearch, oldRunner, oldConfirm := packageSearchRunner, commandRunner, nixInstallConfirmer
	t.Cleanup(func() {
		packageSearchRunner, commandRunner, nixInstallConfirmer = oldSearch, oldRunner, oldConfirm
	})
	packageSearchRunner = func(source, query string, exact bool) ([]packageMatch, error) {
		if source == "apk" {
			return nil, nil
		}
		return []packageMatch{{Source: "Nix", Name: query, Attribute: query}}, nil
	}
	var commands [][]string
	commandRunner = func(name string, args ...string) error {
		commands = append(commands, append([]string{name}, args...))
		return nil
	}
	nixInstallConfirmer = func(candidates []packageMatch) (bool, error) {
		if len(candidates) != 2 || candidates[0].Name != "ripgrep" || candidates[1].Name != "wezterm" {
			t.Fatalf("confirmation candidates = %#v", candidates)
		}
		return true, nil
	}
	if err := dispatchAutoInstall([]string{"ripgrep", "wezterm"}); err != nil {
		t.Fatal(err)
	}
	want := [][]string{{
		"nix", "--extra-experimental-features", "nix-command flakes", "profile", "install",
		"nixpkgs#ripgrep", "nixpkgs#wezterm",
	}}
	if !reflect.DeepEqual(commands, want) {
		t.Fatalf("commands = %#v, want %#v", commands, want)
	}
}

func TestAutomaticAPKInstallDeclineDoesNotRunPackageManager(t *testing.T) {
	oldSearch, oldRunner, oldConfirm := packageSearchRunner, commandRunner, apkInstallConfirmer
	t.Cleanup(func() {
		packageSearchRunner, commandRunner, apkInstallConfirmer = oldSearch, oldRunner, oldConfirm
	})
	packageSearchRunner = func(source, query string, exact bool) ([]packageMatch, error) {
		if source != "apk" || query != "nano" || !exact {
			t.Fatalf("unexpected search: %s %q exact=%t", source, query, exact)
		}
		return []packageMatch{{Source: "Alpine/Veyra APK", Name: "nano"}}, nil
	}
	var commands [][]string
	commandRunner = func(name string, args ...string) error {
		commands = append(commands, append([]string{name}, args...))
		return nil
	}
	apkInstallConfirmer = func(candidates []packageMatch) (bool, error) { return false, nil }
	if err := dispatchAutoInstall([]string{"nano"}); err == nil {
		t.Fatal("installation continued after declining the plan")
	}
	want := [][]string{{"apk", "add", "--simulate", "nano"}}
	if !reflect.DeepEqual(commands, want) {
		t.Fatalf("commands after decline = %#v, want only the dry-run plan %#v", commands, want)
	}
}

func TestAutomaticAPKInstallStopsWhenSimulationFails(t *testing.T) {
	oldSearch, oldRunner, oldConfirm := packageSearchRunner, commandRunner, apkInstallConfirmer
	t.Cleanup(func() {
		packageSearchRunner, commandRunner, apkInstallConfirmer = oldSearch, oldRunner, oldConfirm
	})
	packageSearchRunner = func(source, query string, exact bool) ([]packageMatch, error) {
		return []packageMatch{{Source: "Alpine/Veyra APK", Name: query}}, nil
	}
	var commands [][]string
	commandRunner = func(name string, args ...string) error {
		commands = append(commands, append([]string{name}, args...))
		return errors.New("simulation failed")
	}
	apkInstallConfirmer = func([]packageMatch) (bool, error) {
		t.Fatal("confirmed an unvalidated package plan")
		return false, nil
	}
	if err := dispatchAutoInstall([]string{"nano"}); err == nil {
		t.Fatal("accepted a failed package simulation")
	}
	want := [][]string{{"apk", "add", "--simulate", "nano"}}
	if !reflect.DeepEqual(commands, want) {
		t.Fatalf("commands = %#v, want %#v", commands, want)
	}
}

func TestAutomaticInstallRequiresTTYConfirmation(t *testing.T) {
	oldStdin := os.Stdin
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	writer.Close()
	os.Stdin = reader
	t.Cleanup(func() {
		os.Stdin = oldStdin
		reader.Close()
	})
	if _, err := confirmAPKInstall([]packageMatch{{Source: "Alpine/Veyra APK", Name: "nano"}}); err == nil ||
		!strings.Contains(err.Error(), "--from alpine") {
		t.Fatalf("non-interactive install confirmation error = %v", err)
	}
}

func TestAutomaticInstallDetectsLocalFormats(t *testing.T) {
	oldRunner, oldAppImage := commandRunner, appImageInstaller
	oldPath := glenvFetchDepsPath
	glenvFetchDepsPath = "/test/fetch-deps.py"
	t.Cleanup(func() {
		commandRunner = oldRunner
		appImageInstaller = oldAppImage
		glenvFetchDepsPath = oldPath
	})
	var commands [][]string
	commandRunner = func(name string, args ...string) error {
		commands = append(commands, append([]string{name}, args...))
		return nil
	}
	var installedAppImage string
	appImageInstaller = func(path string) error {
		installedAppImage = path
		return nil
	}
	if err := dispatch("install", "auto", []string{"./sample.deb"}); err != nil {
		t.Fatal(err)
	}
	if err := dispatch("install", "auto", []string{"./Demo.AppImage"}); err != nil {
		t.Fatal(err)
	}
	if installedAppImage != "./Demo.AppImage" {
		t.Fatalf("AppImage installer received %q", installedAppImage)
	}
	want := [][]string{{"python3", "/test/fetch-deps.py", "--deb-file", "./sample.deb"}}
	if !reflect.DeepEqual(commands, want) {
		t.Fatalf("commands = %#v, want %#v", commands, want)
	}
}

func TestNixAttributeConversion(t *testing.T) {
	attribute := "legacyPackages.x86_64-linux.python3Packages.foo"
	if got, want := nixAttributeName(attribute), "foo"; got != want {
		t.Fatalf("nixAttributeName = %q, want %q", got, want)
	}
	if got, want := nixInstallAttribute(attribute), "python3Packages.foo"; got != want {
		t.Fatalf("nixInstallAttribute = %q, want %q", got, want)
	}
}

func TestAPKSearchUsesExactMatchWhenSelectingInstallSource(t *testing.T) {
	oldOutput := commandOutput
	t.Cleanup(func() { commandOutput = oldOutput })
	commandOutput = func(name string, args ...string) ([]byte, error) {
		if name != "apk" || !reflect.DeepEqual(args, []string{"search", "--quiet", "--exact", "busybox"}) {
			t.Fatalf("apk search command = %s %#v", name, args)
		}
		return []byte("busybox\n"), nil
	}
	matches, err := searchPackageSource("apk", "busybox", true)
	if err != nil {
		t.Fatal(err)
	}
	want := []packageMatch{{Source: "Alpine/Veyra APK", Name: "busybox"}}
	if !reflect.DeepEqual(matches, want) {
		t.Fatalf("matches = %#v, want %#v", matches, want)
	}
}

func TestNixSearchDecodesJSONAndFiltersExactPackage(t *testing.T) {
	oldOutput := commandOutput
	t.Cleanup(func() { commandOutput = oldOutput })
	commandOutput = func(name string, args ...string) ([]byte, error) {
		if name != "nix" || !reflect.DeepEqual(args, []string{
			"--extra-experimental-features", "nix-command flakes", "search", "--json",
			"nixpkgs", "^firefox$",
		}) {
			t.Fatalf("nix search command = %s %#v", name, args)
		}
		return []byte(`{
            "legacyPackages.x86_64-linux.firefox": {
                "name": "firefox-1.2", "pname": "firefox", "version": "1.2",
                "description": "Web browser"
            },
            "legacyPackages.x86_64-linux.firefox-esr": {
                "name": "firefox-esr-2", "pname": "firefox-esr", "version": "2",
                "description": "Firefox ESR web browser"
            }
        }`), nil
	}
	matches, err := searchPackageSource("nix", "firefox", true)
	if err != nil {
		t.Fatal(err)
	}
	want := []packageMatch{{
		Source: "Nix", Name: "firefox", Version: "1.2", Description: "Web browser", Attribute: "firefox",
	}}
	if !reflect.DeepEqual(matches, want) {
		t.Fatalf("matches = %#v, want %#v", matches, want)
	}
}

func TestAutomaticSearchChecksBothBackends(t *testing.T) {
	oldSearch := packageSearchRunner
	t.Cleanup(func() { packageSearchRunner = oldSearch })
	var sources []string
	packageSearchRunner = func(source, query string, exact bool) ([]packageMatch, error) {
		if query != "discord" || exact {
			t.Fatalf("unexpected search query: %s %q exact=%t", source, query, exact)
		}
		sources = append(sources, source)
		return nil, nil
	}
	if err := dispatch("search", "auto", []string{"discord"}); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(sources, []string{"apk", "nix"}) {
		t.Fatalf("searched sources = %#v", sources)
	}
}

func TestAutomaticInstallRejectsMixedBackends(t *testing.T) {
	oldSearch := packageSearchRunner
	t.Cleanup(func() { packageSearchRunner = oldSearch })
	packageSearchRunner = func(source, query string, exact bool) ([]packageMatch, error) {
		if source == "apk" && query == "firefox" {
			return []packageMatch{{Name: query}}, nil
		}
		if source == "nix" && query == "discord" {
			return []packageMatch{{Name: query, Attribute: query}}, nil
		}
		return nil, nil
	}
	if err := dispatch("install", "auto", []string{"firefox", "discord"}); err == nil {
		t.Fatal("accepted a transaction spanning APK and Nix")
	}
}
