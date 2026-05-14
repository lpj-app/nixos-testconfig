# Setting Up a Persistent NixOS Virtual Machine with QEMU

Currently, your VM is running in **Live Mode**. This means the entire system is loaded into the virtual RAM. Any changes you make, files you save, or settings you change will be permanently lost as soon as you close the QEMU window.

The reason the NixOS installer is requesting 10 GB or more of space is that it is looking for a physical (or virtual) hard drive to install the OS onto. Since you haven't provided a virtual disk yet, it has nowhere to go.

Follow these three steps to create a persistent installation.

---

## Step 1: Create a Virtual Hard Drive

Before starting the VM, you need to create a file that acts as a virtual hard drive. We use the `qemu-img` tool for this.

Run the following command in your terminal:

```bash
qemu-img create -f qcow2 nixos-disk.qcow2 30G
```

### Explanation of Parameters:
* **`qcow2`**: This is the "QEMU Copy-On-Write" format. It is thin-provisioned, meaning that even though we specify 30 GB, the file will initially only take up a few kilobytes on your real SSD/HDD. It grows dynamically as you add data to the VM.
* **`30G`**: We recommend at least 30 GB for NixOS. Since NixOS keeps older versions of your system configuration (generations), it requires more "breathing room" than other distributions.

---

## Step 2: Start the VM for Installation

Now, start QEMU and "plug in" both the virtual Live-CD (your ISO) and your newly created, empty virtual hard drive.

```bash
qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 -vga virtio \
-drive file=nixos-disk.qcow2,format=qcow2 \
-cdrom nixos-graphical-25.11.10134.26ef669cffa9-x86_64-linux.iso \
-boot d
```

### Explanation of Parameters:
* **`-drive file=nixos-disk.qcow2,format=qcow2`**: Connects your virtual hard drive.
* **`-boot d`**: Forces QEMU to boot from the "CD-ROM" (the ISO) first, so you can enter the installer.
* **`-enable-kvm`**: Enables hardware acceleration (essential for performance).
* **`-vga virtio`**: Provides a modern virtual GPU for better graphical performance.

**Action:** Once NixOS boots up, open the graphical installer and follow the instructions. It will now detect the 30 GB drive and allow you to install the system.

---

## Step 3: Daily Use (Persistent Mode)

Once the installation is complete and you have shut down the VM, you no longer need the ISO file. From now on, you only boot from your virtual hard drive:

```bash
qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 -vga virtio -drive file=nixos-disk.qcow2,format=qcow2
```

Start with ssh portforwarding 2222:22
```bash
qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 -vga virtio \
          -drive file=nixos-disk.qcow2,format=qcow2 \
          -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0
```

Note that we removed `-cdrom` and `-boot d`. QEMU will now boot directly into your installed NixOS system, and **all your changes will be saved**.
