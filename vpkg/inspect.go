package main

import (
	"debug/elf"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type binaryInfo struct {
	architecture string
	interpreter  string
	runtime      string
	libraries    []string
	glibc        []string
	missing      []string
}

var glibcVersionPattern = regexp.MustCompile(`GLIBC_[0-9]+(?:\.[0-9]+)+`)

func inspectArgs(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: vpkg inspect <binary>")
	}
	info, err := inspectELF(args[0])
	if err != nil {
		return err
	}
	fmt.Printf("Veyra Compatibility Inspector\n\nBinary: %s\nArchitecture: %s\nFormat: ELF\n", args[0], info.architecture)
	if info.interpreter != "" {
		fmt.Printf("\nInterpreter:\n  %s\n", info.interpreter)
	}
	fmt.Printf("\nDetected runtime: %s\n", info.runtime)
	if len(info.glibc) > 0 {
		fmt.Printf("GLIBC symbol versions: %s\n", strings.Join(info.glibc, ", "))
	}
	if len(info.libraries) > 0 {
		fmt.Printf("\nShared libraries:\n")
		for _, lib := range info.libraries {
			fmt.Printf("  %s\n", lib)
		}
	}
	if len(info.missing) > 0 {
		fmt.Printf("\nMissing glenv libraries (direct dependencies only):\n")
		for _, lib := range info.missing {
			fmt.Printf("  %s\n", lib)
		}
	}
	if info.runtime == "glibc" && info.architecture == "x86_64" {
		fmt.Printf("\nNative execution on musl: Unsupported\nglenv: Candidate (static analysis only)\n")
	} else if info.runtime == "no PT_INTERP" {
		fmt.Printf("\nNative runtime: Unknown (no PT_INTERP recorded)\nglenv: No glibc interpreter detected\n")
	} else {
		fmt.Printf("\nNative execution: Depends on the host runtime\nglenv: Not identified as a glibc candidate\n")
	}
	fmt.Println("\nStatic analysis cannot guarantee that the program will run; it does not check graphics, services, drivers, or runtime data files.")
	return nil
}

func inspectELF(path string) (*binaryInfo, error) {
	f, err := elf.Open(path)
	if err != nil {
		return nil, fmt.Errorf("inspect %q: not a readable ELF binary: %w", path, err)
	}
	defer f.Close()

	info := &binaryInfo{architecture: elfArchitecture(f.Machine), runtime: "unknown"}
	for _, prog := range f.Progs {
		if prog.Type != elf.PT_INTERP {
			continue
		}
		data, err := io.ReadAll(prog.Open())
		if err != nil {
			return nil, fmt.Errorf("read ELF interpreter: %w", err)
		}
		info.interpreter = strings.TrimRight(string(data), "\x00")
		break
	}

	if info.interpreter == "" {
		info.runtime = "no PT_INTERP"
	} else if strings.Contains(filepath.Base(info.interpreter), "ld-linux") || strings.Contains(filepath.Base(info.interpreter), "ld64.so") {
		info.runtime = "glibc"
	} else if strings.Contains(info.interpreter, "musl") {
		info.runtime = "musl"
	}

	if libraries, err := f.ImportedLibraries(); err == nil {
		info.libraries = libraries
		sort.Strings(info.libraries)
	}
	if info.runtime == "glibc" {
		info.missing = missingLibraries(info.libraries, glenvLibraryDirs(info.architecture))
	}
	if section := f.Section(".dynstr"); section != nil {
		if data, err := section.Data(); err == nil {
			versions := map[string]struct{}{}
			for _, version := range glibcVersionPattern.FindAllString(string(data), -1) {
				versions[version] = struct{}{}
			}
			for version := range versions {
				info.glibc = append(info.glibc, version)
			}
			sort.Slice(info.glibc, func(i, j int) bool {
				return compareVersionNumbers(strings.TrimPrefix(info.glibc[i], "GLIBC_"), strings.TrimPrefix(info.glibc[j], "GLIBC_")) < 0
			})
		}
	}
	return info, nil
}

func glenvLibraryDirs(architecture string) []string {
	prefix := os.Getenv("GLENV_PREFIX")
	if prefix == "" {
		prefix = "/opt/glibc-env"
		if _, err := os.Stat(filepath.Join(prefix, "sysroot")); err != nil {
			if home, homeErr := os.UserHomeDir(); homeErr == nil {
				prefix = filepath.Join(home, "glibc-env")
			}
		}
	}
	triplet := ""
	if architecture == "x86_64" {
		triplet = "x86_64-linux-gnu"
	} else if architecture == "aarch64" {
		triplet = "aarch64-linux-gnu"
	}
	root := filepath.Join(prefix, "sysroot")
	dirs := []string{filepath.Join(root, "lib"), filepath.Join(root, "lib64"), filepath.Join(root, "usr", "lib"), filepath.Join(root, "usr", "lib64")}
	if triplet != "" {
		dirs = append(dirs, filepath.Join(root, "lib", triplet), filepath.Join(root, "usr", "lib", triplet))
	}
	return dirs
}

func missingLibraries(libraries, searchDirs []string) []string {
	var missing []string
	for _, library := range libraries {
		if filepath.Base(library) != library {
			missing = append(missing, library)
			continue
		}
		found := false
		for _, dir := range searchDirs {
			if info, err := os.Stat(filepath.Join(dir, library)); err == nil && info.Mode().IsRegular() {
				found = true
				break
			}
		}
		if !found {
			missing = append(missing, library)
		}
	}
	sort.Strings(missing)
	return missing
}

func elfArchitecture(machine elf.Machine) string {
	switch machine {
	case elf.EM_X86_64:
		return "x86_64"
	case elf.EM_AARCH64:
		return "aarch64"
	case elf.EM_386:
		return "i386"
	case elf.EM_ARM:
		return "arm"
	case elf.EM_RISCV:
		return "riscv"
	default:
		return strings.TrimPrefix(machine.String(), "EM_")
	}
}

func compareVersionNumbers(a, b string) int {
	left, right := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(left) || i < len(right); i++ {
		var x, y int
		if i < len(left) {
			for _, r := range left[i] {
				if r < '0' || r > '9' {
					break
				}
				x = x*10 + int(r-'0')
			}
		}
		if i < len(right) {
			for _, r := range right[i] {
				if r < '0' || r > '9' {
					break
				}
				y = y*10 + int(r-'0')
			}
		}
		if x < y {
			return -1
		}
		if x > y {
			return 1
		}
	}
	return 0
}
