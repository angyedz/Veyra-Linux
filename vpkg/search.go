package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type packageMatch struct {
	Source      string
	Name        string
	Version     string
	Description string
	Attribute   string
	Unfree      bool
	Broken      bool
}

type nixSearchEntry struct {
	Name        string `json:"name"`
	Pname       string `json:"pname"`
	Version     string `json:"version"`
	Description string `json:"description"`
	Unfree      bool   `json:"unfree"`
	Broken      bool   `json:"broken"`
}

var packageSearchRunner = searchPackageSource
var nixInstallConfirmer = confirmNixInstall
var apkInstallConfirmer = confirmAPKInstall
var commandOutput = captureCommandOutput

var plainPackageName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+._-]*$`)

func captureCommandOutput(name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	output, err := cmd.Output()
	if err != nil {
		if exit, ok := err.(*exec.ExitError); ok && len(exit.Stderr) > 0 {
			return nil, fmt.Errorf("%s: %s", name, strings.TrimSpace(string(exit.Stderr)))
		}
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	return output, nil
}

func searchPackageSource(source, query string, exact bool) ([]packageMatch, error) {
	switch source {
	case "apk":
		args := []string{"search", "--quiet"}
		if exact {
			args = append(args, "--exact")
		}
		output, err := commandOutput("apk", append(args, query)...)
		if err != nil {
			return nil, err
		}
		var matches []packageMatch
		for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
			name := strings.TrimSpace(line)
			if name == "" {
				continue
			}
			matches = append(matches, packageMatch{Source: "Alpine/Veyra APK", Name: name})
		}
		return matches, nil
	case "nix":
		pattern := query
		if exact {
			if !plainPackageName.MatchString(query) {
				return nil, fmt.Errorf("automatic source detection requires a plain package name; select --from explicitly")
			}
			pattern = "^" + query + "$"
		}
		output, err := commandOutput("nix", "--extra-experimental-features", "nix-command flakes",
			"search", "--json", "nixpkgs", pattern)
		if err != nil {
			return nil, err
		}
		var entries map[string]nixSearchEntry
		if err := json.Unmarshal(output, &entries); err != nil {
			return nil, fmt.Errorf("decode Nix search results: %w", err)
		}
		matches := make([]packageMatch, 0, len(entries))
		for attribute, entry := range entries {
			name := entry.Pname
			if name == "" {
				name = nixAttributeName(attribute)
			}
			if exact && name != query && nixAttributeName(attribute) != query {
				continue
			}
			matches = append(matches, packageMatch{
				Source: "Nix", Name: name, Version: entry.Version,
				Description: entry.Description, Attribute: nixInstallAttribute(attribute),
				Unfree: entry.Unfree, Broken: entry.Broken,
			})
		}
		sort.Slice(matches, func(i, j int) bool {
			if matches[i].Name != matches[j].Name {
				return matches[i].Name < matches[j].Name
			}
			return matches[i].Attribute < matches[j].Attribute
		})
		return matches, nil
	default:
		return nil, fmt.Errorf("unknown package search source %q", source)
	}
}

func nixAttributeName(attribute string) string {
	parts := strings.Split(attribute, ".")
	if len(parts) >= 4 && (parts[0] == "legacyPackages" || parts[0] == "packages") {
		return parts[len(parts)-1]
	}
	return parts[len(parts)-1]
}

func nixInstallAttribute(attribute string) string {
	parts := strings.Split(attribute, ".")
	if len(parts) >= 3 && (parts[0] == "legacyPackages" || parts[0] == "packages") {
		return strings.Join(parts[2:], ".")
	}
	return attribute
}

func dispatchAuto(action string, packages []string, dryRun bool) error {
	switch action {
	case "search":
		return dispatchSearchAll(packages)
	case "install":
		return dispatchAutoInstall(packages)
	default:
		return dispatch(action, "alpine", packagesWithDryRun(packages, dryRun))
	}
}

func packagesWithDryRun(packages []string, dryRun bool) []string {
	if !dryRun {
		return packages
	}
	return append(append([]string(nil), packages...), "--dry-run")
}

func dispatchSearchAll(terms []string) error {
	if len(terms) == 0 {
		return fmt.Errorf("search requires a term")
	}
	for _, term := range terms {
		fmt.Printf("Search results for %q\n", term)
		found := false
		failures := 0
		for _, source := range []string{"apk", "nix"} {
			matches, err := packageSearchRunner(source, term, false)
			if err != nil {
				failures++
				fmt.Printf("  %s search unavailable: %v\n", source, err)
				continue
			}
			if len(matches) > 0 {
				found = true
			}
			for _, match := range matches {
				printPackageMatch(match)
			}
		}
		if !found && failures == 0 {
			fmt.Println("  No matches found in APK or Nix sources.")
		} else if !found {
			fmt.Println("  No matches in the sources that responded; check the unavailable source(s) above.")
		}
	}
	return nil
}

func printPackageMatch(match packageMatch) {
	version := match.Version
	if version == "" {
		version = "version not shown by source"
	}
	label := match.Source
	if match.Unfree {
		label += ", unfree"
	}
	if match.Broken {
		label += ", marked broken"
	}
	fmt.Printf("  %-20s %-38s %s\n", label, match.Name, version)
	if match.Description != "" {
		fmt.Printf("    %s\n", match.Description)
	}
}

func dispatchAutoInstall(packages []string) error {
	if len(packages) == 0 {
		return fmt.Errorf("install requires a package name or local package file")
	}
	if len(packages) == 1 {
		switch strings.ToLower(filepath.Ext(packages[0])) {
		case ".deb":
			fmt.Println("Detected a Debian package; validating it through glenv's authenticated package index.")
			return dispatchGlenv("install", packages, false)
		case ".appimage":
			fmt.Println("Detected an AppImage; installing it in the current user's application directory.")
			return dispatch("install", "appimage", packages)
		}
	}

	selectedSource := ""
	var apkMatches []packageMatch
	var nixMatches []packageMatch
	for _, name := range packages {
		if !plainPackageName.MatchString(name) {
			return fmt.Errorf("automatic source selection needs plain package names; use --from alpine or --from nix for %q", name)
		}
		apkFound, err := packageSearchRunner("apk", name, true)
		if err != nil {
			return fmt.Errorf("cannot search enabled Alpine/Veyra repositories: %w", err)
		}
		source := "alpine"
		if len(apkFound) == 0 {
			nixMatchesForName, searchErr := packageSearchRunner("nix", name, true)
			if searchErr != nil {
				return fmt.Errorf("%q was not found in Alpine/Veyra repositories and Nix search failed: %w", name, searchErr)
			}
			if len(nixMatchesForName) == 0 {
				return fmt.Errorf("%q was not found in enabled Alpine/Veyra repositories or Nix; run vpkg search %s", name, name)
			}
			source = "nix"
			nixMatches = append(nixMatches, nixMatchesForName[0])
		} else {
			apkMatches = append(apkMatches, apkFound[0])
		}
		if selectedSource != "" && selectedSource != source {
			return fmt.Errorf("requested packages span APK and Nix; install each source separately or pass --from explicitly")
		}
		selectedSource = source
	}

	if selectedSource == "nix" {
		if currentUserIsRoot() {
			return fmt.Errorf("automatic Nix installation targets the current user's profile; rerun without sudo, or select --from nix explicitly for root's profile")
		}
		fmt.Println("Alpine/Veyra packages were not found. Nix candidates:")
		for _, candidate := range nixMatches {
			printPackageMatch(candidate)
		}
		fmt.Println("Nix packages can have package-specific runtime requirements; this selection does not assume glenv is needed.")
		ok, err := nixInstallConfirmer(nixMatches)
		if err != nil {
			return err
		}
		if !ok {
			return fmt.Errorf("Nix installation declined; use vpkg install --from nix %s to choose it explicitly", strings.Join(packages, " "))
		}
		installables := []string{"profile", "install"}
		for _, match := range nixMatches {
			installables = append(installables, "nixpkgs#"+match.Attribute)
		}
		return runNix(installables...)
	}

	fmt.Println("Found the requested package(s) in enabled Alpine/Veyra APK repositories:")
	for _, candidate := range apkMatches {
		printPackageMatch(candidate)
	}
	planArgs := append([]string{"add", "--simulate"}, packages...)
	if err := commandRunner("apk", planArgs...); err != nil {
		return fmt.Errorf("cannot prepare Alpine/Veyra installation plan: %w", err)
	}
	ok, err := apkInstallConfirmer(apkMatches)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("APK installation declined; use vpkg install --from alpine %s to select it explicitly", strings.Join(packages, " "))
	}
	return dispatch("install", "alpine", packages)
}

func currentUserIsRoot() bool {
	current, err := user.Current()
	return err == nil && current.Uid == "0"
}

func confirmNixInstall(candidates []packageMatch) (bool, error) {
	return confirmInstall("Nix", candidates)
}

func confirmAPKInstall(candidates []packageMatch) (bool, error) {
	return confirmInstall("Alpine/Veyra APK", candidates)
}

func confirmInstall(source string, candidates []packageMatch) (bool, error) {
	info, err := os.Stdin.Stat()
	if err != nil {
		return false, fmt.Errorf("check terminal before selecting a package source: %w", err)
	}
	if info.Mode()&os.ModeCharDevice == 0 {
		sourceFlag := "alpine"
		if source == "Nix" {
			sourceFlag = "nix"
		}
		return false, fmt.Errorf("automatic package installation requires a terminal confirmation; pass --from %s to select the source explicitly", sourceFlag)
	}
	fmt.Printf("Install %d package(s) from %s? [y/N] ", len(candidates), source)
	answer, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil && len(answer) == 0 {
		return false, fmt.Errorf("read package source confirmation: %w", err)
	}
	answer = strings.ToLower(strings.TrimSpace(answer))
	return answer == "y" || answer == "yes", nil
}
