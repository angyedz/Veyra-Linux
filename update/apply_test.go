package update

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

type recordingBackend struct {
	steps    []string
	failAt   string
	existing map[string]bool
}

func (b *recordingBackend) step(name string) error {
	b.steps = append(b.steps, name)
	if b.failAt == name {
		return errors.New("injected backend failure")
	}
	return nil
}

func (b *recordingBackend) GenerationExists(id string) bool { return b.existing[id] }
func (b *recordingBackend) StagePair(_, _ ConfirmedPair) error {
	return b.step("stage")
}
func (b *recordingBackend) ConfigureAPK(id string, _ Environment, _ []string) error {
	return b.step("configure:" + id)
}
func (b *recordingBackend) UpgradeAPK(id string) error { return b.step("upgrade:" + id) }
func (b *recordingBackend) VerifyRequiredPackages(id string, _ map[string]string) error {
	return b.step("verify-packages:" + id)
}
func (b *recordingBackend) RebuildSystemInitramfs(id string) error {
	return b.step("initramfs:" + id)
}
func (b *recordingBackend) WriteReleaseMetadata(id string, _ VerifiedRelease) error {
	return b.step("metadata:" + id)
}
func (b *recordingBackend) VerifyPair(systemID, userID string) error {
	return b.step("verify-pair:" + systemID + "+" + userID)
}
func (b *recordingBackend) DiscardStagedPair(_, _ ConfirmedPair) error {
	return b.step("discard")
}
func (b *recordingBackend) Activate(id string) error { return b.step("activate:" + id) }

func TestApplyPairedUpdateActivatesOnlyAfterBothRootsVerify(t *testing.T) {
	document, signature, key := signedFixture(t, nil)
	release, err := VerifyRelease(document, signature, key)
	if err != nil {
		t.Fatal(err)
	}
	backend := &recordingBackend{existing: map[string]bool{}}
	current := ConfirmedPair{
		SystemID: "S-2026-09-01", UserID: "U-2026-09-01", Sequence: 0,
		UserWorld: []string{"alpine-base", "firefox"},
	}
	plan, err := ApplyPairedUpdate(release, current, backend)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"stage",
		"configure:S-2026-10-23", "configure:U-2026-10-23",
		"upgrade:S-2026-10-23", "upgrade:U-2026-10-23",
		"verify-packages:S-2026-10-23", "verify-packages:U-2026-10-23",
		"initramfs:S-2026-10-23",
		"metadata:S-2026-10-23", "metadata:U-2026-10-23",
		"verify-pair:S-2026-10-23+U-2026-10-23", "activate:S-2026-10-23",
	}
	if !reflect.DeepEqual(backend.steps, want) {
		t.Fatalf("transaction steps = %v, want %v", backend.steps, want)
	}
	if plan.Target.UserWorld[len(plan.Target.UserWorld)-1] != "firefox" {
		t.Fatalf("user package selection was lost: %v", plan.Target.UserWorld)
	}
}

func TestApplyPairedUpdateNeverActivatesAfterPreparationFailure(t *testing.T) {
	document, signature, key := signedFixture(t, nil)
	release, err := VerifyRelease(document, signature, key)
	if err != nil {
		t.Fatal(err)
	}
	backend := &recordingBackend{failAt: "upgrade:U-2026-10-23", existing: map[string]bool{}}
	current := ConfirmedPair{
		SystemID: "S-2026-09-01", UserID: "U-2026-09-01", Sequence: 0,
		UserWorld: []string{"alpine-base"},
	}
	_, err = ApplyPairedUpdate(release, current, backend)
	if err == nil || !strings.Contains(err.Error(), "were discarded") {
		t.Fatalf("failed update did not report safe cleanup: %v", err)
	}
	for _, step := range backend.steps {
		if strings.HasPrefix(step, "activate:") {
			t.Fatalf("activated after failed preparation: %v", backend.steps)
		}
	}
	if got := backend.steps[len(backend.steps)-1]; got != "discard" {
		t.Fatalf("failed preparation did not discard inactive pair: %v", backend.steps)
	}
}

func TestApplyPairedUpdateRejectsExistingTargetBeforeStaging(t *testing.T) {
	document, signature, key := signedFixture(t, nil)
	release, err := VerifyRelease(document, signature, key)
	if err != nil {
		t.Fatal(err)
	}
	backend := &recordingBackend{existing: map[string]bool{"S-2026-10-23": true}}
	current := ConfirmedPair{
		SystemID: "S-2026-09-01", UserID: "U-2026-09-01", Sequence: 0,
		UserWorld: []string{"alpine-base"},
	}
	if _, err := ApplyPairedUpdate(release, current, backend); err == nil {
		t.Fatal("existing target generation was overwritten")
	}
	if len(backend.steps) != 0 {
		t.Fatalf("backend ran before plan was accepted: %v", backend.steps)
	}
}
