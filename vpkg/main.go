// vpkg is the package frontend for the isolated Veyra user environment.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

const version = "0.2.0-dev"

func usage() {
	fmt.Print(`vpkg ` + version + ` - Veyra package manager

Usage:
  vpkg install <package>... [--from apk|nix]
  vpkg remove <package>...  [--from apk|nix]
  vpkg search <term>        [--from apk|nix]
  vpkg info <package>       [--from apk|nix]
  vpkg list                 [--from apk|nix]
  vpkg update
  vpkg upgrade              [--from apk|nix]
  vpkg version
  vpkg help

By default, install checks untagged Alpine APK repositories first, then the
signed @veyra APK repository, then the current user's Nix profile. --from apk
uses APK only and --from nix selects Nix directly. Package operations are
refused unless /run/veyra/user-environment contains user-v1. The current
installer does not start the user environment yet. System packages use ordinary
apk inside the protected system shell.
`)
}

func parse(args []string) (string, []string, error) {
	source := "auto"
	var rest []string
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--from":
			if i+1 >= len(args) {
				return "", nil, fmt.Errorf("--from requires apk or nix")
			}
			source = args[i+1]
			i++
		case strings.HasPrefix(args[i], "--from="):
			source = strings.TrimPrefix(args[i], "--from=")
		case strings.HasPrefix(args[i], "-"):
			return "", nil, fmt.Errorf("unknown option: %s", args[i])
		default:
			rest = append(rest, args[i])
		}
	}
	// Keep the former name as an alias for scripts already using it. The APK
	// backend searches all configured APK repositories, not just Alpine's.
	if source == "alpine" {
		source = "apk"
	}
	if source != "auto" && source != "apk" && source != "nix" {
		return "", nil, fmt.Errorf("unsupported source %q", source)
	}
	return source, rest, nil
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	return nil
}

// A trusted environment launcher creates this marker inside the user root.
// It is an accidental-misuse guard, not the isolation boundary; the user
// namespace and mount layout must keep the system root unreachable.
var userEnvironmentMarker = "/run/veyra/user-environment"

func requireUserEnvironment() error {
	data, err := os.ReadFile(userEnvironmentMarker)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("vpkg only runs inside the Veyra user environment")
	}
	if err != nil {
		return fmt.Errorf("cannot read Veyra user-environment marker: %w", err)
	}
	if strings.TrimSpace(string(data)) != "user-v1" {
		return fmt.Errorf("invalid Veyra user-environment marker")
	}
	return nil
}

func userEngine() string {
	if _, err := exec.LookPath("vpkg-engine"); err == nil {
		return "vpkg-engine"
	}
	return "apk" // Used only after the user-environment guard succeeds.
}

// apkRepositoryFiles creates temporary repository lists for deterministic
// source priority. The configured @veyra repository is excluded from the
// Alpine pass, gets its own lookup list, and is tagged in the combined list
// used for Veyra installs so Alpine remains preferred for dependencies.
func apkRepositoryFiles() (alpineFile, veyraFile, combinedFile string, cleanup func(), err error) {
	repositoriesPath := os.Getenv("VPKG_APK_REPOSITORIES_FILE")
	if repositoriesPath == "" {
		repositoriesPath = "/etc/apk/repositories"
	}
	data, err := os.ReadFile(repositoriesPath)
	if err != nil {
		return "", "", "", nil, fmt.Errorf("read APK repositories: %w", err)
	}

	var alpineLines, veyraLines, combinedLines []string
	hasVeyra := false
	for _, original := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(original)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		veyra := strings.HasPrefix(line, "@veyra ") || strings.Contains(line, "veyra-pkgrepo")
		if veyra {
			hasVeyra = true
			line = strings.TrimSpace(strings.TrimPrefix(line, "@veyra "))
			veyraLines = append(veyraLines, line)
			combinedLines = append(combinedLines, "@veyra "+line)
			continue
		}
		alpineLines = append(alpineLines, line)
		combinedLines = append(combinedLines, line)
	}
	if !hasVeyra {
		return "", "", "", nil, fmt.Errorf("no signed Veyra APK repository is configured")
	}

	writeRepositories := func(lines []string) (string, error) {
		file, createErr := os.CreateTemp("", "vpkg-repositories-*")
		if createErr != nil {
			return "", createErr
		}
		name := file.Name()
		if _, createErr = file.WriteString(strings.Join(lines, "\n") + "\n"); createErr != nil {
			file.Close()
			os.Remove(name)
			return "", createErr
		}
		if createErr = file.Close(); createErr != nil {
			os.Remove(name)
			return "", createErr
		}
		return name, nil
	}

	alpineFile, err = writeRepositories(alpineLines)
	if err != nil {
		return "", "", "", nil, fmt.Errorf("create Alpine APK repository list: %w", err)
	}
	veyraFile, err = writeRepositories(veyraLines)
	if err != nil {
		os.Remove(alpineFile)
		return "", "", "", nil, fmt.Errorf("create Veyra APK repository list: %w", err)
	}
	combinedFile, err = writeRepositories(combinedLines)
	if err != nil {
		os.Remove(alpineFile)
		os.Remove(veyraFile)
		return "", "", "", nil, fmt.Errorf("create combined APK repository list: %w", err)
	}
	cleanup = func() {
		os.Remove(alpineFile)
		os.Remove(veyraFile)
		os.Remove(combinedFile)
	}
	return alpineFile, veyraFile, combinedFile, cleanup, nil
}

func apkPackageAvailable(engine, repositoriesFile, packageName string) (bool, error) {
	cmd := exec.Command(engine, "--repositories-file", repositoriesFile, "search", "--exact", "--quiet", packageName)
	cmd.Stdin = os.Stdin
	output, err := cmd.Output()
	if err != nil {
		return false, fmt.Errorf("search APK repositories for %s: %w", packageName, err)
	}
	return strings.TrimSpace(string(output)) != "", nil
}

func installAutomatically(packages []string) error {
	engine := userEngine()
	alpineRepos, veyraRepos, combinedRepos, cleanup, err := apkRepositoryFiles()
	if err != nil {
		return err
	}
	defer cleanup()

	// Update only Alpine first. A missing index or unreachable Alpine source is
	// an error, not evidence that the package should be installed from Nix.
	if err := run(engine, "--repositories-file", alpineRepos, "update"); err != nil {
		return err
	}

	var alpinePackages, unresolved []string
	for _, packageName := range packages {
		available, err := apkPackageAvailable(engine, alpineRepos, packageName)
		if err != nil {
			return err
		}
		if available {
			alpinePackages = append(alpinePackages, packageName)
		} else {
			unresolved = append(unresolved, packageName)
		}
	}

	var veyraPackages, nixPackages []string
	if len(unresolved) > 0 {
		// Refresh the signed Veyra index only when Alpine has no candidate.
		// The combined config keeps the Veyra source tagged for installation.
		if err := run(engine, "--repositories-file", combinedRepos, "update"); err != nil {
			return err
		}
		for _, packageName := range unresolved {
			available, err := apkPackageAvailable(engine, veyraRepos, packageName)
			if err != nil {
				return err
			}
			if available {
				veyraPackages = append(veyraPackages, packageName)
			} else {
				nixPackages = append(nixPackages, packageName)
			}
		}
	}

	// Resolve every requested package before starting any install transaction.
	// One APK solve preserves Alpine as the default source and pins only the
	// packages confirmed to exist solely in Veyra.
	var apkPackages []string
	apkPackages = append(apkPackages, alpinePackages...)
	for _, packageName := range veyraPackages {
		apkPackages = append(apkPackages, packageName+"@veyra")
	}
	if len(apkPackages) > 0 {
		args := []string{"--repositories-file", combinedRepos, "add"}
		if err := run(engine, append(args, apkPackages...)...); err != nil {
			return err
		}
	}
	for _, packageName := range nixPackages {
		if err := run("nix", "profile", "install", "nixpkgs#"+packageName); err != nil {
			return err
		}
	}
	return nil
}

func dispatch(action, source string, packages []string) error {
	if err := requireUserEnvironment(); err != nil {
		return err
	}
	if source == "alpine" {
		source = "apk"
	}
	if source == "auto" {
		if action == "install" {
			if len(packages) == 0 {
				return fmt.Errorf("%s requires a package name", action)
			}
			return installAutomatically(packages)
		}
		source = "apk"
	}
	need := func() error {
		if len(packages) == 0 {
			return fmt.Errorf("%s requires a package name", action)
		}
		return nil
	}
	if source == "apk" {
		engine := userEngine()
		switch action {
		case "install":
			if e := need(); e != nil {
				return e
			}
			return run(engine, append([]string{"add"}, packages...)...)
		case "remove":
			if e := need(); e != nil {
				return e
			}
			return run(engine, append([]string{"del"}, packages...)...)
		case "search":
			if e := need(); e != nil {
				return e
			}
			return run(engine, append([]string{"search"}, packages...)...)
		case "info":
			if e := need(); e != nil {
				return e
			}
			return run(engine, append([]string{"info", "-a"}, packages...)...)
		case "list":
			return run(engine, "info")
		case "update":
			return run(engine, "update")
		case "upgrade":
			return run(engine, "upgrade")
		}
	} else {
		switch action {
		case "install":
			if e := need(); e != nil {
				return e
			}
			for _, p := range packages {
				if e := run("nix", "profile", "install", "nixpkgs#"+p); e != nil {
					return e
				}
			}
			return nil
		case "remove":
			if e := need(); e != nil {
				return e
			}
			return run("nix", append([]string{"profile", "remove"}, packages...)...)
		case "search", "info":
			if e := need(); e != nil {
				return e
			}
			return run("nix", append([]string{"search", "nixpkgs"}, packages...)...)
		case "list":
			return run("nix", "profile", "list")
		case "upgrade":
			return run("nix", "profile", "upgrade", "--all")
		}
	}
	return fmt.Errorf("unsupported command %q for %s", action, source)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	action := os.Args[1]
	if action == "help" || action == "--help" || action == "-h" {
		usage()
		return
	}
	if action == "version" || action == "--version" {
		fmt.Println("vpkg", version)
		return
	}
	source, packages, err := parse(os.Args[2:])
	if err == nil {
		err = dispatch(action, source, packages)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "vpkg:", err)
		os.Exit(1)
	}
}
