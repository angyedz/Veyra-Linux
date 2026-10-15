package main

import (
	"reflect"
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
	oldConfirm := nixInstallConfirmer
	t.Cleanup(func() {
		packageSearchRunner = oldSearch
		commandRunner = oldRunner
		nixInstallConfirmer = oldConfirm
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
	nixInstallConfirmer = func(packageMatch) (bool, error) {
		t.Fatal("Nix confirmation should not run when APK contains the package")
		return false, nil
	}
	commandRunner = func(name string, args ...string) error {
		commands = append(commands, append([]string{name}, args...))
		return nil
	}
	if err := dispatch("install", "auto", []string{"firefox"}); err != nil {
		t.Fatal(err)
	}
	want := [][]string{{"apk", "add", "firefox"}}
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
	nixInstallConfirmer = func(candidate packageMatch) (bool, error) {
		if candidate.Name != "firefox" || candidate.Attribute != "firefox-bin" {
			t.Fatalf("confirmation candidate = %#v", candidate)
		}
		return false, nil
	}
	if err := dispatch("install", "auto", []string{"firefox"}); err == nil {
		t.Fatal("installed a Nix candidate without approval")
	}
	if len(commands) != 0 {
		t.Fatalf("ran commands after decline: %#v", commands)
	}
	nixInstallConfirmer = func(packageMatch) (bool, error) { return true, nil }
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
