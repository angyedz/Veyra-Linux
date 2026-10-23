package update

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const maxAPKDatabase = 64 << 20

// ReadAPKWorld reads a bounded, regular APK world file and returns its
// non-empty constraints in file order.
func ReadAPKWorld(path string) ([]string, error) {
	data, err := readRegular(path, 4<<20)
	if err != nil {
		return nil, err
	}
	var world []string
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 4096), 1<<20)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line != "" {
			world = append(world, line)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read APK world: %w", err)
	}
	if len(world) == 0 || len(world) > maxPackages {
		return nil, errors.New("APK world is empty or exceeds the package limit")
	}
	if _, err := MergeUserWorld(world, nil); err != nil {
		return nil, err
	}
	return world, nil
}

// WriteAPKConfiguration writes only repositories and world inside a staged
// root. Existing APK keys and package database are preserved.
func WriteAPKConfiguration(root string, environment Environment, world []string) error {
	if err := environment.validate("target"); err != nil {
		return err
	}
	if _, err := MergeUserWorld(world, nil); err != nil {
		return fmt.Errorf("validate target APK world: %w", err)
	}
	root, err := safeRoot(root)
	if err != nil {
		return err
	}
	apkDir := filepath.Join(root, "etc", "apk")
	if err := requireSafeDirectory(root, filepath.Join(root, "etc")); err != nil {
		return err
	}
	if err := requireSafeDirectory(root, apkDir); err != nil {
		return err
	}
	repositories, err := environment.APKRepositoryLines()
	if err != nil {
		return err
	}
	if err := atomicWriteRegular(apkDir, filepath.Join(apkDir, "repositories"), []byte(strings.Join(repositories, "\n")+"\n")); err != nil {
		return err
	}
	return atomicWriteRegular(apkDir, filepath.Join(apkDir, "world"), []byte(strings.Join(world, "\n")+"\n"))
}

// VerifyRequiredPackages compares release-owned exact package versions with
// the installed APK database below root.
func VerifyRequiredPackages(root string, required map[string]string) error {
	if len(required) == 0 || len(required) > maxPackages {
		return errors.New("required APK package list is empty or exceeds the package limit")
	}
	root, err := safeRoot(root)
	if err != nil {
		return err
	}
	database := filepath.Join(root, "lib", "apk", "db", "installed")
	if err := requireSafeDirectory(root, filepath.Join(root, "lib")); err != nil {
		return err
	}
	if err := requireSafeDirectory(root, filepath.Join(root, "lib", "apk", "db")); err != nil {
		return err
	}
	installed, err := readInstalledPackageVersions(database)
	if err != nil {
		return err
	}
	for name, wanted := range required {
		if !packageName.MatchString(name) || !packageVer.MatchString(wanted) {
			return fmt.Errorf("invalid required APK package %q", name)
		}
		actual, ok := installed[name]
		if !ok {
			return fmt.Errorf("required APK package %q is not installed", name)
		}
		if actual != wanted {
			return fmt.Errorf("required APK package %q has version %q, want %q", name, actual, wanted)
		}
	}
	return nil
}

// WriteReleaseMetadata stores the exact signed manifest, detached signature
// and sequence in one staged root after its packages have been verified.
func WriteReleaseMetadata(root string, release VerifiedRelease) error {
	manifest := release.Manifest()
	if err := manifest.Validate(); err != nil {
		return fmt.Errorf("invalid paired release metadata: %w", err)
	}
	document, signature := release.Document(), release.Signature()
	if len(document) == 0 || len(signature) == 0 {
		return errors.New("verified release does not contain signed bytes")
	}
	root, err := safeRoot(root)
	if err != nil {
		return err
	}
	veyraDir := filepath.Join(root, "etc", "veyra")
	if err := requireSafeDirectory(root, filepath.Join(root, "etc")); err != nil {
		return err
	}
	if err := requireSafeDirectory(root, veyraDir); err != nil {
		return err
	}
	if err := atomicWriteRegular(veyraDir, filepath.Join(veyraDir, "release-manifest.json"), document); err != nil {
		return err
	}
	if err := atomicWriteRegular(veyraDir, filepath.Join(veyraDir, "release-manifest.json.sig"), signature); err != nil {
		return err
	}
	return atomicWriteRegular(veyraDir, filepath.Join(veyraDir, "release-sequence"), []byte(strconv.FormatUint(manifest.Sequence, 10)+"\n"))
}

func readInstalledPackageVersions(path string) (map[string]string, error) {
	data, err := readRegular(path, maxAPKDatabase)
	if err != nil {
		return nil, fmt.Errorf("read installed APK database: %w", err)
	}
	installed := make(map[string]string)
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 16*1024), 2<<20)
	var name, version string
	finish := func() error {
		if name == "" && version == "" {
			return nil
		}
		if !packageName.MatchString(name) || !packageVer.MatchString(version) {
			return errors.New("installed APK database contains an incomplete package record")
		}
		if _, exists := installed[name]; exists {
			return fmt.Errorf("installed APK database repeats package %q", name)
		}
		installed[name] = version
		name, version = "", ""
		return nil
	}
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			if err := finish(); err != nil {
				return nil, err
			}
			continue
		}
		if strings.HasPrefix(line, "P:") {
			if name != "" {
				return nil, errors.New("installed APK database contains multiple package names in one record")
			}
			name = strings.TrimPrefix(line, "P:")
		}
		if strings.HasPrefix(line, "V:") {
			if version != "" {
				return nil, errors.New("installed APK database contains multiple versions in one record")
			}
			version = strings.TrimPrefix(line, "V:")
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan installed APK database: %w", err)
	}
	if err := finish(); err != nil {
		return nil, err
	}
	if len(installed) == 0 {
		return nil, errors.New("installed APK database has no package records")
	}
	return installed, nil
}

func safeRoot(root string) (string, error) {
	if !filepath.IsAbs(root) {
		return "", errors.New("staged root must be an absolute path")
	}
	root = filepath.Clean(root)
	info, err := os.Lstat(root)
	if err != nil {
		return "", err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("staged root must be a real directory")
	}
	for parent := filepath.Dir(root); parent != root; parent = filepath.Dir(parent) {
		info, err := os.Lstat(parent)
		if err != nil {
			return "", err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("symlink in staged root path: %s", parent)
		}
		if parent == filepath.Dir(parent) {
			break
		}
	}
	return root, nil
}

func requireSafeDirectory(root, directory string) error {
	relative, err := filepath.Rel(root, directory)
	if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(os.PathSeparator)) {
		return errors.New("staged path escapes root")
	}
	current := root
	for _, part := range strings.Split(relative, string(os.PathSeparator)) {
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		if err != nil {
			return err
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("staged path is not a real directory: %s", current)
		}
	}
	return nil
}

func atomicWriteRegular(directory, path string, data []byte) error {
	info, err := os.Lstat(path)
	if err == nil && (!info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0) {
		return fmt.Errorf("refusing to replace non-regular staged file: %s", path)
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".veyra-update-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0644); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	directoryHandle, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer directoryHandle.Close()
	return directoryHandle.Sync()
}

func readRegular(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return nil, err
	}
	pathInfo, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !opened.Mode().IsRegular() || opened.Size() > limit || pathInfo.Mode()&os.ModeSymlink != 0 ||
		!os.SameFile(opened, pathInfo) {
		return nil, fmt.Errorf("%s must be a regular non-symlink file no larger than %d bytes", filepath.Clean(path), limit)
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%s exceeds %d bytes", filepath.Clean(path), limit)
	}
	return data, nil
}
