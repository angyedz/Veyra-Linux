# Veyra Linux Pre-Alpha

> Release-note draft. Do not publish until the Veyra Linux Pre-Alpha gate in `docs/ROADMAP.md` passes for the exact ISO and package-repository state. Choose the release version and tag after qualification.

## Intended release

Veyra Linux Pre-Alpha is the first public, deliberately early x86_64 release. Its first qualification target is an ext4 installation tested in QEMU. It may have visible defects and unfinished features. SDDM login, the package workflow, basic user environments, and A/B update with rollback on the qualified target are release-critical.

## Intended core behavior

- SDDM provides the normal authenticated desktop login.
- The system environment owns the kernel, physical devices, boot process and protected system deployments.
- Normal account login starts in Veyra's shared user Linux environment. Accounts retain separate identities and private home directories; the user environment has its own root, package database and init process.
- `vpkg` works only in the user environment. It looks in Alpine APK repositories first, then the signed `veyra-pkgrepo` APK repository, then Nix if the package is absent from both APK sources. `veyra-pkgrepo` contains both system and user packages; system packages are installed with ordinary `apk` only from the password-gated system shell or by the trusted updater.
- A signed release description keeps system and user-environment package sets compatible. Updates stage changes in inactive generations and switch to a new pair only after verification; an unsuccessful trial returns to the previous confirmed pair.
- Personal files and declared persistent user state stay outside OS generations and survive an update or OS rollback.

## Known limits

- The initial qualification target is x86_64 QEMU on ext4. Physical PCs, GPUs and other filesystems need separate testing.
- VPN isolation, SnapCore user snapshots, Guardian, graphical recovery and the independent Recovery Environment are not Pre-Alpha promises unless separately verified.
- Pre-Alpha means defects and incomplete non-core features are expected. Back up important data and use a disposable VM until broader hardware and recovery qualification is complete.

## Verification status

- The current conventional single-root ISO remains an internal installer and SDDM validation image; it does not yet contain the complete Pre-Alpha dual-environment system.
- Current `vpkg` uses the configured APK repositories or imperative Nix profile commands when explicitly selected. Automatic Alpine → Veyra APK → Nix fallback and integration into the user environment remain to be implemented; `vpkg` will not expose system-root routing.
- The current updater performs in-place APK upgrades, and the A/B prototype requires manual activation. Those paths do not satisfy the Pre-Alpha update gate.
- Before publication, integrate signed paired updates, pass a clean graphical install and SDDM login, then prove successful update confirmation and forced-failure rollback in QEMU.
- Publish the exact tested ISO with checksums, source and package manifests, update instructions and its matching source tag. Never include private signing keys or credentials.
