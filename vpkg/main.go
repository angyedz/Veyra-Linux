// vpkg: minimal Veyra CLI frontend; transactions remain with APK and Nix.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

const version = "0.1.0"

func usage() {
	fmt.Print(`vpkg ` + version + ` - Veyra package manager

Usage:
  vpkg install <package>... [--from alpine|nix]
  vpkg remove <package>...  [--from alpine|nix]
  vpkg search <term>        [--from alpine|nix]
  vpkg info <package>       [--from alpine|nix]
  vpkg list                 [--from alpine|nix]
  vpkg update
  vpkg upgrade              [--from alpine|nix]
  vpkg inspect <binary>
  vpkg version
  vpkg help

Default source: Alpine APK. Nix commands affect the current user's profile.
`)
}

func parse(args []string) (string, []string, error) {
	source := "alpine"
	var rest []string
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--from":
			if i+1 >= len(args) {
				return "", nil, fmt.Errorf("--from requires alpine or nix")
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
	if source != "alpine" && source != "nix" {
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

// commandRunner is replaceable in tests so command routing can be verified on
// hosts that do not provide apk or nix.
var commandRunner = run

func dispatch(action, source string, packages []string) error {
	need := func() error {
		if len(packages) == 0 {
			return fmt.Errorf("%s requires a package name", action)
		}
		return nil
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
			return commandRunner("apk", "upgrade")
		}
	} else {
		switch action {
		case "install":
			if e := need(); e != nil {
				return e
			}
			for _, p := range packages {
				if e := commandRunner("nix", "profile", "install", "nixpkgs#"+p); e != nil {
					return e
				}
			}
			return nil
		case "remove":
			if e := need(); e != nil {
				return e
			}
			return commandRunner("nix", append([]string{"profile", "remove"}, packages...)...)
		case "search", "info":
			if e := need(); e != nil {
				return e
			}
			return commandRunner("nix", append([]string{"search", "nixpkgs"}, packages...)...)
		case "list":
			return commandRunner("nix", "profile", "list")
		case "upgrade":
			return commandRunner("nix", "profile", "upgrade", "--all")
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
