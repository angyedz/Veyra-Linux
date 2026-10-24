package update

import (
	"errors"
	"fmt"
	"strings"
)

// ConfirmedPair describes the currently confirmed installation. Sequence is
// zero only for a converted installation that predates signed pair metadata.
type ConfirmedPair struct {
	SystemID  string
	UserID    string
	Sequence  uint64
	UserWorld []string
}

// PairUpdatePlan is a fully validated description of the generations and APK
// worlds an updater may stage. Building a plan has no filesystem side effects.
type PairUpdatePlan struct {
	Source ConfirmedPair
	Target ConfirmedPair
	System Environment
	User   Environment
}

// PlanPairedUpdate rejects replay, target reuse and incomplete current state,
// then computes the user world that preserves user-selected APK packages.
func PlanPairedUpdate(release VerifiedRelease, current ConfirmedPair, generationExists func(string) bool) (PairUpdatePlan, error) {
	if generationExists == nil {
		return PairUpdatePlan{}, errors.New("generation existence check is required")
	}
	manifest := release.Manifest()
	if err := manifest.Validate(); err != nil {
		return PairUpdatePlan{}, fmt.Errorf("invalid verified release: %w", err)
	}
	if !idPattern.MatchString(current.SystemID) || strings.Contains(current.SystemID, "..") ||
		!idPattern.MatchString(current.UserID) || strings.Contains(current.UserID, "..") ||
		current.SystemID == current.UserID || current.Sequence == ^uint64(0) {
		return PairUpdatePlan{}, errors.New("current confirmed pair metadata is invalid")
	}
	if len(current.UserWorld) == 0 || len(current.UserWorld) > maxPackages {
		return PairUpdatePlan{}, errors.New("current confirmed user APK world is missing or too large")
	}
	if manifest.Sequence <= current.Sequence {
		return PairUpdatePlan{}, fmt.Errorf("release sequence %d is not newer than confirmed sequence %d", manifest.Sequence, current.Sequence)
	}
	if manifest.System.ID == current.SystemID || manifest.User.ID == current.UserID {
		return PairUpdatePlan{}, errors.New("release generation identifiers must differ from the confirmed pair")
	}
	if generationExists(manifest.System.ID) || generationExists(manifest.User.ID) {
		return PairUpdatePlan{}, errors.New("release generation identifier already exists; refusing to overwrite stored data")
	}
	userWorld, err := MergeUserWorld(manifest.User.World, current.UserWorld)
	if err != nil {
		return PairUpdatePlan{}, fmt.Errorf("merge current user APK world: %w", err)
	}
	target := ConfirmedPair{
		SystemID:  manifest.System.ID,
		UserID:    manifest.User.ID,
		Sequence:  manifest.Sequence,
		UserWorld: append([]string(nil), userWorld...),
	}
	current.UserWorld = append([]string(nil), current.UserWorld...)
	return PairUpdatePlan{
		Source: current,
		Target: target,
		System: cloneEnvironment(manifest.System),
		User:   cloneEnvironment(manifest.User),
	}, nil
}
