// veyra-atomic-update stages a signed system/user APK release into inactive
// deployment roots, verifies both roots, and only then arms a one-boot trial.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	update "veyra-update"
)

const (
	defaultStore       = "/var/lib/veyra/store"
	channelFile        = "/etc/veyra/update-manifest-url"
	publicKeyFile      = "/etc/veyra/trust/update-ed25519.pub"
	bootctlPath        = "/usr/local/sbin/veyra-bootctl"
	deploymentScript   = "/usr/local/lib/veyra/veyra-deployment.sh"
	maxChannelFile     = 4096
	maxKeyFile         = 256
	maxSequenceFile    = 64
	maxHTTPManifest    = 1 << 20
	maxHTTPSignature   = 256
	maxBootStatusBytes = 16 << 10
)

var environmentID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "veyra-atomic-update:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	flags := flag.NewFlagSet("veyra-atomic-update", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	check := flags.Bool("check", false, "show whether a newer signed release is available")
	store := flags.String("store", defaultStore, "mounted Veyra deployment store")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("usage: veyra-atomic-update [--check] [--store STORE]")
	}
	if !filepath.IsAbs(*store) || filepath.Clean(*store) == filepath.Dir(filepath.Clean(*store)) {
		return errors.New("deployment store must be an absolute path")
	}
	manifestURL, err := readUpdateURL(channelFile)
	if err != nil {
		return err
	}
	publicKey, err := readProtectedFile(publicKeyFile, maxKeyFile)
	if err != nil {
		return fmt.Errorf("read trusted update key: %w", err)
	}
	release, err := fetchAndVerify(manifestURL, publicKey)
	if err != nil {
		return err
	}
	if !*check && os.Geteuid() != 0 {
		return errors.New("applying a paired release requires root; run sudo veyra-update")
	}
	var lock *os.File
	if !*check {
		lock, err = acquireUpdateLock(*store)
		if err != nil {
			return err
		}
		defer releaseUpdateLock(lock)
	}
	if *check {
		_, _, sequence, err := readStoredRelease("/", publicKey)
		if err != nil {
			return err
		}
		return printCheck(release, sequence)
	}
	current, err := readConfirmedPair(*store, publicKey)
	if err != nil {
		return err
	}
	backend := &systemBackend{store: filepath.Clean(*store), publicKey: publicKey}
	plan, err := update.ApplyPairedUpdate(release, current, backend)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(struct {
		Status     string `json:"status"`
		Release    string `json:"release"`
		Sequence   uint64 `json:"sequence"`
		SystemID   string `json:"system_id"`
		UserID     string `json:"user_id"`
		NextAction string `json:"next_action"`
	}{"trial_armed", release.Manifest().Release, plan.Target.Sequence,
		plan.Target.SystemID, plan.Target.UserID, "reboot to test the paired release"})
}

func readUpdateURL(path string) (*url.URL, error) {
	data, err := readProtectedFile(path, maxChannelFile)
	if err != nil {
		return nil, fmt.Errorf("read update channel URL: %w", err)
	}
	value := strings.TrimSpace(string(data))
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil ||
		parsed.Opaque != "" || parsed.RawQuery != "" || parsed.ForceQuery || parsed.Fragment != "" ||
		strings.ContainsAny(value, "\r\n\t ") {
		return nil, errors.New("update channel must be a plain HTTPS manifest URL without credentials, query, or fragment")
	}
	return parsed, nil
}

func fetchAndVerify(manifestURL *url.URL, publicKey []byte) (update.VerifiedRelease, error) {
	client := &http.Client{
		Timeout: 45 * time.Second,
		CheckRedirect: func(request *http.Request, previous []*http.Request) error {
			if request.URL.Scheme != "https" || !strings.EqualFold(request.URL.Host, manifestURL.Host) {
				return errors.New("update server redirected outside its HTTPS host")
			}
			if len(previous) >= 5 {
				return errors.New("too many update server redirects")
			}
			return nil
		},
	}
	document, err := fetchHTTPS(client, manifestURL, maxHTTPManifest)
	if err != nil {
		return update.VerifiedRelease{}, fmt.Errorf("download signed release manifest: %w", err)
	}
	signatureURL := *manifestURL
	signatureURL.Path += ".sig"
	signatureURL.RawPath = ""
	signature, err := fetchHTTPS(client, &signatureURL, maxHTTPSignature)
	if err != nil {
		return update.VerifiedRelease{}, fmt.Errorf("download release signature: %w", err)
	}
	release, err := update.VerifyRelease(document, signature, publicKey)
	if err != nil {
		return update.VerifiedRelease{}, err
	}
	return release, nil
}

func fetchHTTPS(client *http.Client, target *url.URL, limit int64) ([]byte, error) {
	request, err := http.NewRequestWithContext(context.Background(), http.MethodGet, target.String(), nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", "Veyra-Atomic-Updater/0.1")
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.Request == nil || response.Request.URL.Scheme != "https" {
		return nil, errors.New("update server response did not use HTTPS")
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("update server returned HTTP %d", response.StatusCode)
	}
	if response.ContentLength > limit {
		return nil, fmt.Errorf("update response exceeds %d bytes", limit)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("update response exceeds %d bytes", limit)
	}
	return data, nil
}

func readConfirmedPair(store string, publicKey []byte) (update.ConfirmedPair, error) {
	status, err := commandOutput(bootctlPath, "--store", store, "status")
	if err != nil {
		return update.ConfirmedPair{}, fmt.Errorf("read boot selection: %w", err)
	}
	confirmed, trial, err := parseBootStatus(string(status))
	if err != nil {
		return update.ConfirmedPair{}, err
	}
	if trial != "none" {
		return update.ConfirmedPair{}, fmt.Errorf("a trial deployment %s is already armed", trial)
	}
	running, err := readEnvironmentID("/etc/veyra/deployment-id")
	if err != nil {
		return update.ConfirmedPair{}, fmt.Errorf("read running deployment ID: %w", err)
	}
	cmdlineID, err := runningDeploymentID()
	if err != nil {
		return update.ConfirmedPair{}, err
	}
	if running != confirmed || cmdlineID != confirmed {
		return update.ConfirmedPair{}, errors.New("running generation is not the last confirmed deployment")
	}
	systemRoot := filepath.Join(store, "deployments", confirmed)
	userID, err := readEnvironmentID(filepath.Join(systemRoot, "etc", "veyra", "user-environment-id"))
	if err != nil {
		return update.ConfirmedPair{}, fmt.Errorf("read paired user environment ID: %w", err)
	}
	if _, err := commandOutput("/bin/sh", deploymentScript, "verify-pair", store, confirmed, userID); err != nil {
		return update.ConfirmedPair{}, fmt.Errorf("verify current paired roots: %w", err)
	}
	userRoot := filepath.Join(store, "user-environments", userID)
	world, err := update.ReadAPKWorld(filepath.Join(userRoot, "etc", "apk", "world"))
	if err != nil {
		return update.ConfirmedPair{}, fmt.Errorf("read current user APK world: %w", err)
	}
	systemRelease, systemHasRelease, sequence, err := readStoredRelease(systemRoot, publicKey)
	if err != nil {
		return update.ConfirmedPair{}, err
	}
	userRelease, userHasRelease, userSequence, err := readStoredRelease(userRoot, publicKey)
	if err != nil {
		return update.ConfirmedPair{}, err
	}
	if systemHasRelease != userHasRelease || sequence != userSequence {
		return update.ConfirmedPair{}, errors.New("confirmed system/user release metadata does not match")
	}
	if systemHasRelease {
		systemManifest := systemRelease.Manifest()
		userManifest := userRelease.Manifest()
		if systemManifest.System.ID != confirmed || systemManifest.User.ID != userID ||
			userManifest.System.ID != confirmed || userManifest.User.ID != userID ||
			!bytes.Equal(systemRelease.Document(), userRelease.Document()) ||
			!bytes.Equal(systemRelease.Signature(), userRelease.Signature()) {
			return update.ConfirmedPair{}, errors.New("confirmed system/user roots contain different signed release metadata")
		}
	}
	return update.ConfirmedPair{SystemID: confirmed, UserID: userID, Sequence: sequence, UserWorld: world}, nil
}

func parseBootStatus(status string) (confirmed, trial string, err error) {
	if len(status) > maxBootStatusBytes {
		return "", "", errors.New("boot status output is too large")
	}
	for _, field := range strings.Fields(status) {
		key, value, found := strings.Cut(field, "=")
		if !found {
			continue
		}
		switch key {
		case "confirmed":
			if confirmed != "" {
				return "", "", errors.New("boot status repeats the confirmed deployment")
			}
			confirmed = value
		case "trial":
			if trial != "" {
				return "", "", errors.New("boot status repeats the trial deployment")
			}
			trial = value
		}
	}
	if !validID(confirmed) || (trial != "none" && !validID(trial)) {
		return "", "", errors.New("boot status has invalid or missing confirmed/trial deployment IDs")
	}
	return confirmed, trial, nil
}

func runningDeploymentID() (string, error) {
	data, err := readRegularFile("/proc/cmdline", 1<<20)
	if err != nil {
		return "", fmt.Errorf("read kernel command line: %w", err)
	}
	var found string
	for _, token := range strings.Fields(string(data)) {
		if !strings.HasPrefix(token, "veyra_deployment=") {
			continue
		}
		if found != "" {
			return "", errors.New("kernel command line repeats the Veyra deployment ID")
		}
		found = strings.TrimPrefix(token, "veyra_deployment=")
	}
	if !validID(found) {
		return "", errors.New("kernel command line has no valid Veyra deployment ID")
	}
	return found, nil
}

func readStoredRelease(root string, publicKey []byte) (update.VerifiedRelease, bool, uint64, error) {
	metadata := filepath.Join(root, "etc", "veyra")
	paths := []string{
		filepath.Join(metadata, "release-manifest.json"),
		filepath.Join(metadata, "release-manifest.json.sig"),
		filepath.Join(metadata, "release-sequence"),
	}
	exists := 0
	for _, path := range paths {
		if _, err := os.Lstat(path); err == nil {
			exists++
		} else if !errors.Is(err, os.ErrNotExist) {
			return update.VerifiedRelease{}, false, 0, err
		}
	}
	if exists == 0 {
		return update.VerifiedRelease{}, false, 0, nil
	}
	if exists != len(paths) {
		return update.VerifiedRelease{}, false, 0, errors.New("paired release metadata is incomplete")
	}
	document, err := readRegularFile(paths[0], maxHTTPManifest)
	if err != nil {
		return update.VerifiedRelease{}, false, 0, fmt.Errorf("read stored release manifest: %w", err)
	}
	signature, err := readRegularFile(paths[1], maxHTTPSignature)
	if err != nil {
		return update.VerifiedRelease{}, false, 0, fmt.Errorf("read stored release signature: %w", err)
	}
	sequenceData, err := readRegularFile(paths[2], maxSequenceFile)
	if err != nil {
		return update.VerifiedRelease{}, false, 0, fmt.Errorf("read stored release sequence: %w", err)
	}
	sequence, err := strconv.ParseUint(strings.TrimSpace(string(sequenceData)), 10, 64)
	if err != nil || sequence == 0 {
		return update.VerifiedRelease{}, false, 0, errors.New("stored release sequence is invalid")
	}
	release, err := update.VerifyRelease(document, signature, publicKey)
	if err != nil {
		return update.VerifiedRelease{}, false, 0, fmt.Errorf("verify stored signed release: %w", err)
	}
	if release.Manifest().Sequence != sequence {
		return update.VerifiedRelease{}, false, 0, errors.New("stored release sequence disagrees with its signed manifest")
	}
	return release, true, sequence, nil
}

func printCheck(release update.VerifiedRelease, currentSequence uint64) error {
	manifest := release.Manifest()
	available := manifest.Sequence > currentSequence
	result := struct {
		Status            string `json:"status"`
		Release           string `json:"release"`
		Sequence          uint64 `json:"sequence"`
		ConfirmedSequence uint64 `json:"confirmed_sequence"`
		Available         bool   `json:"available"`
		SystemID          string `json:"system_id"`
		UserID            string `json:"user_id"`
	}{"verified", manifest.Release, manifest.Sequence, currentSequence, available,
		manifest.System.ID, manifest.User.ID}
	return json.NewEncoder(os.Stdout).Encode(result)
}

type systemBackend struct {
	store     string
	publicKey []byte
}

func (b *systemBackend) GenerationExists(id string) bool {
	for _, parent := range []string{"deployments", "user-environments"} {
		if _, err := os.Lstat(filepath.Join(b.store, parent, id)); err == nil || !errors.Is(err, os.ErrNotExist) {
			return true
		}
	}
	return false
}

func (b *systemBackend) StagePair(source, target update.ConfirmedPair) error {
	_, err := commandOutput("/bin/sh", deploymentScript, "stage-pair", b.store,
		source.SystemID, target.SystemID, source.UserID, target.UserID)
	return err
}

func (b *systemBackend) ConfigureAPK(id string, environment update.Environment, world []string) error {
	root, err := b.rootPath(id)
	if err != nil {
		return err
	}
	return update.WriteAPKConfiguration(root, environment, world)
}

func (b *systemBackend) UpgradeAPK(id string) error {
	root, err := b.rootPath(id)
	if err != nil {
		return err
	}
	const script = `set -eu
root=$1
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    umount "$root/tmp" 2>/dev/null || :
    umount "$root/run" 2>/dev/null || :
    umount "$root/sys" 2>/dev/null || :
    umount "$root/proc" 2>/dev/null || :
    umount "$root/dev" 2>/dev/null || :
    exit "$result"
}
trap cleanup EXIT HUP INT TERM
mount --rbind /dev "$root/dev"
mount --rbind /proc "$root/proc"
mount --rbind /sys "$root/sys"
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$root/run"
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$root/tmp"
apk --root "$root" --repositories-file "$root/etc/apk/repositories" update
apk --root "$root" --repositories-file "$root/etc/apk/repositories" upgrade --available
`
	_, err = commandOutput("unshare", "--mount", "--propagation", "private", "--fork", "--",
		"/bin/sh", "-c", script, "veyra-apk-update", root)
	return err
}

func (b *systemBackend) VerifyRequiredPackages(id string, required map[string]string) error {
	root, err := b.rootPath(id)
	if err != nil {
		return err
	}
	return update.VerifyRequiredPackages(root, required)
}

func (b *systemBackend) RebuildSystemInitramfs(id string) error {
	root := filepath.Join(b.store, "deployments", id)
	if !validID(id) {
		return errors.New("invalid system generation ID")
	}
	const script = `set -eu
root=$1
generation=$2
patched="$root/boot/.veyra-init-$generation"
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    rm -f "$patched"
    umount "$root/tmp" 2>/dev/null || :
    umount "$root/run" 2>/dev/null || :
    umount "$root/sys" 2>/dev/null || :
    umount "$root/proc" 2>/dev/null || :
    umount "$root/dev" 2>/dev/null || :
    exit "$result"
}
trap cleanup EXIT HUP INT TERM
mount --rbind /dev "$root/dev"
mount --rbind /proc "$root/proc"
mount --rbind /sys "$root/sys"
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$root/run"
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$root/tmp"
count=0
kernel=
for modules in "$root"/lib/modules/*; do
    [ -d "$modules" ] || continue
    [ ! -L "$modules" ] || { echo 'symlinked kernel modules directory' >&2; exit 1; }
    count=$((count + 1))
    kernel=${modules##*/}
done
[ "$count" -eq 1 ] || { echo 'expected exactly one installed kernel modules directory' >&2; exit 1; }
[ ! -e "$patched" ] && [ ! -L "$patched" ] || { echo 'stale Veyra init script exists' >&2; exit 1; }
chroot "$root" /usr/local/lib/veyra/build-veyra-init.sh "/boot/.veyra-init-$generation"
chroot "$root" mkinitfs -i "/boot/.veyra-init-$generation" -o /boot/initramfs-lts "$kernel"
test -s "$root/boot/vmlinuz-lts"
test -s "$root/boot/initramfs-lts"
`
	_, err := commandOutput("unshare", "--mount", "--propagation", "private", "--fork", "--",
		"/bin/sh", "-c", script, "veyra-mkinitfs", root, id)
	if err != nil {
		return err
	}
	return nil
}

func (b *systemBackend) WriteReleaseMetadata(id string, release update.VerifiedRelease) error {
	root, err := b.rootPath(id)
	if err != nil {
		return err
	}
	return update.WriteReleaseMetadata(root, release)
}

func (b *systemBackend) VerifyPair(systemID, userID string) error {
	_, err := commandOutput("/bin/sh", deploymentScript, "verify-pair", b.store, systemID, userID)
	return err
}

func (b *systemBackend) DiscardStagedPair(source, target update.ConfirmedPair) error {
	current, err := readConfirmedPair(b.store, b.publicKey)
	if err != nil {
		return fmt.Errorf("cannot prove the source pair is still confirmed: %w", err)
	}
	if current.SystemID != source.SystemID || current.UserID != source.UserID {
		return errors.New("confirmed source pair changed; refusing to discard staged roots")
	}
	grubConfig, err := readRegularFile(filepath.Join(b.store, "boot", "grub", "grub.cfg"), 4<<20)
	if err != nil {
		return fmt.Errorf("read GRUB menu before cleanup: %w", err)
	}
	if bytes.Contains(grubConfig, []byte("veyra_deployment="+target.SystemID)) ||
		bytes.Contains(grubConfig, []byte("veyra-"+target.SystemID)) {
		return errors.New("target generation appears in GRUB configuration; refusing cleanup")
	}
	systemRoot := filepath.Join(b.store, "deployments", target.SystemID)
	userRoot := filepath.Join(b.store, "user-environments", target.UserID)
	if err := requireNoSymlinkComponents(systemRoot); err != nil {
		return err
	}
	if err := requireNoSymlinkComponents(userRoot); err != nil {
		return err
	}
	if id, err := readEnvironmentID(filepath.Join(systemRoot, "etc", "veyra", "deployment-id")); err != nil || id != target.SystemID {
		return errors.New("staged system identity cannot be proven; refusing cleanup")
	}
	if id, err := readEnvironmentID(filepath.Join(systemRoot, "etc", "veyra", "user-environment-id")); err != nil || id != target.UserID {
		return errors.New("staged system/user pairing cannot be proven; refusing cleanup")
	}
	if id, err := readEnvironmentID(filepath.Join(userRoot, "etc", "veyra", "user-environment-id")); err != nil || id != target.UserID {
		return errors.New("staged user identity cannot be proven; refusing cleanup")
	}
	if err := os.RemoveAll(systemRoot); err != nil {
		return fmt.Errorf("remove inactive system generation: %w", err)
	}
	if err := os.RemoveAll(userRoot); err != nil {
		return fmt.Errorf("remove inactive user environment: %w", err)
	}
	for _, parent := range []string{filepath.Dir(systemRoot), filepath.Dir(userRoot)} {
		directory, err := os.Open(parent)
		if err != nil {
			return err
		}
		err = directory.Sync()
		directory.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

func (b *systemBackend) Activate(systemID string) error {
	_, err := commandOutput(bootctlPath, "--store", b.store, "activate", systemID)
	return err
}

func (b *systemBackend) rootPath(id string) (string, error) {
	if !validID(id) {
		return "", errors.New("invalid environment generation ID")
	}
	systemRoot := filepath.Join(b.store, "deployments", id)
	userRoot := filepath.Join(b.store, "user-environments", id)
	_, systemErr := os.Lstat(systemRoot)
	_, userErr := os.Lstat(userRoot)
	systemExists := systemErr == nil
	userExists := userErr == nil
	if systemExists == userExists {
		return "", fmt.Errorf("generation ID %s does not identify exactly one staged environment root", id)
	}
	if systemErr != nil && !errors.Is(systemErr, os.ErrNotExist) {
		return "", systemErr
	}
	if userErr != nil && !errors.Is(userErr, os.ErrNotExist) {
		return "", userErr
	}
	if systemExists {
		return systemRoot, nil
	}
	return userRoot, nil
}

func acquireUpdateLock(store string) (*os.File, error) {
	if err := requireNoSymlinkComponents(store); err != nil {
		return nil, err
	}
	bootState := filepath.Join(store, "boot-state")
	info, err := os.Lstat(bootState)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("Veyra boot-state directory is missing or unsafe")
	}
	path := filepath.Join(bootState, ".update-lock")
	fd, err := syscall.Open(path, syscall.O_CREAT|syscall.O_RDWR|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, fmt.Errorf("open update lock: %w", err)
	}
	lock := os.NewFile(uintptr(fd), path)
	opened, statErr := lock.Stat()
	pathInfo, pathErr := os.Lstat(path)
	if statErr != nil || pathErr != nil || !opened.Mode().IsRegular() ||
		pathInfo.Mode()&os.ModeSymlink != 0 || !os.SameFile(opened, pathInfo) {
		lock.Close()
		return nil, errors.New("update lock is not a regular non-symlink file")
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, errors.New("another Veyra update transaction is running")
	}
	return lock, nil
}

func releaseUpdateLock(lock *os.File) {
	_ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	_ = lock.Close()
}

func readEnvironmentID(path string) (string, error) {
	data, err := readRegularFile(path, 128)
	if err != nil {
		return "", err
	}
	id := strings.TrimSpace(string(data))
	if !validID(id) {
		return "", fmt.Errorf("invalid environment ID in %s", filepath.Clean(path))
	}
	return id, nil
}

func validID(value string) bool {
	return environmentID.MatchString(value) && !strings.Contains(value, "..")
}

func readProtectedFile(path string, limit int64) ([]byte, error) {
	if err := requireNoSymlinkComponents(path); err != nil {
		return nil, err
	}
	data, info, err := readRegularFileInfo(path, limit)
	if err != nil {
		return nil, err
	}
	if info.Mode().Perm()&0022 != 0 {
		return nil, errors.New("trusted configuration is group- or world-writable")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 {
		return nil, errors.New("trusted configuration is not owned by root")
	}
	return data, nil
}

func requireNoSymlinkComponents(path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("protected path must be absolute")
	}
	path = filepath.Clean(path)
	for current := path; ; current = filepath.Dir(current) {
		info, err := os.Lstat(current)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("symlink path component is forbidden: %s", current)
		}
		parent := filepath.Dir(current)
		if parent == current {
			break
		}
	}
	return nil
}

func readRegularFile(path string, limit int64) ([]byte, error) {
	data, _, err := readRegularFileInfo(path, limit)
	return data, err
}

func readRegularFileInfo(path string, limit int64) ([]byte, os.FileInfo, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil {
		return nil, nil, err
	}
	pathInfo, err := os.Lstat(path)
	if err != nil {
		return nil, nil, err
	}
	if !opened.Mode().IsRegular() || opened.Size() > limit || pathInfo.Mode()&os.ModeSymlink != 0 || !os.SameFile(opened, pathInfo) {
		return nil, nil, fmt.Errorf("%s must be a regular non-symlink file no larger than %d bytes", filepath.Clean(path), limit)
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, nil, err
	}
	if int64(len(data)) > limit {
		return nil, nil, fmt.Errorf("%s exceeds %d bytes", filepath.Clean(path), limit)
	}
	return data, opened, nil
}

func commandOutput(name string, arguments ...string) ([]byte, error) {
	command := exec.Command(name, arguments...)
	var standardError bytes.Buffer
	command.Stderr = &standardError
	output, err := command.Output()
	if err != nil {
		detail := strings.TrimSpace(standardError.String())
		if detail == "" {
			detail = strings.TrimSpace(string(output))
		}
		if detail != "" {
			return output, fmt.Errorf("%s: %w: %s", name, err, detail)
		}
		return output, fmt.Errorf("%s: %w", name, err)
	}
	return output, nil
}
