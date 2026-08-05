#!/usr/bin/env bash
set -euo pipefail

# Native Windows QEMU, that variant. Uses WHPX instead of KVM and virtio-gpu-gl for real 3D accel
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../local" && pwd)"
DISK="$SCRIPT_DIR/nixos-disk.qcow2"
ISO="$(ls "$SCRIPT_DIR"/nixos-minimal-*-x86_64-linux.iso 2>/dev/null | head -n1)"
QEMU="$(command -v qemu-system-x86_64.exe || command -v qemu-system-x86_64 || echo "/c/Program Files/qemu/qemu-system-x86_64.exe")"
FW_CODE="$(dirname "$QEMU")/share/edk2-x86_64-code.fd"
FW_VARS="$SCRIPT_DIR/edk2-x86_64-vars.fd"

if [ ! -f "$DISK" ]; then
  qemu-img create -f qcow2 "$DISK" 30G
fi

if [ -z "$ISO" ]; then
  echo "No nixos-minimal-*-x86_64-linux.iso found in $SCRIPT_DIR" >&2
  exit 1
fi

if [ ! -f "$FW_CODE" ]; then
  echo "No UEFI firmware found at $FW_CODE — hosts/laptop-vm needs" >&2
  echo "boot.loader.systemd-boot, which requires UEFI, not BIOS." >&2
  exit 1
fi

if [ ! -f "$FW_VARS" ]; then
  truncate -s "$(stat -c%s "$FW_CODE")" "$FW_VARS"
fi

"$QEMU" \
  -accel whpx,kernel-irqchip=off \
  -m 8192 -smp 4 \
  -machine q35,smm=off \
  -cpu qemu64 \
  -drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
  -drive if=pflash,format=raw,file="$FW_VARS" \
  -vga none -device virtio-vga-gl \
  -display sdl,gl=on \
  -drive file="$DISK",if=none,id=disk0 \
  -device virtio-blk-pci,drive=disk0,bootindex=1 \
  -drive file="$ISO",if=none,id=cdrom0,media=cdrom,readonly=on \
  -device ide-cd,drive=cdrom0,bootindex=2 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net,netdev=net0 \
  -usb -device usb-tablet
