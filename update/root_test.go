package update

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadAndWriteAPKConfiguration(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc", "apk"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "etc", "veyra"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "etc", "veyra", "user-environment-id"), []byte("U-next\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "etc", "apk", "world"), []byte("alpine-base=3.21-r0\nfirefox\n"), 0644); err != nil {
		t.Fatal(err)
	}
	world, err := ReadAPKWorld(filepath.Join(root, "etc", "apk", "world"))
	if err != nil {
		t.Fatal(err)
	}
	current, err := MergeUserWorld([]string{"alpine-base=3.22-r0", "vpkg@veyra=0.1-r0"}, world)
	if err != nil {
		t.Fatal(err)
	}
	environment := Environment{
		ID: "U-next", Provides: "user-api-v1", RequiresOther: "system-api-v1",
		Repositories: []Repository{
			{URL: "https://packages.example.invalid/alpine/main"},
			{URL: "https://packages.example.invalid/veyra/v1", Tag: "veyra"},
		},
		World:            []string{"alpine-base=3.22-r0", "vpkg@veyra=0.1-r0"},
		RequiredPackages: map[string]string{"alpine-base": "3.22-r0", "vpkg": "0.1-r0"},
	}
	if err := WriteAPKConfiguration(root, environment, current); err != nil {
		t.Fatal(err)
	}
	repositories, err := os.ReadFile(filepath.Join(root, "etc", "apk", "repositories"))
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(repositories), "https://packages.example.invalid/alpine/main\n@veyra https://packages.example.invalid/veyra/v1\n"; got != want {
		t.Fatalf("repositories = %q, want %q", got, want)
	}
	worldBytes, err := os.ReadFile(filepath.Join(root, "etc", "apk", "world"))
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(worldBytes), "alpine-base=3.22-r0\nvpkg@veyra=0.1-r0\nfirefox\n"; got != want {
		t.Fatalf("world = %q, want %q", got, want)
	}
}

func TestWriteAPKConfigurationRejectsSymlinkedAPKDirectory(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "etc"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "etc", "veyra"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "etc", "veyra", "user-environment-id"), []byte("U-next\n"), 0644); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "etc", "apk")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	environment := Environment{
		ID: "U-next", Provides: "user-api-v1", RequiresOther: "system-api-v1",
		Repositories: []Repository{{URL: "https://packages.example.invalid/user"}},
		World:        []string{"alpine-base"}, RequiredPackages: map[string]string{"alpine-base": "3.22-r0"},
	}
	if err := WriteAPKConfiguration(root, environment, environment.World); err == nil ||
		!strings.Contains(err.Error(), "real directory") {
		t.Fatalf("symlinked APK directory was not rejected: %v", err)
	}
	if _, err := os.Stat(filepath.Join(outside, "repositories")); !os.IsNotExist(err) {
		t.Fatalf("wrote repositories outside staged root: %v", err)
	}
}

func TestVerifyRequiredPackagesUsesExactInstalledVersions(t *testing.T) {
	root := t.TempDir()
	databasePath := filepath.Join(root, "lib", "apk", "db", "installed")
	if err := os.MkdirAll(filepath.Dir(databasePath), 0755); err != nil {
		t.Fatal(err)
	}
	database := "P:alpine-base\nV:3.22.0-r1\nA:x86_64\n\nP:vpkg\nV:0.1.0-r1\nA:x86_64\n"
	if err := os.WriteFile(databasePath, []byte(database), 0644); err != nil {
		t.Fatal(err)
	}
	required := map[string]string{"alpine-base": "3.22.0-r1", "vpkg": "0.1.0-r1"}
	if err := VerifyRequiredPackages(root, required); err != nil {
		t.Fatal(err)
	}
	if err := VerifyRequiredPackages(root, map[string]string{"vpkg": "0.1.1-r0"}); err == nil ||
		!strings.Contains(err.Error(), "want \"0.1.1-r0\"") {
		t.Fatalf("wrong installed package version was accepted: %v", err)
	}
}

func TestWriteReleaseMetadataPreservesSignedDocumentAndSequence(t *testing.T) {
	document, signature, key := signedFixture(t, nil)
	release, err := VerifyRelease(document, signature, key)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc", "veyra"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "etc", "veyra", "deployment-id"), []byte("S-2026-10-23\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := WriteReleaseMetadata(root, release); err != nil {
		t.Fatal(err)
	}
	for relative, expected := range map[string]string{
		"etc/veyra/release-manifest.json":     string(document),
		"etc/veyra/release-manifest.json.sig": string(signature),
		"etc/veyra/release-sequence":          "1\n",
	} {
		got, err := os.ReadFile(filepath.Join(root, relative))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != expected {
			t.Errorf("%s = %q, want %q", relative, got, expected)
		}
	}
}

func TestWriteReleaseMetadataRequiresMatchingEnvironmentKindAndID(t *testing.T) {
	document, signature, key := signedFixture(t, nil)
	release, err := VerifyRelease(document, signature, key)
	if err != nil {
		t.Fatal(err)
	}

	userRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(userRoot, "etc", "veyra"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(userRoot, "etc", "veyra", "user-environment-id"), []byte("U-2026-10-23\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := WriteReleaseMetadata(userRoot, release); err != nil {
		t.Fatalf("valid user root rejected: %v", err)
	}

	wrongSystemRoot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(wrongSystemRoot, "etc", "veyra"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(wrongSystemRoot, "etc", "veyra", "deployment-id"), []byte("U-2026-10-23\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(wrongSystemRoot, "etc", "veyra", "user-environment-id"), []byte("U-2026-10-23\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := WriteReleaseMetadata(wrongSystemRoot, release); err == nil ||
		!strings.Contains(err.Error(), "does not target") {
		t.Fatalf("system root confused with its paired user root: %v", err)
	}
}

func TestSafeRootRejectsFilesystemRoot(t *testing.T) {
	filesystemRoot := string(os.PathSeparator)
	if _, err := safeRoot(filesystemRoot); err == nil {
		t.Fatal("filesystem root was accepted as a staged environment")
	}
}
