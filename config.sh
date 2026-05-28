#!/bin/bash
# ============================================================
# eMMC Compatibility Test - 通用配置
# ============================================================

# --- 设备配置 ---
# eMMC 设备路径（裸设备测试用）
EMMC_DEV=""
# eMMC 分区（若测试特定分区）
EMMC_PART=""
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

# --- 交互式设备选择 ---
select_device() {
  if [ -n "$EMMC_DEV" ] && [ -b "$EMMC_DEV" ]; then
    return 0
  fi

  EMMC_DEV=""
  local candidates=()
  local types=()

  for dev in /sys/block/*; do
    local name=$(basename "$dev")
    local devpath="/dev/$name"
    [ -b "$devpath" ] || continue

    # 跳过分区和 loop/ram/zram
    [ -f "$dev/partition" ] && continue
    [[ "$name" = loop* ]] && continue
    [[ "$name" = ram* ]] && continue
    [[ "$name" = zram* ]] && continue

    local size=$(blockdev --getsize64 "$devpath" 2>/dev/null)
    [ -n "$size" ] && [ "$size" -gt 0 ] || continue

    # 跳过只读设备 (如无盘 CD-ROM)
    local ro=$(cat "$dev/ro" 2>/dev/null || echo 0)
    [ "$ro" = "0" ] || continue
    local model=""
    local type_label=""

    if [ -f "$dev/device/type" ]; then
      local dtype
      read -r dtype < "$dev/device/type"
      case "$dtype" in
        MMC) type_label="eMMC"
          model=$(cat "$dev/device/name" 2>/dev/null || echo "")
          local manf=$(cat "$dev/device/manfid" 2>/dev/null || echo "")
          [ -n "$manf" ] && model="${model} (manf:${manf})" ;;
        SD) type_label="SD"
          model=$(cat "$dev/device/name" 2>/dev/null || echo "SD") ;;
        *)
          if [ -f "$dev/device/vendor" ]; then
            local vendor=$(cat "$dev/device/vendor" 2>/dev/null | tr -d ' ')
            local model_id=$(cat "$dev/device/model" 2>/dev/null | tr -d ' ')
            model="${vendor} ${model_id}"
            type_label="SCSI/NVMe"
          fi
          ;;
      esac
    elif [ -f "$dev/device/vendor" ]; then
      local vendor=$(cat "$dev/device/vendor" 2>/dev/null | tr -d ' ')
      local model_id=$(cat "$dev/device/model" 2>/dev/null | tr -d ' ')
      model="${vendor} ${model_id}"
      type_label="SCSI/NVMe"
    elif [ -d "$dev/device/interface" ]; then
      type_label="USB"
      model=$(cat "$dev/device/model" 2>/dev/null || echo "USB Mass Storage")
    fi

    [ -z "$type_label" ] && continue

    local size_iec=$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}")
    candidates+=("$devpath:$size:$size_iec:$model:$type_label")
    types+=("$type_label")
  done

  if [ ${#candidates[@]} -eq 0 ]; then
    echo "[ERROR] 未找到任何块设备"
    return 1
  fi

  # 按类型排序: eMMC 优先
  local emmc_list=()
  local other_list=()
  for c in "${candidates[@]}"; do
    if echo "$c" | grep -q ":eMMC"; then
      emmc_list+=("$c")
    else
      other_list+=("$c")
    fi
  done
  candidates=("${emmc_list[@]}" "${other_list[@]}")

  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  选择测试设备                                        ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""

  PS3="请输入序号选择设备 (q 退出): "
  select opt in "${candidates[@]}"; do
    if [ -n "$opt" ]; then
      EMMC_DEV=$(echo "$opt" | cut -d: -f1)
      local size=$(echo "$opt" | cut -d: -f3)
      local model=$(echo "$opt" | cut -d: -f4)
      local dev_type=$(echo "$opt" | cut -d: -f5)
      echo ""
      echo "  已选择: $EMMC_DEV"
      echo "  类型:   $dev_type"
      echo "  容量:   $size"
      [ -n "$model" ] && echo "  型号:   $model"
      echo ""
      break
    elif [ "$REPLY" = "q" ]; then
      echo "  退出"
      exit 0
    fi
  done
}

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
  # 如果 EMMC_PART 未设置, 从 EMMC_DEV 推导
  if [ -z "$EMMC_PART" ]; then
    local dev_name=$(basename "$EMMC_DEV")
    for part in /dev/${dev_name}p*; do
      if [ -b "$part" ]; then
        EMMC_PART="$part"
        break
      fi
    done
    [ -z "$EMMC_PART" ] && EMMC_PART="${EMMC_DEV}p1"
  fi
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

# --- 测试结果表格 ---
INIT_TABLE_DONE=0

init_test_table() {
  [ "$INIT_TABLE_DONE" -eq 1 ] && return
  INIT_TABLE_DONE=1
  printf "" > "${RESULT_DIR}/table_data.txt"
  echo ""
  echo "  ┌──────────────────────────┬────────┬────────┬──────────────────────────┐"
  echo "  │ 测试项目                 │ 状态   │ 耗时   │ 关键指标                 │"
  echo "  ├──────────────────────────┼────────┼────────┼──────────────────────────┤"
}

add_table_row() {
  local name="$1"
  local status="$2"
  local duration="$3"
  local result="${4:-}"

  if [ -z "$result" ]; then
    result=$(tail -2 "${RESULT_DIR}/summary.txt" 2>/dev/null | head -1 || echo "")
  fi

  local color=""
  [ "$status" = "PASS" ] && color="\033[0;32m"
  [ "$status" = "FAIL" ] && color="\033[0;31m"

  printf "  │ %-24s │ ${color}%-6s\033[0m │ %-6s │ %-24s │\n" \
    "${name:0:24}" "$status" "${duration}" "${result:0:24}"
  echo "$name|$status|$duration|$result" >> "${RESULT_DIR}/table_data.txt"
}

close_test_table() {
  echo "  └──────────────────────────┴────────┴────────┴──────────────────────────┘"
  echo ""
}

print_full_table() {
  [ ! -f "${RESULT_DIR}/table_data.txt" ] && return
  echo ""
  echo "  ┌──────────────────────────┬────────┬────────┬──────────────────────────┐"
  echo "  │ 测试项目                 │ 状态   │ 耗时   │ 关键指标                 │"
  echo "  ├──────────────────────────┼────────┼────────┼──────────────────────────┤"
  while IFS='|' read -r name status duration result; do
    [ -z "$name" ] && continue
    if [ "$status" = "PASS" ]; then
      printf "  │ %-24s │ \033[0;32m%-6s\033[0m │ %-6s │ %-24s │\n" "${name:0:24}" "$status" "$duration" "${result:0:24}"
    else
      printf "  │ %-24s │ \033[0;31m%-6s\033[0m │ %-6s │ %-24s │\n" "${name:0:24}" "$status" "$duration" "${result:0:24}"
    fi
  done < "${RESULT_DIR}/table_data.txt"
  echo "  └──────────────────────────┴────────┴────────┴──────────────────────────┘"
  echo ""
}
