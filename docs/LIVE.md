# Veyra Live

Veyra uses Alpine's **diskless** boot mode by default: the writable system root runs in RAM and is restored afresh on reboot. A live desktop is available without installation.

The built image includes KDE Plasma 6 with a Wayland session, SDDM, PipeWire, common utilities and the Nix package manager. The ephemeral account `veyra` is created by the `veyra-live` OpenRC boot service; SDDM automatically starts the Wayland session using `plasma.desktop`.

The temporary live account has no password, and both `sudo` and Polkit administrator actions work without one. The live root exists only in memory and its changes are discarded at reboot. The installer removes the live privilege rules before preparing the installed system; choose a password for the regular account in Calamares.

The live image uses compressed zram swap and software rendering in Firefox to reduce memory and virtual GPU failures. Plasma is configured without desktop compositing in the live session, and a small session watchdog restarts `plasmashell` if it exits. These are live-session compatibility measures; they do not replace testing the VM or physical hardware.

## Memory and media

The live root filesystem is a RAM-backed tmpfs. **The ISO is not fully ejectable while the system is running**: the kernel module loop image (modloop) and the offline APK repository remain on the original media. Full copy-to-RAM boot is a separate feature and is not implemented yet.

KDE live images need substantially more memory than the earlier console image. **8 GiB RAM is recommended.** The image now enables compressed swap to make smaller VM allocations more tolerant, but performance depends on the host and browser workload.

## Virtual machine

For graphical testing:

```sh
qemu-system-x86_64 -m 4096 -smp 4 -vga virtio -display gtk \
  -cdrom dist/veyra-linux-*.iso -boot d
```

Use `-display vnc=:1` in headless environments and connect a VNC viewer on the host. CI boots the live ISO to a serial login prompt, then installs all five desktop choices on blank BIOS QEMU disks and also tests Plasma and the console-only profile with UEFI. The automated install drives the same distribution scripts Calamares calls; it does not click through the Calamares GUI.

## Installing

The live image build pipeline compiles and bundles a native Qt6 Calamares package with Veyra's installation configuration. The QEMU tests cover the installation scripts and first boot on disposable blank virtual disks. The installer remains experimental: the Calamares GUI flow and physical hardware are not covered by those tests.
