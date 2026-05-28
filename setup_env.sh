#!/bin/bash
# ============================================================
# 环境准备脚本
# 挂载 eMMC 分区、安装依赖等
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  eMMC 测试环境准备"
echo "========================================"

# 1. 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] 需要 root 权限执行"
  exit 1
fi

# 2. 安装依赖
echo ""
echo "--- 安装依赖 ---"
apt-get update -qq
apt-get install -y -qq fio hdparm smartmontools util-linux python3 mmc-utils 2>/dev/null
echo "  依赖安装完成"

# 3. 检查 eMMC 设备
echo ""
echo "--- 检查 eMMC 设备 ---"
if [ -b "$EMMC_DEV" ]; then
  echo "  [OK] 设备 $EMMC_DEV 存在"
  lsblk "$EMMC_DEV"
else
  echo "  [WARN] 设备 $EMMC_DEV 不存在"
  echo "  可用设备:"
  lsblk -d -o NAME,SIZE,TYPE,TRAN 2>/dev/null | head -20
fi

# 4. 挂载文件系统
echo ""
echo "--- 挂载文件系统 ---"
if [ ! -d "$MOUNT_POINT" ]; then
  mkdir -p "$MOUNT_POINT"
fi

if mountpoint -q "$MOUNT_POINT"; then
  echo "  [OK] $MOUNT_POINT 已挂载:"
  df -h "$MOUNT_POINT" | tail -1
else
  if [ -b "$EMMC_PART" ]; then
    # 检查分区是否有文件系统
    FSTYPE=$(blkid -o value -s TYPE "$EMMC_PART" 2>/dev/null || echo "")
    if [ -n "$FSTYPE" ]; then
      mount "$EMMC_PART" "$MOUNT_POINT"
      echo "  [OK] $EMMC_PART ($FSTYPE) 已挂载到 $MOUNT_POINT"
    else
      echo "  [WARN] $EMMC_PART 无文件系统，如需测试请先格式化:"
      echo "    mkfs.ext4 $EMMC_PART"
      echo "    mount $EMMC_PART $MOUNT_POINT"
    fi
  else
    echo "  [WARN] 分区 $EMMC_PART 不存在"
    echo "  eMMC 分区表:"
    fdisk -l "$EMMC_DEV" 2>/dev/null | grep "^$EMMC_DEV" || lsblk "$EMMC_DEV"
  fi
fi

# 5. 检查 IO 调度器
echo ""
echo "--- IO 调度器 ---"
DEV_NAME=$(basename "$EMMC_DEV")
SCHED_PATH="/sys/block/${DEV_NAME}/queue/scheduler"
if [ -f "$SCHED_PATH" ]; then
  echo "  当前调度器: $(cat $SCHED_PATH)"
  # eMMC 推荐使用 mq-deadline 或 none
  echo "  建议: echo mq-deadline > $SCHED_PATH"
fi

# 6. 检查 UFS/eMMC 控制器
echo ""
echo "--- eMMC 控制器信息 ---"
for ctrl in /sys/devices/platform/*/mmc_host/mmc*/mmc*; do
  if [ -d "$ctrl" ]; then
    echo "  $(basename $ctrl):"
    cat "$ctrl/date" 2>/dev/null && echo -n "  " && echo "厂商: $(cat $ctrl/manfid 2>/dev/null)"
    echo -n "  名称: $(cat $ctrl/name 2>/dev/null)"
    echo " 时序: $(cat $ctrl/timing_spec 2>/dev/null)"
    echo -n "  转速: $(cat $ctrl/ocr 2>/dev/null)"
  fi
done 2>/dev/null || echo "  (无法读取 eMMC 控制器信息)"

echo ""
echo "环境准备完成!"
echo "现在可以运行: ./run_all.sh quick"
