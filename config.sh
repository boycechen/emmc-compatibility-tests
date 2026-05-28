#!/bin/bash
# ============================================================
# eMMC Compatibility Test - 通用配置
# ============================================================

# --- 设备配置 ---
# eMMC 设备路径（裸设备测试用）
EMMC_DEV="/dev/mmcblk0"
# eMMC 分区（若测试特定分区）
EMMC_PART="/dev/mmcblk0p4"
# 挂载点（文件系统测试用）
MOUNT_POINT="/mnt/emmc_test"

# --- 测试参数 ---
# 测试文件大小（占可用空间的百分比或绝对值）
TEST_SIZE="90%"
# 运行时间（秒）
RUNTIME=60
# 默认队列深度
IODEPTH=1
# 默认块大小
BS="4k"
# 默认并发数
NUMJOBS=1
# 预热时间（秒）
RAMP_TIME=10
# 测试目录（结果存放）
RESULT_DIR="results"
# 日志目录
LOG_DIR="${RESULT_DIR}/logs"

# --- 工具检查 ---
check_deps() {
  local deps=("fio" "blkdiscard" "hdparm" "smartctl" "lsblk" "mmc")
  local missing=()
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      missing+=("$dep")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[WARN] 缺少工具: ${missing[*]}"
    echo "       请执行: apt-get install -y fio hdparm smartmontools util-linux mmc-utils"
  fi
}

# --- 环境准备 ---
prepare_env() {
  mkdir -p "$RESULT_DIR" "$LOG_DIR"
  # 如果是裸设备测试，先记录设备信息
  if [ -b "$EMMC_DEV" ]; then
    echo "=== 设备信息 ===" | tee "${RESULT_DIR}/device_info.txt"
    lsblk "$EMMC_DEV" | tee -a "${RESULT_DIR}/device_info.txt"
    hdparm -I "$EMMC_DEV" 2>/dev/null | tee -a "${RESULT_DIR}/device_info.txt" || true
    cat /sys/block/$(basename $EMMC_DEV)/queue/scheduler 2>/dev/null | tee -a "${RESULT_DIR}/device_info.txt" || true
  fi
}

# --- 通用 fio 参数 ---
FIO_COMMON="--output-format=json --write_lat_log=${LOG_DIR}/lat_log"

# --- 结果解析辅助 ---
parse_fio_result() {
  local json_file=$1
  local label=$2
  if [ -f "$json_file" ]; then
    local read_iops=$(python3 -c "import json; d=json.load(open('$json_file')); print(d.get('jobs',[{}])[0].get('read',{}).get('iops','N/A'))" 2>/dev/null || echo "N/A")
    local write_iops=$(python3 -c "import json; d=json.load(open('$json_file')); print(d.get('jobs',[{}])[0].get('write',{}).get('iops','N/A'))" 2>/dev/null || echo "N/A")
    local read_bw=$(python3 -c "import json; d=json.load(open('$json_file')); bw=d.get('jobs',[{}])[0].get('read',{}).get('bw','N/A'); print(f'{bw}KB/s' if bw!='N/A' else 'N/A')" 2>/dev/null || echo "N/A")
    local write_bw=$(python3 -c "import json; d=json.load(open('$json_file')); bw=d.get('jobs',[{}])[0].get('write',{}).get('bw','N/A'); print(f'{bw}KB/s' if bw!='N/A' else 'N/A')" 2>/dev/null || echo "N/A")
    echo "$label: Read=${read_bw} IOPS=${read_iops} | Write=${write_bw} IOPS=${write_iops}"
  fi
}

# --- 设备复位（blkdiscard 到干净状态）---
# 设置 SKIP_RESET=0 以在每项测试前执行 blkdiscard
# 可通过环境变量 SKIP_RESET=0 覆盖（如 run_all.sh --reset）
SKIP_RESET="${SKIP_RESET:-1}"

reset_device() {
  [ "$SKIP_RESET" = "1" ] && return
  if ! command -v blkdiscard &>/dev/null; then
    echo "  [WARN] blkdiscard 不可用，跳过设备复位"
    return
  fi
  local dev_name=$(basename "$EMMC_DEV")
  local gran=$(cat /sys/block/${dev_name}/queue/discard_granularity 2>/dev/null)
  if [ -z "$gran" ] || [ "$gran" -eq 0 ]; then
    echo "  [WARN] $EMMC_DEV 不支持 discard，跳过复位"
    return
  fi
  echo "  [RESET] blkdiscard $EMMC_DEV ..."
  blkdiscard "$EMMC_DEV" 2>/dev/null && echo "  [RESET] 完成" || echo "  [RESET] 失败（设备忙或不支持）"
  sleep 1
}

# --- 破坏性操作警告 ---
warn_destructive() {
  local test_name=$1
  echo ""
  echo "  ╔══════════════════════════════════════════════════╗"
  echo "  ║  [WARN] $test_name" | head -c 56
  printf "║\n"
  echo "  ║  使用 $EMMC_DEV (整块设备)" | head -c 56
  printf "║\n"
  echo "  ║  分区表和数据将被覆盖!" | head -c 56
  printf "║\n"
  echo "  ║  Press Ctrl+C within 3s to abort..." | head -c 56
  printf "║\n"
  echo "  ╚══════════════════════════════════════════════════╝"
  echo ""
  sleep 3
}

# --- 输出到汇总表 ---
append_summary() {
  local title=$1
  shift
  echo "==========================================" >> "${RESULT_DIR}/summary.txt"
  echo "[$title]" >> "${RESULT_DIR}/summary.txt"
  echo "$@" >> "${RESULT_DIR}/summary.txt"
  echo "" >> "${RESULT_DIR}/summary.txt"
}
