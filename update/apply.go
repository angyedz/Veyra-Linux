package update

import "fmt"

// PairedUpdateBackend performs the privileged, platform-specific operations.
// Implementations must keep all package work in inactive roots and must make
// Activate the sole operation that arms a trial boot.
type PairedUpdateBackend interface {
	GenerationExists(id string) bool
	StagePair(source, target ConfirmedPair) error
	ConfigureAPK(rootID string, environment Environment, world []string) error
	UpgradeAPK(rootID string) error
	VerifyRequiredPackages(rootID string, required map[string]string) error
	RebuildSystemInitramfs(rootID string) error
	WriteReleaseMetadata(rootID string, release VerifiedRelease) error
	VerifyPair(systemID, userID string) error
	DiscardStagedPair(source, target ConfirmedPair) error
	Activate(systemID string) error
}

// ApplyPairedUpdate executes package preparation and verification before the
// final trial-boot activation. It deliberately leaves failed inactive roots
// untouched for diagnosis; it never selects a partially prepared generation.
func ApplyPairedUpdate(release VerifiedRelease, current ConfirmedPair, backend PairedUpdateBackend) (PairUpdatePlan, error) {
	if backend == nil {
		return PairUpdatePlan{}, fmt.Errorf("paired update backend is required")
	}
	plan, err := PlanPairedUpdate(release, current, backend.GenerationExists)
	if err != nil {
		return PairUpdatePlan{}, err
	}
	if err := backend.StagePair(plan.Source, plan.Target); err != nil {
		return plan, fmt.Errorf("stage paired roots %s+%s: %w", plan.Target.SystemID, plan.Target.UserID, err)
	}
	if err := backend.ConfigureAPK(plan.Target.SystemID, plan.System, plan.System.World); err != nil {
		return plan, inactiveFailure(backend, "configure system APK selection", plan, err)
	}
	if err := backend.ConfigureAPK(plan.Target.UserID, plan.User, plan.Target.UserWorld); err != nil {
		return plan, inactiveFailure(backend, "configure user APK selection", plan, err)
	}
	if err := backend.UpgradeAPK(plan.Target.SystemID); err != nil {
		return plan, inactiveFailure(backend, "upgrade system APK packages", plan, err)
	}
	if err := backend.UpgradeAPK(plan.Target.UserID); err != nil {
		return plan, inactiveFailure(backend, "upgrade user APK packages", plan, err)
	}
	if err := backend.VerifyRequiredPackages(plan.Target.SystemID, plan.System.RequiredPackages); err != nil {
		return plan, inactiveFailure(backend, "verify required system APK versions", plan, err)
	}
	if err := backend.VerifyRequiredPackages(plan.Target.UserID, plan.User.RequiredPackages); err != nil {
		return plan, inactiveFailure(backend, "verify required user APK versions", plan, err)
	}
	if err := backend.RebuildSystemInitramfs(plan.Target.SystemID); err != nil {
		return plan, inactiveFailure(backend, "rebuild system initramfs", plan, err)
	}
	if err := backend.WriteReleaseMetadata(plan.Target.SystemID, release); err != nil {
		return plan, inactiveFailure(backend, "write system release metadata", plan, err)
	}
	if err := backend.WriteReleaseMetadata(plan.Target.UserID, release); err != nil {
		return plan, inactiveFailure(backend, "write user release metadata", plan, err)
	}
	if err := backend.VerifyPair(plan.Target.SystemID, plan.Target.UserID); err != nil {
		return plan, inactiveFailure(backend, "verify paired roots", plan, err)
	}
	if err := backend.Activate(plan.Target.SystemID); err != nil {
		return plan, fmt.Errorf("activate trial pair %s+%s (inspect boot state before retrying): %w", plan.Target.SystemID, plan.Target.UserID, err)
	}
	return plan, nil
}

func inactiveFailure(backend PairedUpdateBackend, operation string, plan PairUpdatePlan, err error) error {
	if discardErr := backend.DiscardStagedPair(plan.Source, plan.Target); discardErr != nil {
		return fmt.Errorf("%s failed; paired roots %s+%s remain inactive and need recovery: %w (discard failed: %v)",
			operation, plan.Target.SystemID, plan.Target.UserID, err, discardErr)
	}
	return fmt.Errorf("%s failed; unactivated paired roots %s+%s were discarded: %w",
		operation, plan.Target.SystemID, plan.Target.UserID, err)
}
