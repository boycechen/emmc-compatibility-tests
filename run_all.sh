#!/bin/bash
# ============================================================
# eMMC Compatibility Test Suite - 主运行脚本
# Rock 5B + Linux 6.1.43 + fio
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

banner() {
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║        eMMC Compatibility Test Suite                 ║"
  echo "║        Rock 5B · Linux 6.1.43 · fio                  ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""
  echo "设备: $EMMC_DEV"
  echo "挂载点: $MOUNT_POINT"
  echo "结果目录: $RESULT_DIR"
  echo ""
}

usage() {
  echo "用法: $0 [选项] [测试类型...]"
  echo ""
  echo "测试类型:"
  echo "  常规性能:"
  echo "    sequential   - 顺序读写测试"
  echo "    random       - 随机读写测试"
  echo "    mixed        - 混合读写测试"
  echo "    latency      - 延迟测试"
  echo "    stress       - 压力测试"
  echo "    steady       - 稳定态测试 (耗时长)"
  echo "    bs_scan      - 块大小扫描"
  echo "    qd_scan      - 队列深度扫描"
  echo ""
echo "  深层问题定位 (FTL/NAND/Controller):"
echo "    ftl_gc              - FTL垃圾回收+延迟尖峰检测"
echo "    write_amp           - 写入放大测试"
echo "    read_disturb        - 读干扰测试"
echo "    data_integrity      - 数据完整性校验"
echo "    slc_cache           - SLC缓存耗尽+性能悬崖"
echo "    contention          - 多线程竞态(读挨饿/死锁)"
echo "    erratic_io          - 不规则IO模式(触发固件bug)"
echo "    thermal             - 热降频+老化模拟"
echo "    boundary            - 擦除块/页边界测试"
echo "    pattern_sensitivity - NAND数据pattern敏感性"
echo "    lba_remap           - LBA映射表压力(FTL缓存thrashing)"
echo ""
echo "  eMMC固件特性专项:"
echo "    cache_fsync         - 写入缓存 + fsync压力"
echo "    timing_mode         - HS400/HS200时序稳定性"
echo "    sanitize            - Sanitize安全擦除测试"
echo "    power_mgmt          - Sleep/Wake + 挂起恢复"
echo ""
echo "  长时稳定专项:"
echo "    longhaul            - 长时间浸泡测试(6h+固件资源泄漏)"
echo ""
echo "  底层硬件/控制器/subsystem:"
echo "    boot_partition      - Boot分区SLC模式可靠性"
echo "    fua_barrier         - FUA/barrier缓存旁路语义"
echo "    dma_boundary        - DMA地址边界跨越(控制器对齐)"
echo "    multi_partition     - 多分区并发访问(分区切换上下文)"
echo "    hw_reset            - HW Reset复位稳定性(映射表重建)"
echo ""
echo "  eMMC 5.x 规范特性:"
echo "    spec_compliance     - 5.x规范特性校验(EXT_CSD寄存器)"
echo "    cmdq_stress         - CMDQ命令队列调度压力"
echo "    bkops_monitor       - BKOPS后台操作监测+延迟影响"
echo ""
echo "  快捷方式:"
echo "    quick        - 快速验证 (顺序+随机+混合)"
echo "    profiling    - 性能画像 (顺序+随机+bs_scan+qd_scan)"
echo "    deep         - FTL/NAND深度问题排查"
echo "    integrity    - 数据完整性专项"
echo "    firmware     - 固件特性专项 (cache+timing+sanitize+power)"
echo "    soak         - 稳定专项 (longhaul+lba_remap)"
echo "    hw           - 底层硬件 (boot分区/FUA/DMA边界/多分区/复位)
    spec         - eMMC 5.x 规范特性 (spec/cmdq/bkops)"
  echo ""
  echo "选项:"
  echo "  --device DEV   指定 eMMC 设备 (默认: $EMMC_DEV)"
  echo "  --mount DIR    指定挂载点 (默认: $MOUNT_POINT)"
  echo "  --part PART    指定分区 (默认: $EMMC_PART)"
  echo "  --runtime N    测试运行时间(秒) (默认: $RUNTIME)"
  echo "  --reset        每项测试前执行 blkdiscard 复位设备（默认跳过）"
  echo "  --dry-run      只打印要执行的命令，不实际执行"
  echo ""
  echo "示例:"
  echo "  $0 all                          # 运行所有测试"
  echo "  $0 sequential random mixed       # 运行指定测试"
  echo "  $0 quick --runtime 30           # 快速验证，每项30秒"
  echo "  $0 --device /dev/mmcblk1 all    # 测试另一块emmc"
  echo ""
}

# --- 解析参数 ---
TESTS=()
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    all) TESTS+=("sequential" "random" "mixed" "stress" "latency" "steady" "trim" "fill" "bs_scan" "qd_scan" "ftl_gc" "write_amp" "read_disturb" "data_integrity" "slc_cache" "contention" "erratic_io" "thermal" "boundary" "cache_fsync" "timing_mode" "sanitize" "power_mgmt" "pattern_sensitivity" "longhaul" "lba_remap" "boot_partition" "fua_barrier" "dma_boundary" "multi_partition" "hw_reset" "spec_compliance" "cmdq_stress" "bkops_monitor") ;;
    quick) TESTS+=("sequential" "random" "mixed") ;;
    profiling) TESTS+=("sequential" "random" "bs_scan" "qd_scan") ;;
    deep) TESTS+=("ftl_gc" "write_amp" "read_disturb" "data_integrity" "slc_cache" "contention" "erratic_io" "thermal" "boundary" "pattern_sensitivity" "lba_remap") ;;
    integrity) TESTS+=("data_integrity" "read_disturb" "trim") ;;
    firmware) TESTS+=("cache_fsync" "timing_mode" "sanitize" "power_mgmt") ;;
    soak) TESTS+=("longhaul" "lba_remap") ;;
    hw) TESTS+=("boot_partition" "fua_barrier" "dma_boundary" "multi_partition" "hw_reset") ;;
    spec) TESTS+=("spec_compliance" "cmdq_stress" "bkops_monitor") ;;
    sequential|random|mixed|stress|latency|steady|trim|fill|bs_scan|qd_scan|ftl_gc|write_amp|read_disturb|data_integrity|slc_cache|contention|erratic_io|thermal|boundary|cache_fsync|timing_mode|sanitize|power_mgmt|pattern_sensitivity|longhaul|lba_remap|boot_partition|fua_barrier|dma_boundary|multi_partition|hw_reset|spec_compliance|cmdq_stress|bkops_monitor)
      TESTS+=("$1") ;;
    --device) EMMC_DEV="$2"; shift ;;
    --mount) MOUNT_POINT="$2"; shift ;;
    --part) EMMC_PART="$2"; shift ;;
    --runtime) RUNTIME="$2"; shift ;;
    --reset) export SKIP_RESET=0 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] 未知选项: $1"; usage; exit 1 ;;
  esac
  shift
done

if [ ${#TESTS[@]} -eq 0 ]; then
  usage
  exit 1
fi

# 如果未指定设备, 交互选择
if [ -z "$EMMC_DEV" ]; then
  select_device
fi

# --- 主流程 ---
banner
check_deps

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[DRY RUN] 将执行以下脚本:"
  for t in "${TESTS[@]}"; do
    echo "  → tests/${t}.sh"
  done
  exit 0
fi

prepare_env

init_test_table

START_TIME=$(date +%s)

echo ""
echo "开始时间: $(date)"
echo ""

PASS=0
FAIL=0
FAILED_TESTS=()

for t in "${TESTS[@]}"; do
  script="${SCRIPT_DIR}/tests/${t}.sh"

  if [ ! -f "$script" ]; then
    echo -e "${YELLOW}[SKIP]${NC} 找不到脚本: tests/${t}.sh"
    continue
  fi

  TEST_START=$(date +%s)
  echo -e "${GREEN}[RUN]${NC} 测试: ${t}"
  echo "──────────────────────────────────────────"

  if bash "$script"; then
    STATUS="PASS"
    PASS=$((PASS + 1))
  else
    STATUS="FAIL"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$t")
  fi

  TEST_END=$(date +%s)
  TEST_DURATION=$((TEST_END - TEST_START))
  if [ $TEST_DURATION -ge 60 ]; then
    DUR_STR="$((TEST_DURATION / 60))m$((TEST_DURATION % 60))s"
  else
    DUR_STR="${TEST_DURATION}s"
  fi

  add_table_row "$t" "$STATUS" "$DUR_STR"

  echo ""
done

close_test_table

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# --- 汇总 ---
echo ""
echo "========================================"
echo "  测试完成汇总"
echo "========================================"
echo "  通过: $PASS"
echo "  失败: $FAIL"
echo "  耗时: $((DURATION / 60))分$((DURATION % 60))秒"
echo "  结果目录: $(readlink -f $RESULT_DIR)"
echo ""

if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  echo "  失败项: ${FAILED_TESTS[*]}"
fi

if [ -f "${RESULT_DIR}/summary.txt" ]; then
  echo ""
  echo "=== 性能摘要 ==="
  cat "${RESULT_DIR}/summary.txt"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}所有测试通过!${NC}"
else
  echo -e "${RED}部分测试失败，请检查日志${NC}"
  exit 1
fi
