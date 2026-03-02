#!/bin/bash
set -euo pipefail

# 安装组件
# update-grub
# apt install grub2-common -y


BACKUP_IMG="/media/kali/6c5da18c-4f5b-4171-a917-9016a2974d9f/debian_ext4/mydebian.img.gz"  # 使用绝对路径
TARGET_DISK="/dev/sda"
SWAP_UUID="3167e6ed-55ed-4af7-9ea0-225fa814f114"


FSTAB_ADD="UUID=${SWAP_UUID} none swap sw 0 0"
GRUB_LINE="GRUB_CMDLINE_LINUX_DEFAULT=\"quiet resume=UUID=${SWAP_UUID}\""
TARGET_EFI="${TARGET_DISK}1"
TARGET_ROOT="${TARGET_DISK}2"
TARGET_HOME="${TARGET_DISK}3"
MOUNT_POINT="/mnt/restore_root"

if [[ $EUID -ne 0 ]]; then
  echo "请以 root 身份运行该脚本。"
  exit 1
fi

apt install grub2-common -y
# 检查是否安装 dosfstools
if command -v mkfs.vfat > /dev/null 2>&1; then
    echo "dosfstools 已安装"
else
    echo "未检测到 dosfstools，正在安装..."
    apt install dosfstools -y  > /dev/null 2>&1
fi

if [ ! -f "$BACKUP_IMG" ]; then
  echo "错误：备份文件 $BACKUP_IMG 不存在！"
  exit 1
fi

echo "当前磁盘分区如下："
lsblk "$TARGET_DISK"
echo "请再次确认分区信息无误。"

echo "注意：你正在将 $BACKUP_IMG 恢复到 $TARGET_DISK"
read -rp "请确认你已分好 EFI/系统/Home 分区，并继续操作？(yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "已取消。"
  exit 1
fi

echo "检查目标分区是否存在..."
for part in "$TARGET_ROOT" "$TARGET_EFI" "$TARGET_HOME"; do
  if [ ! -b "$part" ]; then
    echo "错误：分区 $part 不存在！"
    exit 1
  fi
done

echo "格式化目标分区..."
umount "$TARGET_EFI" 2>/dev/null || true
mkfs.vfat -F 32 $TARGET_EFI  > /dev/null 2>&1
umount "$TARGET_ROOT" 2>/dev/null || true
mkfs.ext4 -F $TARGET_ROOT  > /dev/null 2>&1

echo "[1/7] 解压并写入系统分区到 $TARGET_ROOT..."
gunzip -c "$BACKUP_IMG" | dd of="$TARGET_ROOT" iflag=fullblock bs=4M status=progress oflag=direct || {
  echo "解压失败！";
  exit 1;
}
sync  > /dev/null 2>&1
partprobe "$TARGET_DISK"  > /dev/null 2>&1
sleep 2 > /dev/null 2>&1


echo "[2/7] 挂载恢复分区..."
mkdir -p "$MOUNT_POINT"
mount "$TARGET_ROOT" "$MOUNT_POINT"

echo "已恢复 HOME 分区..."
mv "$MOUNT_POINT/home" "$MOUNT_POINT/home_bak"

mkdir -p "$MOUNT_POINT/mnt/home_root"
mount "$TARGET_HOME" "$MOUNT_POINT/mnt/home_root"

mkdir -p "$MOUNT_POINT/mnt/home_root/debian"
mkdir -p "$MOUNT_POINT/home"
mount --bind "$MOUNT_POINT/mnt/home_root/debian" "$MOUNT_POINT/home"

# 首次恢复覆盖
# mv "$MOUNT_POINT/home_bak"/* "$MOUNT_POINT/home"/ 2>/dev/null || true
rm -rf "$MOUNT_POINT/home_bak"


echo "[3/7] 挂载必要系统目录..."
mount --bind /dev "$MOUNT_POINT/dev"
mount --bind /proc "$MOUNT_POINT/proc"
mount --bind /sys "$MOUNT_POINT/sys"
mkdir -p "$MOUNT_POINT/run"
mount --bind /run "$MOUNT_POINT/run"


echo "[4/7] 挂载 EFI 分区"
mkdir -p "$MOUNT_POINT/boot/efi"
mount "$TARGET_EFI" "$MOUNT_POINT/boot/efi"


echo "[5/7] chroot 进入系统，安装 GRUB 并修复引导..."
chroot "$MOUNT_POINT" /bin/bash -c "
if [ -d /sys/firmware/efi ]; then
  # 系统为 UEFI 模式，安装 EFI GRUB
  mountpoint -q /sys/firmware/efi/efivars || mount -t efivarfs efivarfs /sys/firmware/efi/efivars
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck  > /dev/null 2>&1
else
  # 当前似乎是 BIOS 启动，尝试安装 legacy GRUB
  grub-install $TARGET_DISK  > /dev/null 2>&1
fi

# 禁用 os-prober 自动检测其他系统启动项 # 修改或追加 GRUB_DISABLE_OS_PROBER=true
if grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
  sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=true/' /etc/default/grub
else
  echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
fi

echo '更新 /etc/default/grub 开启休眠'
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|${GRUB_LINE}|' '/etc/default/grub'
echo '更新 initramfs...'
update-initramfs -u -k all  > /dev/null 2>&1
echo '更新 grub 配置...'
update-grub  > /dev/null 2>&1
" || {
  echo "chroot 或 GRUB 安装失败！"
  exit 1
}


echo "[6/7] 更新 fstab UUID..."
# 获取分区 UUID
UUID_ROOT=$(blkid -s UUID -o value "$TARGET_ROOT")
UUID_EFI=$(blkid -s UUID -o value "$TARGET_EFI")
UUID_HOME=$(blkid -s UUID -o value "$TARGET_HOME")
# 写入新的 fstab
cat <<EOF > "$MOUNT_POINT/etc/fstab"
UUID=$UUID_ROOT / ext4 errors=remount-ro 0 1
UUID=$UUID_EFI /boot/efi vfat umask=0077 0 1
UUID=$UUID_HOME /mnt/home_root ext4 defaults 0 1
/mnt/home_root/debian /home none bind 0 0
$FSTAB_ADD
EOF


echo "[7/7] 清理挂载..."
umount "$MOUNT_POINT/boot/efi" 2>/dev/null || true
umount "$MOUNT_POINT/home" 2>/dev/null || true
umount "$MOUNT_POINT/sys" 2>/dev/null || true
umount "$MOUNT_POINT/proc" 2>/dev/null || true
umount "$MOUNT_POINT/dev" 2>/dev/null || true
umount "$MOUNT_POINT/run" 2>/dev/null || true
umount "$MOUNT_POINT" 2>/dev/null || true
umount -l "$MOUNT_POINT" 2>/dev/null || true


echo "恢复和扩展分区容量..."
e2fsck -f $TARGET_ROOT
resize2fs $TARGET_ROOT

echo "[系统恢复和引导修复完成] ！你可以尝试从 $TARGET_DISK 启动。"
echo "提醒：若原系统盘仍接入，可能影响启动顺序，请考虑断开原盘再启动新盘。"
echo "."


