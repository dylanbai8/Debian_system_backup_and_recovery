# Debian_system_backup_and_recovery
debian 系统备份和恢复

系统备份
```
sudo dd if=/dev/sda2 bs=4M status=progress | gzip > /media/kali/6c5da18c-4f5b-4171-a917-9016a2974d9f/debian_ext4/mydebian.img.gz
sudo dd if=/dev/sda2 bs=4M status=progress | gzip -9 > /media/kali/6c5da18c-4f5b-4171-a917-9016a2974d9f/debian_ext4/mydebian.img.gz
```

系统恢复
```
sudo ./debian.sh
```
首次恢复时，取消第90行注释。

