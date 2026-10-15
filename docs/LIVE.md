# Veyra Live

Veyra uses Alpine's **diskless** boot mode by default: the writable system root runs in RAM and is restored afresh on reboot. A live desktop is available without installation.

The built image includes KDE Plasma 6 with a Wayland session, SDDM, PipeWire, common utilities and the Nix package manager. The ephemeral account `veyra` is created by the `veyra-live` OpenRC boot service; SDDM automatically starts the Wayland session using `plasma.desktop`.

## Memory and media

The live root filesystem is a RAM-backed tmpfs. **The ISO is not fully ejectable while the system is running**: the kernel module loop image (modloop) and the offline APK repository remain on the original media. Full copy-to-RAM boot is a separate feature and is not implemented yet.

KDE live images need substantially more memory than the earlier console image. Allow **at least 8 GiB RAM** for the current RAM-backed KDE installer, since the entire system is expanded into memory. Current CI boots it with 6 GiB and checks for space exhaustion.

## Virtual machine

For graphical testing:

```sh
qemu-system-x86_64 -m 4096 -smp 4 -vga virtio -display gtk \
  -cdrom dist/veyra-linux-*.iso -boot d
```

Use `-display vnc=:1` in headless environments and connect a VNC viewer on the host. CI boots the live ISO to a serial login prompt, then installs Plasma and the console-only profile on separate blank QEMU disks and verifies that both installed systems boot. The automated install drives the same distribution scripts Calamares calls; it does not click through the Calamares GUI.

## Installing

The live image build pipeline compiles and bundles a native Qt6 Calamares package with Veyra's installation configuration. Plasma and console-only disk installations have passed the automated QEMU install and reboot tests. The installer remains experimental: the Calamares GUI flow and physical hardware are not covered by those tests. Only test it using disposable blank virtual disks.
