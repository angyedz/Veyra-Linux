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

The intended install lookup order is Alpine APK repositories, signed
veyra-pkgrepo, then Nix when no APK package exists. This prototype does not yet
perform automatic source fallback: --from apk uses all configured APK repos,
and --from nix selects the current user's Nix profile. Package operations are
refused unless /run/veyra/user-environment contains user-v1. The current
installer does not start the user environment yet. System packages use ordinary
apk inside the protected system shell.
`)
}

func parse(args []string) (string, []string, error) {
	source := "apk"
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
	if source != "apk" && source != "nix" {
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

func dispatch(action, source string, packages []string) error {
	if err := requireUserEnvironment(); err != nil {
		return err
	}
	if source == "alpine" {
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
