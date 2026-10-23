// Package update validates authenticated metadata for a paired Veyra release.
package update

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"strings"
)

const (
	ManifestFormat = "veyra-pair-release-v1"
	Architecture   = "x86_64"
	maxManifest    = 1 << 20
	maxPackages    = 4096
)

var (
	idPattern     = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
	compatPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$`)
	packageSpec   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+_.-]*(?:@[A-Za-z0-9][A-Za-z0-9._-]*)?(?:(?:=|<|>|~)[A-Za-z0-9+_.-]+)?$`)
	packageName   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+_.-]*$`)
	packageVer    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+_.-]*$`)
)

// Environment describes the package selection and compatibility contract
// for one root. World entries are APK constraints; required versions are
// release-owned packages that every installation of the root must contain.
type Environment struct {
	ID               string            `json:"id"`
	Provides         string            `json:"provides"`
	RequiresOther    string            `json:"requires_other"`
	Repositories     []string          `json:"repositories"`
	World            []string          `json:"world"`
	RequiredPackages map[string]string `json:"required_packages"`
}

// Manifest is the signed release description used to select a compatible
// system/user environment pair. The signature covers the exact JSON bytes.
type Manifest struct {
	Format       string      `json:"format"`
	Release      string      `json:"release"`
	Sequence     uint64      `json:"sequence"`
	Architecture string      `json:"architecture"`
	System       Environment `json:"system"`
	User         Environment `json:"user"`
}

// VerifySignedManifest checks a raw or base64-encoded Ed25519 public key and
// signature, verifies the exact manifest bytes, and rejects malformed or
// incompatible release metadata.
func VerifySignedManifest(document, signatureData, publicKeyData []byte) (Manifest, error) {
	if len(document) == 0 || len(document) > maxManifest {
		return Manifest{}, fmt.Errorf("manifest size must be between 1 and %d bytes", maxManifest)
	}
	publicKey, err := decodeKeyMaterial(publicKeyData, ed25519.PublicKeySize, "public key")
	if err != nil {
		return Manifest{}, err
	}
	signature, err := decodeKeyMaterial(signatureData, ed25519.SignatureSize, "signature")
	if err != nil {
		return Manifest{}, err
	}
	if !ed25519.Verify(ed25519.PublicKey(publicKey), document, signature) {
		return Manifest{}, errors.New("release manifest signature verification failed")
	}
	if err := rejectDuplicateJSONKeys(document); err != nil {
		return Manifest{}, fmt.Errorf("invalid signed release manifest: %w", err)
	}

	decoder := json.NewDecoder(bytes.NewReader(document))
	decoder.DisallowUnknownFields()
	var manifest Manifest
	if err := decoder.Decode(&manifest); err != nil {
		return Manifest{}, fmt.Errorf("decode signed release manifest: %w", err)
	}
	if err := decoder.Decode(new(any)); !errors.Is(err, io.EOF) {
		if err == nil {
			return Manifest{}, errors.New("manifest contains trailing JSON data")
		}
		return Manifest{}, fmt.Errorf("decode trailing manifest data: %w", err)
	}
	if err := manifest.Validate(); err != nil {
		return Manifest{}, err
	}
	return manifest, nil
}

// Validate checks all fields that can influence release or package selection.
func (m Manifest) Validate() error {
	if m.Format != ManifestFormat {
		return fmt.Errorf("unsupported release manifest format %q", m.Format)
	}
	if !idPattern.MatchString(m.Release) || strings.Contains(m.Release, "..") {
		return errors.New("release identifier is invalid")
	}
	if m.Sequence == 0 {
		return errors.New("release sequence must be greater than zero")
	}
	if m.Architecture != Architecture {
		return fmt.Errorf("unsupported release architecture %q", m.Architecture)
	}
	if err := m.System.validate("system"); err != nil {
		return err
	}
	if err := m.User.validate("user"); err != nil {
		return err
	}
	if m.System.ID == m.User.ID {
		return errors.New("system and user environment identifiers must differ")
	}
	if m.System.RequiresOther != m.User.Provides {
		return errors.New("system release does not accept the user environment compatibility ID")
	}
	if m.User.RequiresOther != m.System.Provides {
		return errors.New("user release does not accept the system environment compatibility ID")
	}
	return nil
}

func (e Environment) validate(label string) error {
	if !idPattern.MatchString(e.ID) || strings.Contains(e.ID, "..") {
		return fmt.Errorf("%s environment identifier is invalid", label)
	}
	if !compatPattern.MatchString(e.Provides) || !compatPattern.MatchString(e.RequiresOther) {
		return fmt.Errorf("%s environment compatibility ID is invalid", label)
	}
	if len(e.Repositories) == 0 {
		return fmt.Errorf("%s environment has no APK repositories", label)
	}
	seenRepositories := make(map[string]struct{}, len(e.Repositories))
	for _, repository := range e.Repositories {
		if err := validateRepository(repository); err != nil {
			return fmt.Errorf("%s environment repository: %w", label, err)
		}
		if _, ok := seenRepositories[repository]; ok {
			return fmt.Errorf("%s environment repeats repository %q", label, repository)
		}
		seenRepositories[repository] = struct{}{}
	}
	if len(e.World) == 0 || len(e.World) > maxPackages {
		return fmt.Errorf("%s environment must define between 1 and %d APK world entries", label, maxPackages)
	}
	seenWorld := make(map[string]struct{}, len(e.World))
	for _, constraint := range e.World {
		if !packageSpec.MatchString(constraint) {
			return fmt.Errorf("%s environment has invalid APK world constraint %q", label, constraint)
		}
		if _, ok := seenWorld[constraint]; ok {
			return fmt.Errorf("%s environment repeats APK world constraint %q", label, constraint)
		}
		seenWorld[constraint] = struct{}{}
	}
	if len(e.RequiredPackages) == 0 || len(e.RequiredPackages) > maxPackages {
		return fmt.Errorf("%s environment must define between 1 and %d required APK packages", label, maxPackages)
	}
	for name, version := range e.RequiredPackages {
		if !packageName.MatchString(name) || !packageVer.MatchString(version) {
			return fmt.Errorf("%s environment has invalid required APK package %q", label, name)
		}
	}
	return nil
}

func validateRepository(value string) error {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" ||
		parsed.Opaque != "" || parsed.User != nil || parsed.RawQuery != "" || parsed.ForceQuery || parsed.Fragment != "" ||
		strings.ContainsAny(value, "\r\n\t ") {
		return fmt.Errorf("repository must be an HTTPS URL without credentials, query, or fragment: %q", value)
	}
	return nil
}

func rejectDuplicateJSONKeys(document []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(document))
	if err := scanJSONValue(decoder); err != nil {
		return err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("trailing JSON data")
		}
		return err
	}
	return nil
}

func scanJSONValue(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delimiter, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delimiter {
	case '{':
		seen := make(map[string]struct{})
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return errors.New("object member name is not a string")
			}
			if _, exists := seen[key]; exists {
				return fmt.Errorf("duplicate JSON object member %q", key)
			}
			seen[key] = struct{}{}
			if err := scanJSONValue(decoder); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil || closing != json.Delim('}') {
			return errors.New("unterminated JSON object")
		}
	case '[':
		for decoder.More() {
			if err := scanJSONValue(decoder); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil || closing != json.Delim(']') {
			return errors.New("unterminated JSON array")
		}
	default:
		return errors.New("unexpected JSON delimiter")
	}
	return nil
}

func decodeKeyMaterial(data []byte, size int, label string) ([]byte, error) {
	if len(data) == size {
		return append([]byte(nil), data...), nil
	}
	encoded := strings.TrimSpace(string(data))
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(decoded) != size {
		return nil, fmt.Errorf("%s must be %d raw bytes or base64-encoded", label, size)
	}
	return decoded, nil
}
