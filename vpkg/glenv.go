package main

import (
	"fmt"
	"path/filepath"
	"strings"
)

const defaultGlenvFetchDepsPath = "/usr/share/veyra/glenv/tools/fetch-deps.py"

var glenvFetchDepsPath = defaultGlenvFetchDepsPath

func runGlenv(args ...string) error {
	return commandRunner("python3", append([]string{glenvFetchDepsPath}, args...)...)
}

func dispatchGlenv(action string, packages []string, dryRun bool) error {
	switch action {
	case "install":
		if len(packages) == 0 {
			return fmt.Errorf("install requires a package name or local .deb file")
		}
		for _, item := range packages {
			if strings.EqualFold(filepath.Ext(item), ".deb") {
				if len(packages) != 1 {
					return fmt.Errorf("a local .deb file must be installed by itself")
				}
				return runGlenv("--deb-file", item)
			}
		}
		return runGlenv(append([]string{"--update"}, packages...)...)
	case "update":
		if len(packages) != 0 {
			return fmt.Errorf("update does not accept package names for glenv")
		}
		return runGlenv("--update-index")
	case "upgrade":
		if dryRun {
			return fmt.Errorf("glenv upgrades do not support --check/--dry-run")
		}
		if len(packages) != 0 {
			return fmt.Errorf("upgrade does not accept package names for glenv")
		}
		return runGlenv("upgrade")
	case "history":
		if len(packages) != 0 {
			return fmt.Errorf("history does not accept package names")
		}
		return runGlenv("history")
	case "rollback":
		if len(packages) > 1 {
			return fmt.Errorf("rollback accepts at most one transaction id")
		}
		return runGlenv(append([]string{"rollback"}, packages...)...)
	default:
		return fmt.Errorf("%s is not supported for the glenv source", action)
	}
}
