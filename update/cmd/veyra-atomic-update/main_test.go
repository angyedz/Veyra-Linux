package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	update "veyra-update"
)

func signedReleaseFixture(t *testing.T) (update.VerifiedRelease, []byte) {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	manifest := update.Manifest{
		Format: update.ManifestFormat, Release: "pre-alpha-0.1.0-test", Sequence: 1,
		Architecture: update.Architecture,
		System: update.Environment{
			ID: "S-next", Provides: "system-api-v1", RequiresOther: "user-api-v1",
			Repositories:     []update.Repository{{URL: "https://packages.example.invalid/system"}},
			World:            []string{"alpine-base=3.22.0-r1", "linux-lts=6.12.20-r0"},
			RequiredPackages: map[string]string{"alpine-base": "3.22.0-r1", "linux-lts": "6.12.20-r0"},
		},
		User: update.Environment{
			ID: "U-next", Provides: "user-api-v1", RequiresOther: "system-api-v1",
			Repositories:     []update.Repository{{URL: "https://packages.example.invalid/user", Tag: "veyra"}},
			World:            []string{"alpine-base=3.22.0-r1", "vpkg@veyra=0.1.0-r1"},
			RequiredPackages: map[string]string{"alpine-base": "3.22.0-r1", "vpkg": "0.1.0-r1"},
		},
	}
	document, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(privateKey, document)
	release, err := update.VerifyRelease(document,
		[]byte(base64.StdEncoding.EncodeToString(signature)),
		[]byte(base64.StdEncoding.EncodeToString(publicKey)))
	if err != nil {
		t.Fatal(err)
	}
	return release, []byte(base64.StdEncoding.EncodeToString(publicKey))
}

func TestParseBootStatusRequiresUniqueConfirmedAndTrialValues(t *testing.T) {
	confirmed, trial, err := parseBootStatus("Veyra confirmed=A trial=none filesystem=ext4 uuid=abcd generations=A,B")
	if err != nil || confirmed != "A" || trial != "none" {
		t.Fatalf("parse valid boot status: confirmed=%q trial=%q err=%v", confirmed, trial, err)
	}
	if _, _, err := parseBootStatus("Veyra confirmed=A trial=B filesystem=ext4"); err != nil {
		t.Fatalf("pending trial status should parse for caller policy: %v", err)
	}
	for _, status := range []string{
		"Veyra confirmed=A filesystem=ext4",
		"Veyra confirmed=A confirmed=B trial=none",
		"Veyra confirmed=../bad trial=none",
	} {
		if _, _, err := parseBootStatus(status); err == nil {
			t.Errorf("invalid boot status was accepted: %q", status)
		}
	}
}

func TestValidateRecoveryMarkerRequiresExactVersion(t *testing.T) {
	if err := validateRecoveryMarker([]byte(recoveryMarkerData)); err != nil {
		t.Fatalf("valid recovery marker was rejected: %v", err)
	}
	for _, data := range [][]byte{
		[]byte("VEYRA-RECOVERY-v0\n"),
		[]byte("VEYRA-RECOVERY-v1\nextra"),
		[]byte(""),
	} {
		if err := validateRecoveryMarker(data); err == nil {
			t.Errorf("invalid recovery marker was accepted: %q", data)
		}
	}
}

func TestUpdateTargetsMustUseDifferentFilesystemFromRecoveryRoot(t *testing.T) {
	if err := requireDistinctFilesystemDevices(1, 2, 3); err != nil {
		t.Fatalf("distinct filesystems were rejected: %v", err)
	}
	for _, targetDevice := range []uint64{1, 2} {
		err := requireDistinctFilesystemDevices(1, targetDevice)
		if (targetDevice == 1) != (err != nil) {
			t.Errorf("running device 1 vs target %d: error=%v", targetDevice, err)
		}
	}
}

func TestOfflineUpdateTargetsMustNotBeMounted(t *testing.T) {
	storeMount := "36 25 8:1 / /mnt/veyra rw,relatime - ext4 /dev/sda1 rw\n"
	systemTarget := "/mnt/veyra/deployments/S-next"
	userTarget := "/mnt/veyra/user-environments/U-next"
	if err := requireNoMountedTargets([]byte(storeMount), systemTarget, userTarget); err != nil {
		t.Fatalf("store mount ancestor should be allowed: %v", err)
	}

	for _, mountpoint := range []string{
		"/mnt/veyra/deployments/S-next",
		"/mnt/veyra/deployments/S-next/var/lib/data",
	} {
		mountInfo := "36 25 8:2 / " + mountpoint + " rw,relatime - ext4 /dev/sdb1 rw\n"
		if err := requireNoMountedTargets([]byte(mountInfo), systemTarget, userTarget); err == nil {
			t.Errorf("accepted mounted update target path %q", mountpoint)
		}
	}

	if err := requireNoMountedTargets([]byte("36 25 8:2 / /mnt/veyra\\040deploy/deployments/S-next rw - ext4 /dev/sdb1 rw\n"),
		"/mnt/veyra deploy/deployments/S-next"); err == nil {
		t.Fatal("accepted a target mounted at a path containing an escaped space")
	}
	if err := requireNoMountedTargets([]byte("not mountinfo\n"), systemTarget); err == nil {
		t.Fatal("accepted a malformed mount table")
	}
	if err := requireNoMountedTargets(nil, systemTarget); err == nil {
		t.Fatal("accepted an empty mount table")
	}
}

func TestReadStoredReleaseVerifiesExactSignedSequence(t *testing.T) {
	release, publicKey := signedReleaseFixture(t)
	root := t.TempDir()
	veyraDir := filepath.Join(root, "etc", "veyra")
	if err := os.MkdirAll(veyraDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(veyraDir, "deployment-id"), []byte("S-next\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := update.WriteReleaseMetadata(root, release); err != nil {
		t.Fatal(err)
	}
	stored, present, sequence, err := readStoredRelease(root, publicKey)
	if err != nil || !present || sequence != 1 {
		t.Fatalf("read stored release: present=%t sequence=%d err=%v", present, sequence, err)
	}
	if string(stored.Document()) != string(release.Document()) ||
		string(stored.Signature()) != string(release.Signature()) {
		t.Fatal("stored release bytes differ from the signed release")
	}
	if err := os.WriteFile(filepath.Join(veyraDir, "release-sequence"), []byte("2\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := readStoredRelease(root, publicKey); err == nil ||
		!strings.Contains(err.Error(), "disagrees") {
		t.Fatalf("release sequence tampering was accepted: %v", err)
	}
}

func TestReadStoredReleaseAllowsOnlyCompleteAbsenceForInitialInstall(t *testing.T) {
	release, publicKey := signedReleaseFixture(t)
	_ = release
	root := t.TempDir()
	if _, present, sequence, err := readStoredRelease(root, publicKey); err != nil || present || sequence != 0 {
		t.Fatalf("new converted install metadata: present=%t sequence=%d err=%v", present, sequence, err)
	}
	metadata := filepath.Join(root, "etc", "veyra")
	if err := os.MkdirAll(metadata, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(metadata, "release-sequence"), []byte("1\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := readStoredRelease(root, publicKey); err == nil ||
		!strings.Contains(err.Error(), "incomplete") {
		t.Fatalf("partial release metadata was accepted: %v", err)
	}
}

func TestSystemBackendResolvesSystemAndUserRootsWithoutAmbiguity(t *testing.T) {
	store := t.TempDir()
	backend := &systemBackend{store: store}
	systemPath := filepath.Join(store, "deployments", "S-next")
	userPath := filepath.Join(store, "user-environments", "U-next")
	if err := os.MkdirAll(systemPath, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(userPath, 0755); err != nil {
		t.Fatal(err)
	}
	if got, err := backend.rootPath("S-next"); err != nil || got != systemPath {
		t.Fatalf("system root path = %q, %v", got, err)
	}
	if got, err := backend.rootPath("U-next"); err != nil || got != userPath {
		t.Fatalf("user root path = %q, %v", got, err)
	}
	if err := os.MkdirAll(filepath.Join(store, "deployments", "U-next"), 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := backend.rootPath("U-next"); err == nil {
		t.Fatal("ambiguous system/user generation ID was accepted")
	}
}
