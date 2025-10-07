#!/bin/bash
set -euo pipefail

# ----------- CONFIG -----------
IMAGE_NAME="rocky-tinkerboard3n.img"
IMAGE_SIZE_MB=4096
BOOT_SIZE_MB=256

# Rocky Linux 9 Container Base (aarch64)
ROCKY_ROOTFS_URL="https://dl.rockylinux.org/pub/rocky/9.5/images/aarch64/Rocky-9-Container-Base.latest.aarch64.tar.xz"

# Official ASUS Tinker Board 3N Debian 11 (kernel 5.10) Armbian image
ARMBIAN_IMG_URL="https://dlcdnets.asus.com/pub/ASUS/Embedded_IPC/Tinker%20Board%203N/Tinker_Board_3N-Debian-Bullseye-v1.0.31-20241024-release.zip?model=Tinker%20Board%203N"

WORK_DIR="$PWD/tinkerboard3n"
ROCKY_ROOTFS_DIR="$WORK_DIR/rocky-rootfs"
FIRSTBOOT_DIR="$PWD/firstboot"
ARMBIAN_IMG_ZIP="$(basename "$ARMBIAN_IMG_URL")"
ARMBIAN_IMG="$WORK_DIR/armbian.img"

# Mountpoints (temporary)
MNT_TARGET_BOOT="/mnt/rocky-boot"
MNT_TARGET_ROOT="/mnt/rocky-root"
MNT_ARMBIAN_BOOT="/mnt/armbian-boot"
MNT_ARMBIAN_ROOT="/mnt/armbian-root"
# ------------------------------

echo "📦 Preparing workspace..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" \
         "$MNT_TARGET_BOOT" "$MNT_TARGET_ROOT" \
         "$MNT_ARMBIAN_BOOT" "$MNT_ARMBIAN_ROOT" \
         "$ROCKY_ROOTFS_DIR"

cd "$WORK_DIR"

# ---------------- ROCKY ROOTFS ----------------
ROOTFS_TAR="$(basename "$ROCKY_ROOTFS_URL")"
if [ -f "$ROOTFS_TAR" ]; then
  echo "📦 Rocky rootfs TAR already exists, skipping download: $ROOTFS_TAR"
else
  echo "📥 Downloading Rocky Linux 9 rootfs..."
  curl -L -o "$ROOTFS_TAR" "$ROCKY_ROOTFS_URL"
fi

echo "📂 Extracting Rocky rootfs to $ROCKY_ROOTFS_DIR..."
file "$ROOTFS_TAR" | grep -q 'XZ compressed data' || { echo "❌ Rocky rootfs archive is invalid."; exit 1; }
tar -xf "$ROOTFS_TAR" -C "$ROCKY_ROOTFS_DIR"

# ---------------- ARMBIAN IMAGE ----------------
if [ -f "$ARMBIAN_IMG_ZIP" ]; then
  echo "📁 Armbian ZIP already present, skipping download: $ARMBIAN_IMG_ZIP"
else
  echo "📥 Downloading ASUS Tinker Board 3N Armbian ZIP..."
  curl -L -o "$ARMBIAN_IMG_ZIP" "$ARMBIAN_IMG_URL"
fi

if [ -f "$ARMBIAN_IMG" ]; then
  echo "📁 Armbian IMG already exists, skipping unzip: $ARMBIAN_IMG"
else
  echo "📁 Unzipping Armbian image..."
  unzip -o "$ARMBIAN_IMG_ZIP"
  FOUND_IMG="$(find . -maxdepth 1 -type f -iname "*.img" | head -n1)"
  [ -n "$FOUND_IMG" ] || { echo "❌ Could not find extracted *.img"; exit 1; }
  mv "$FOUND_IMG" "$(basename "$ARMBIAN_IMG")"
fi

# ---------------- VERIFY FIRSTBOOT FILES ----------------
echo "📋 Verifying firstboot files..."
[ -f "$FIRSTBOOT_DIR/firstboot.sh" ] \
  || { echo "❌ missing $FIRSTBOOT_DIR/firstboot.sh"; exit 1; }
[ -f "$FIRSTBOOT_DIR/firstboot.service" ] \
  || { echo "❌ missing $FIRSTBOOT_DIR/firstboot.service"; exit 1; }

# ---------------- CLEAN OLD LOOPS & MAPPINGS ----------------
echo "🧼 Ensuring clean loop state for any old images..."
# Detach any loop device that was previously used for $IMAGE_NAME
for LOOPDEV in $(losetup -a | grep "$IMAGE_NAME" | cut -d: -f1); do
  echo "⚠️  Detaching stale loop: $LOOPDEV"
  # Remove device‐mapper mappings first
  for MAP in $(kpartx -l "$LOOPDEV" 2>/dev/null | awk '{print $1}'); do
    if [ -e "/dev/mapper/$MAP" ]; then
      dmsetup remove "/dev/mapper/$MAP" || true
    fi
  done
  losetup -d "$LOOPDEV" || true
done

# ---------------- CREATE NEW TARGET IMAGE ----------------
echo "💽 Creating blank $IMAGE_NAME (${IMAGE_SIZE_MB} MB)…"
dd if=/dev/zero of="$IMAGE_NAME" bs=1M count="$IMAGE_SIZE_MB" status=progress

echo "📐 Partitioning $IMAGE_NAME (256 MB FAT32 + rest ext4)…"
parted -s "$IMAGE_NAME" mklabel msdos
parted -s "$IMAGE_NAME" mkpart primary fat32 1MiB "${BOOT_SIZE_MB}MiB"
parted -s "$IMAGE_NAME" mkpart primary ext4 "${BOOT_SIZE_MB}MiB" 100%

echo "🔧 Setting up loop+device‐mapper for new image…"
ROCKY_LOOP=$(losetup --find --show "$IMAGE_NAME")
kpartx -av "$ROCKY_LOOP" || true
udevadm settle; sleep 1

MAPPER_LOOP_NAME=$(basename "$ROCKY_LOOP")
TARGET_BOOT_DEV="/dev/mapper/${MAPPER_LOOP_NAME}p1"
TARGET_ROOT_DEV="/dev/mapper/${MAPPER_LOOP_NAME}p2"

echo "🧼 Formatting target image partitions…"
mkfs.vfat -F32 "$TARGET_BOOT_DEV"
mkfs.ext4 "$TARGET_ROOT_DEV"

echo "📁 Mounting target image partitions…"
mount "$TARGET_BOOT_DEV" "$MNT_TARGET_BOOT"
mount "$TARGET_ROOT_DEV" "$MNT_TARGET_ROOT"

# ---------------- MOUNT ARMBIAN IMAGE ----------------
echo "🔧 Setting up loop+device‐mapper for Armbian image…"
ARMBIAN_LOOP=$(losetup --find --show "$ARMBIAN_IMG")
kpartx -av "$ARMBIAN_LOOP" || true
udevadm settle; sleep 1

# Find and mount only the ext4 “root” partition from Armbian
echo "🔍 Detecting Armbian ext4 root partition..."
ARM_ROOT_DEV=""
for DEV in /dev/mapper/$(basename "$ARMBIAN_LOOP")p*; do
  if blkid -o value -s TYPE "$DEV" 2>/dev/null | grep -q '^ext4$'; then
    ARM_ROOT_DEV="$DEV"
    break
  fi
done
[ -n "$ARM_ROOT_DEV" ] || { echo "❌ No ext4 partition found in Armbian image"; exit 1; }
echo "✅ Using Armbian root=$ARM_ROOT_DEV"
mount "$ARM_ROOT_DEV" "$MNT_ARMBIAN_ROOT" || { echo "❌ Failed to mount Armbian root"; exit 1; }

# Now detect partition 1 of Armbian (usually contains /boot or kernel files)
ARM_BOOT_DEV="/dev/mapper/$(basename "$ARMBIAN_LOOP")p1"
echo "🔍 Mounting Armbian boot partition ($ARM_BOOT_DEV) (let kernel auto‐detect FS)..."
mount "$ARM_BOOT_DEV" "$MNT_ARMBIAN_BOOT" \
  || { echo "❌ Failed to mount Armbian boot"; exit 1; }

# ---------------- POPULATE TARGET: BOOT ----------------
echo "📁 Copying /boot from Armbian → target boot partition…"
rsync -a "$MNT_ARMBIAN_BOOT"/boot/ "$MNT_TARGET_BOOT"/ \
  || { echo "❌ Failed to rsync Armbian /boot"; exit 1; }

# Unmount Armbian /boot now that we've copied it
umount -l "$MNT_ARMBIAN_BOOT" || true

# ---------------- POPULATE TARGET: ROOT ----------------
echo "📁 Copying Rocky rootfs → target root partition…"
rsync -a "$ROCKY_ROOTFS_DIR"/ "$MNT_TARGET_ROOT"/

echo "📁 Copying Armbian kernel modules → target root/lib/modules…"
mkdir -p "$MNT_TARGET_ROOT/lib/modules"
rsync -a "$MNT_ARMBIAN_ROOT/lib/modules"/ "$MNT_TARGET_ROOT/lib/modules"/

# ---------------- INJECT firstboot ----------------
echo "📁 Injecting firstboot provisioning files…"
# Copy firstboot.sh into /root/
cp "$FIRSTBOOT_DIR/firstboot.sh" "$MNT_TARGET_ROOT/root/firstboot.sh"
chmod +x "$MNT_TARGET_ROOT/root/firstboot.sh"

# Place firstboot.service under /etc/systemd/system/ and enable it
INSTALL_UNIT_DIR="$MNT_TARGET_ROOT/etc/systemd/system"
mkdir -p "$INSTALL_UNIT_DIR/multi-user.target.wants"
cp "$FIRSTBOOT_DIR/firstboot.service" "$INSTALL_UNIT_DIR/firstboot.service"
ln -sf "../firstboot.service" \
  "$INSTALL_UNIT_DIR/multi-user.target.wants/firstboot.service"

# Sanity check
[ -f "$MNT_TARGET_ROOT/root/firstboot.sh" ] \
  || { echo "❌ firstboot.sh not found in target"; exit 1; }
[ -f "$INSTALL_UNIT_DIR/firstboot.service" ] \
  || { echo "❌ firstboot.service not found in target"; exit 1; }

# ---------------- FINAL CONFIG INSIDE TARGET ----------------
# echo "🔐 Setting root’s password to 'rocky' (inside chroot)…"
# chroot "$MNT_TARGET_ROOT" /bin/bash -c "echo 'root:rocky' | chpasswd"

# echo "📡 Enabling sshd in the new image…"
# chroot "$MNT_TARGET_ROOT" /bin/bash -c "systemctl enable sshd || true"

# ---------------- CLEANUP ALL MOUNTS & LOOPS ----------------
echo "🧹 Cleaning up…"

# Unmount Armbian root
umount -l "$MNT_ARMBIAN_ROOT"   || true
kpartx -d "$ARMBIAN_LOOP"       || true
losetup -d "$ARMBIAN_LOOP"      || true

# Unmount target image partitions
umount -l "$MNT_TARGET_BOOT"    || true
umount -l "$MNT_TARGET_ROOT"    || true
kpartx -d "$ROCKY_LOOP"         || true
losetup -d "$ROCKY_LOOP"        || true

# Remove empty mount directories (optional)
rmdir "$MNT_TARGET_BOOT" 2>/dev/null || true
rmdir "$MNT_TARGET_ROOT" 2>/dev/null || true
rmdir "$MNT_ARMBIAN_BOOT" 2>/dev/null || true
rmdir "$MNT_ARMBIAN_ROOT" 2>/dev/null || true

echo "✅ Image built successfully: $IMAGE_NAME"
echo
echo "💡 To flash:  
    sudo dd if=$IMAGE_NAME of=/dev/sdX bs=4M status=progress && sync  
Replace /dev/sdX with your microSD device node."
