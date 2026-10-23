package update

import (
	"fmt"
	"strings"
)

// MergeUserWorld puts release-owned constraints first and keeps installed
// package selections whose package names are not owned by the signed release.
// APK world entries are unique by package name; release constraints replace
// user constraints for the same package, including any repository tag.
func MergeUserWorld(releaseWorld, installedWorld []string) ([]string, error) {
	if len(releaseWorld) == 0 || len(releaseWorld) > maxPackages {
		return nil, fmt.Errorf("release world must contain between 1 and %d APK constraints", maxPackages)
	}
	if len(installedWorld) > maxPackages {
		return nil, fmt.Errorf("installed world exceeds %d APK constraints", maxPackages)
	}

	owned := make(map[string]struct{}, len(releaseWorld))
	merged := make([]string, 0, len(releaseWorld)+len(installedWorld))
	for _, constraint := range releaseWorld {
		name, err := worldPackageName(constraint)
		if err != nil {
			return nil, fmt.Errorf("invalid release APK world constraint %q: %w", constraint, err)
		}
		if _, exists := owned[name]; exists {
			return nil, fmt.Errorf("release world repeats package %q", name)
		}
		owned[name] = struct{}{}
		merged = append(merged, constraint)
	}

	seenInstalled := make(map[string]struct{}, len(installedWorld))
	for _, constraint := range installedWorld {
		name, err := worldPackageName(constraint)
		if err != nil {
			return nil, fmt.Errorf("invalid installed APK world constraint %q: %w", constraint, err)
		}
		if _, exists := seenInstalled[name]; exists {
			return nil, fmt.Errorf("installed world repeats package %q", name)
		}
		seenInstalled[name] = struct{}{}
		if _, releaseOwned := owned[name]; !releaseOwned {
			if len(merged) == maxPackages {
				return nil, fmt.Errorf("merged world exceeds %d APK constraints", maxPackages)
			}
			merged = append(merged, constraint)
		}
	}
	return merged, nil
}

func worldPackageName(constraint string) (string, error) {
	if !packageSpec.MatchString(constraint) {
		return "", fmt.Errorf("invalid APK constraint syntax")
	}
	name := constraint
	if index := strings.IndexAny(name, "=<>~"); index >= 0 {
		name = name[:index]
	}
	if index := strings.IndexByte(name, '@'); index >= 0 {
		name = name[:index]
	}
	return name, nil
}
