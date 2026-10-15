// vpkg: Veyra package frontend for APK, Nix, glenv, and AppImage.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

const version = "0.1.0"

func usage() {
	fmt.Print(`vpkg ` + version + ` - Veyra package manager

Usage:
  vpkg install <package>... [--from auto|alpine|nix]
  vpkg remove <package>...  [--from alpine|nix]
  vpkg search <term>        [--from auto|alpine|nix]
  vpkg info <package>       [--from alpine|nix]
  vpkg list                 [--from alpine|nix]
  vpkg update
  vpkg upgrade              [--from alpine|nix] [--check|--dry-run]
  vpkg install <file.AppImage> --from appimage
  vpkg install <package|file.deb>... --from glenv
  vpkg update|upgrade|history|rollback --from glenv
  vpkg inspect <binary>
  vpkg history --from appimage
  vpkg rollback --from appimage
  vpkg history --from nix
  vpkg rollback --from nix [version]
  vpkg version
  vpkg help

Default install: show the matched source plan and ask before using APK or Nix.
Local .deb and AppImage files are detected automatically. Nix changes the current user's profile.
`)
}

func parse(args []string) (string, []string, error) {
	source := "auto"
	var rest []string
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--from":
			if i+1 >= len(args) {
				return "", nil, fmt.Errorf("--from requires alpine, nix, glenv, or appimage")
			}
			source = args[i+1]
			i++
		case strings.HasPrefix(args[i], "--from="):
			source = strings.TrimPrefix(args[i], "--from=")
		case args[i] == "--check" || args[i] == "--dry-run":
			rest = append(rest, args[i])
		case strings.HasPrefix(args[i], "-"):
			return "", nil, fmt.Errorf("unknown option: %s", args[i])
		default:
			rest = append(rest, args[i])
		}
	}
	if source != "auto" && source != "alpine" && source != "nix" && source != "appimage" && source != "glenv" {
		return "", nil, fmt.Errorf("unsupported source %q (supported: auto, alpine, nix, glenv, appimage)", source)
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

// commandRunner is replaceable in tests so command routing can be verified on
// hosts that do not provide apk or nix.
var commandRunner = run
var appImageInstaller = installAppImage

func runNix(args ...string) error {
	return commandRunner("nix", append([]string{"--extra-experimental-features", "nix-command flakes"}, args...)...)
}

func dispatch(action, source string, packages []string) error {
	dryRun := false
	filtered := packages[:0]
	for _, arg := range packages {
		if arg == "--check" || arg == "--dry-run" {
			dryRun = true
			continue
		}
		filtered = append(filtered, arg)
	}
	packages = filtered
	if dryRun && action != "upgrade" {
		return fmt.Errorf("--check/--dry-run is only supported with upgrade")
	}
	need := func() error {
		if len(packages) == 0 {
			return fmt.Errorf("%s requires a package name", action)
		}
		return nil
	}
	if source == "auto" {
		return dispatchAuto(action, packages, dryRun)
	}
	if source == "alpine" {
		switch action {
		case "install":
			if e := need(); e != nil {
				return e
			}
			return commandRunner("apk", append([]string{"add"}, packages...)...)
		case "remove":
			if e := need(); e != nil {
				return e
			}
			return commandRunner("apk", append([]string{"del"}, packages...)...)
		case "search":
			if e := need(); e != nil {
				return e
			}
			return commandRunner("apk", append([]string{"search"}, packages...)...)
		case "info":
			if e := need(); e != nil {
				return e
			}
			return commandRunner("apk", append([]string{"info", "-a"}, packages...)...)
		case "list":
			return commandRunner("apk", "info")
		case "update":
			return commandRunner("apk", "update")
		case "upgrade":
			if dryRun {
				return commandRunner("apk", "upgrade", "--simulate")
			}
			return commandRunner("apk", "upgrade")
		case "history":
			return fmt.Errorf("Alpine APK transaction history is not available through vpkg yet")
		case "rollback":
			return fmt.Errorf("Alpine APK rollback is not available through vpkg yet")
		}
	} else if source == "appimage" {
		switch action {
		case "install":
			if len(packages) != 1 {
				return fmt.Errorf("install --from appimage requires one local .AppImage file")
			}
			return appImageInstaller(packages[0])
		case "history":
			if len(packages) != 0 {
				return fmt.Errorf("history does not accept package names")
			}
			return showAppImageHistory()
		case "rollback":
			if len(packages) != 0 {
				return fmt.Errorf("AppImage rollback does not accept a transaction id")
			}
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			return rollbackLatestAppImage(home)
		}
		return fmt.Errorf("AppImage source supports install, history, and rollback")
	} else if source == "glenv" {
		return dispatchGlenv(action, packages, dryRun)
	} else {
		switch action {
		case "install":
			if e := need(); e != nil {
				return e
			}
			installables := []string{"profile", "install"}
			for _, p := range packages {
				installables = append(installables, "nixpkgs#"+p)
			}
			return runNix(installables...)
		case "remove":
			if e := need(); e != nil {
				return e
			}
			return runNix(append([]string{"profile", "remove"}, packages...)...)
		case "search", "info":
			if e := need(); e != nil {
				return e
			}
			return runNix(append([]string{"search", "nixpkgs"}, packages...)...)
		case "list":
			return runNix("profile", "list")
		case "upgrade":
			if dryRun {
				return runNix("profile", "upgrade", "--all", "--dry-run")
			}
			return runNix("profile", "upgrade", "--all")
		case "update":
			return runNix("flake", "metadata", "--refresh", "nixpkgs")
		case "history":
			if len(packages) != 0 {
				return fmt.Errorf("history does not accept package names")
			}
			return runNix("profile", "history")
		case "rollback":
			if len(packages) == 0 {
				return runNix("profile", "rollback")
			}
			if len(packages) != 1 {
				return fmt.Errorf("rollback accepts at most one profile version")
			}
			version, err := strconv.ParseUint(packages[0], 10, 64)
			if err != nil || version == 0 {
				return fmt.Errorf("rollback version must be a positive integer")
			}
			return runNix("profile", "rollback", "--to", strconv.FormatUint(version, 10))
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
	if action == "inspect" {
		if err := inspectArgs(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "vpkg:", err)
			os.Exit(1)
		}
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
