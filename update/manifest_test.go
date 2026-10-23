package update

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func signedFixture(t *testing.T, mutate func(*Manifest)) ([]byte, []byte, []byte) {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	manifest := Manifest{
		Format: ManifestFormat, Release: "pre-alpha-0.1.0-rc1", Sequence: 1,
		Architecture: Architecture,
		System: Environment{
			ID: "S-2026-10-23", Provides: "system-api-v1", RequiresOther: "user-api-v1",
			Repositories:     []string{"https://packages.veyra.example/system"},
			World:            []string{"alpine-base=3.22.0-r1", "linux-lts=6.12.20-r0"},
			RequiredPackages: map[string]string{"alpine-base": "3.22.0-r1", "linux-lts": "6.12.20-r0"},
		},
		User: Environment{
			ID: "U-2026-10-23", Provides: "user-api-v1", RequiresOther: "system-api-v1",
			Repositories:     []string{"https://packages.veyra.example/user"},
			World:            []string{"alpine-base=3.22.0-r1", "vpkg=0.1.0-r1"},
			RequiredPackages: map[string]string{"alpine-base": "3.22.0-r1", "vpkg": "0.1.0-r1"},
		},
	}
	if mutate != nil {
		mutate(&manifest)
	}
	document, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(privateKey, document)
	return document, []byte(base64.StdEncoding.EncodeToString(signature)),
		[]byte(base64.StdEncoding.EncodeToString(publicKey))
}

func TestVerifySignedManifest(t *testing.T) {
	document, signature, key := signedFixture(t, nil)
	manifest, err := VerifySignedManifest(document, signature, key)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Release != "pre-alpha-0.1.0-rc1" || manifest.System.ID != "S-2026-10-23" ||
		manifest.User.ID != "U-2026-10-23" {
		t.Fatalf("unexpected verified release: %+v", manifest)
	}
}

func TestVerifyRejectsTamperingAndWrongKey(t *testing.T) {
	document, signature, key := signedFixture(t, nil)
	changed := append(append([]byte(nil), document...), ' ')
	if _, err := VerifySignedManifest(changed, signature, key); err == nil ||
		!strings.Contains(err.Error(), "signature verification failed") {
		t.Fatalf("tampered manifest was not rejected: %v", err)
	}
	otherKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifySignedManifest(document, signature,
		[]byte(base64.StdEncoding.EncodeToString(otherKey))); err == nil {
		t.Fatal("manifest verified against an unrelated public key")
	}
}

func TestVerifyRejectsIncompatibleOrUnsafeManifest(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Manifest)
		want   string
	}{
		{"system-user API mismatch", func(m *Manifest) { m.User.RequiresOther = "old-system-api" }, "does not accept"},
		{"HTTP repository", func(m *Manifest) { m.System.Repositories[0] = "http://packages.veyra.example/system" }, "HTTPS URL"},
		{"duplicate package", func(m *Manifest) { m.User.World = append(m.User.World, m.User.World[0]) }, "repeats APK world"},
		{"unsafe package constraint", func(m *Manifest) { m.System.World[0] = "alpine-base;touch /tmp/pwned" }, "invalid APK world"},
		{"unsupported architecture", func(m *Manifest) { m.Architecture = "aarch64" }, "unsupported release architecture"},
		{"zero sequence", func(m *Manifest) { m.Sequence = 0 }, "sequence must be greater than zero"},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			document, signature, key := signedFixture(t, test.mutate)
			if _, err := VerifySignedManifest(document, signature, key); err == nil ||
				!strings.Contains(err.Error(), test.want) {
				t.Fatalf("invalid signed manifest was not rejected as expected: %v", err)
			}
		})
	}
}

func TestVerifyRejectsUnknownFieldsAndTrailingJSON(t *testing.T) {
	document, _, _ := signedFixture(t, nil)
	unknown := append(append([]byte(nil), document[:len(document)-1]...), []byte(`,"unexpected":true}`)...)
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifySignedManifest(unknown, ed25519.Sign(privateKey, unknown), publicKey); err == nil {
		t.Fatal("unknown manifest fields were accepted")
	}

	trailing := append(append([]byte(nil), document...), []byte(` {}`)...)
	if _, err := VerifySignedManifest(trailing, ed25519.Sign(privateKey, trailing), publicKey); err == nil {
		t.Fatal("trailing JSON data was accepted")
	}
}

func TestVerifyRejectsDuplicateJSONKeys(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	document := []byte(`{"format":"veyra-pair-release-v1","format":"veyra-pair-release-v1"}`)
	signature := ed25519.Sign(privateKey, document)
	if _, err := VerifySignedManifest(document, signature, publicKey); err == nil ||
		!strings.Contains(err.Error(), "duplicate JSON object member") {
		t.Fatalf("duplicate object member was not rejected: %v", err)
	}
}
