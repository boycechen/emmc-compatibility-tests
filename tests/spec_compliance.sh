#!/bin/bash
# ============================================================
# eMMC 5.x 规范特性校验 (Spec Compliance)
#
# 读取 EXT_CSD 寄存器, 验证 eMMC 5.0/5.1 声称支持的特性
# 在实际工作中是否正常。核心思路:
#   spec 说支持 → 实际测试 → 比对结果
#
# 检查项:
#   - 设备规范版本 (EXT_CSD[192] EXT_CSD_REV)
#   - CMDQ 支持 (DEVICE_SUPPORT_2[6]: bit 0)
#   - Cache Barrier (DEVICE_SUPPORT_2[6]: bit 4)
#   - BKOPS 支持 (BKOPS_SUPPORT[502]: bit 0)
#   - Enhanced Strobe (DEVICE_SUPPORT_2[6]: bit 1)
#   - Data Tag (DEVICE_SUPPORT_2[6]: bit 2)
#   - Secure features
#   - 健康状态: PRE_EOL_INFO[262], LIFE_TIME_EST[268-269]
#   - 时序模式可达性 (HS_TIMING[185])
#   - 实际读写验证是否能达到 spec 声称的性能基线
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  eMMC 5.x 规范特性校验"
echo "========================================"

RESULTS=()
FAIL_COUNT=0
WARN_COUNT=0
WARNINGS=()

DEV_SIZE=$(blockdev --getsize64 "$EMMC_DEV")
DEV_NAME=$(basename "$EMMC_DEV")

# ---------- 读取 EXT_CSD ----------
EXT_CSD=$(mmc extcsd read "$EMMC_DEV" 2>/dev/null) || {
  echo "[FAIL] 无法读取 EXT_CSD, 需要 mmc-utils"
  append_summary "规范校验" "FAIL-无EXT_CSD"
  exit 1
}

echo ""
echo "--- 基本识别 ---"

get_extcsd_field() {
  local pos=$1
  echo "$EXT_CSD" | grep "\[$pos\]" | awk '{print $NF}'
}

# 规范版本
EXT_CSD_REV=$(get_extcsd_field 192)
echo "  EXT_CSD_REV[192]  = $EXT_CSD_REV"
SPEC_VER="unknown"
if [ "$EXT_CSD_REV" = "7" ]; then SPEC_VER="5.1"
elif [ "$EXT_CSD_REV" = "6" ]; then SPEC_VER="5.0"
elif [ "$EXT_CSD_REV" = "5" ]; then SPEC_VER="4.5"
fi
echo "  eMMC 规范版本: $SPEC_VER"

# 设备类型
DEV_TYPE=$(get_extcsd_field 0)
echo "  DEVICE_TYPE[0]   = $DEV_TYPE"

# ---------- 特性寄存器 DECHECK ----------
echo ""
echo "--- 特性支持声明验证 ---"

# CMDQ: DEVICE_SUPPORT_2[6] bit 0
DS2=$(get_extcsd_field 6)
CMDQ_EN=$(( (DS2 >> 0) & 1 ))
BARRIER_EN=$(( (DS2 >> 4) & 1 ))
STROBE_EN=$(( (DS2 >> 1) & 1 ))
TAG_EN=$(( (DS2 >> 2) & 1 ))
echo "  DEVICE_SUPPORT_2[6] = $DS2 (bin: $(echo "obase=2; $DS2" | bc 2>/dev/null || echo $DS2))"
echo "    CMDQ:         $([ $CMDQ_EN -eq 1 ] && echo '支持(5.1)' || echo '不支持')"
echo "    Enhanced Strobe: $([ $STROBE_EN -eq 1 ] && echo '支持(5.0)' || echo '不支持')"
echo "    Data Tag:     $([ $TAG_EN -eq 1 ] && echo '支持(5.0)' || echo '不支持')"
echo "    Cache Barrier:$([ $BARRIER_EN -eq 1 ] && echo '支持(5.1)' || echo '不支持')"

# BKOPS 支持
BKOPS_SUP=$(get_extcsd_field 502)
echo "  BKOPS_SUPPORT[502] = $BKOPS_SUP $([ $BKOPS_SUP -eq 1 ] && echo '(支持)' || echo '(不支持)')"

# Secure 能力
SECURE_FEATURES=$(get_extcsd_field 231)
echo "  SECURE_FEATURE[231] = $SECURE_FEATURES"
echo "    Erase:        $([ $((SECURE_FEATURES & 1)) -eq 1 ] && echo '支持' || echo '不支持')"
echo "    Trim:         $([ $(( (SECURE_FEATURES >> 1) & 1 )) -eq 1 ] && echo '支持' || echo '不支持')"
echo "    Sanitize:     $([ $(( (SECURE_FEATURES >> 2) & 1 )) -eq 1 ] && echo '支持' || echo '不支持')"

# FFU
FFU_STATUS=$(get_extcsd_field 213)
echo "  FFU_STATUS[213] = $FFU_STATUS"

# HS_TIMING 能力
HS_TIMING=$(get_extcsd_field 185)
echo "  HS_TIMING[185] = $HS_TIMING"
echo "    Legacy:       $([ $(((HS_TIMING >> 0) & 1)) -eq 1 ] && echo '支持' || echo '不支持')"
echo "    HS:           $([ $(((HS_TIMING >> 1) & 1)) -eq 1 ] && echo '支持' || echo '不支持')"
echo "    HS200:        $([ $(((HS_TIMING >> 2) & 1)) -eq 1 ] && echo '支持' || echo '不支持')"
echo "    HS400:        $([ $(((HS_TIMING >> 3) & 1)) -eq 1 ] && echo '支持' || echo '不支持')"

# ---------- 健康状态 ----------
echo ""
echo "--- 设备健康 ---"
PRE_EOL=$(get_extcsd_field 262)
LIFE_A=$(get_extcsd_field 268)
LIFE_B=$(get_extcsd_field 269)
echo "  PRE_EOL_INFO[262]     = $PRE_EOL"
echo "    $(case $PRE_EOL in
          0) echo '正常' ;;
          1) echo 'WARN: 消耗20%-80%' ;;
          2) echo 'WARN: 消耗>80% (预留)' ;;
          3) echo 'WARN: 到寿, EOL!' ;;
          *) echo '未知' ;;
        esac)"
echo "  LIFE_TIME_EST_TYP_A[268] = $LIFE_A"
echo "  LIFE_TIME_EST_TYP_B[269] = $LIFE_B"

# ---------- 特性功能验证 ----------
echo ""
echo "--- 特性功能验证 ---"

# 1) CMDQ 验证: 检查 sysfs
if [ $CMDQ_EN -eq 1 ]; then
  echo -n "  CMDQ sysfs 接口... "
  CMDQ_SYSFS="/sys/block/${DEV_NAME}/device/mmc_cmdq"
  if [ -d "$CMDQ_SYSFS" ]; then
    echo "存在 ($CMDQ_SYSFS)"
  else
    echo "不存在(spec声称支持, 但内核未暴露接口)"
    WARN_COUNT=$((WARN_COUNT + 1))
    WARNINGS+=("CMDQ spec 声称支持但内核未暴露")
  fi
fi

# 2) Cache Barrier 验证: 读取 Cache Control
echo -n "  Cache Barrier 可用性... "
if [ $BARRIER_EN -eq 1 ] && [ $CMDQ_EN -eq 1 ]; then
  echo "BARRIER_EN=$BARRIER_EN (CMDQ 使能时支持)"
else
  echo "不支持 (BARRIER_EN=$BARRIER_EN, CMDQ=$CMDQ_EN)"
fi

# 3) Cache 大小
CACHE_SIZE=$(get_extcsd_field 251)
echo "  Cache Size[251-252]  = $CACHE_SIZE KB"

# 4) Max Enhanced Area
ENH_AREAS=$(get_extcsd_field 156)
echo "  ENH_SIZE_MULT[156-158] = $ENH_AREAS"

# 5) Trim/Erase 参数
TRIM_TIMEOUT=$(get_extcsd_field 230)
ERASE_TIMEOUT=$(get_extcsd_field 229)
SEC_TRIM=$(get_extcsd_field 228)
echo "  Trim 超时 = ${TRIM_TIMEOUT}ms"
echo "  Erase 超时 = ${ERASE_TIMEOUT}ms"
echo "  SEC_TRIM_MULT = $SEC_TRIM"

# ---------- 功能验证: 声明 vs 实际能力 ----------
echo ""
echo "--- 声明 vs 实际能力验证 ---"

# HS400 验证: 实际测速确认时序模式可达
if [ $(( (HS_TIMING >> 3) & 1 )) -eq 1 ]; then
  echo -n "  HS400 性能基线验证... "
  BW=0
  fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=1m --size=256M \
      --iodepth=8 --ioengine=libaio --name=spec_hs400 \
      --output="${RESULT_DIR}/spec_hs400.json" --output-format=json \
      2>/dev/null
  BW=$(fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=1m --size=256M \
      --iodepth=8 --ioengine=libaio --name=spec_hs400 \
      --output-format=json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    bw=d.get('jobs',[{}])[0].get('read',{}).get('bw_mean',0)
    print(bw)
except: print(0)
" 2>/dev/null || echo 0)
  BW_MB=$((BW / 1024))
  echo "${BW_MB} MB/s"
  if [ $BW_MB -gt 0 ] && [ $BW_MB -lt 40 ]; then
    echo "    [WARN] HS400 声称支持但只测到 ${BW_MB}MB/s, 可能实际工作在 HS200"
    WARN_COUNT=$((WARN_COUNT + 1))
    WARNINGS+=("HS400 声称支持但性能仅 ${BW_MB}MB/s")
  fi
fi

# ---------- 寄存器值一致性检查 ----------
echo ""
echo "--- 寄存器一致性 ---"

RELIABLE_WRITE=$(get_extcsd_field 222)
PARTITION_CONFIG=$(get_extcsd_field 179)
BOOT_SIZE_MULT=$(get_extcsd_field 226)
BOOT_INFO=$(get_extcsd_field 228)
echo "  RELIABLE_WRITE[222] = $RELIABLE_WRITE"
echo "  PARTITION_CONFIG[179] = $PARTITION_CONFIG"
echo "  BOOT_SIZE_MULT[226] = $BOOT_SIZE_MULT"
BOOT_SZ=$((BOOT_SIZE_MULT * 128 * 1024))
echo "    → Boot分区大小 ≈ $(numfmt --to=iec $BOOT_SZ)"

DEVICE_BUS_WIDTH=$(cat /sys/block/${DEV_NAME}/device/mmc_bus_width 2>/dev/null || echo "unknown")
echo "  MMC总线宽度: $DEVICE_BUS_WIDTH"

echo ""
echo "====== eMMC 5.x 规范校验结果 ======"
echo "  版本: $SPEC_VER"
echo "  CMDQ:   $([ $CMDQ_EN -eq 1 ] && echo '✔' || echo '✘')"
echo "  Strobe: $([ $STROBE_EN -eq 1 ] && echo '✔' || echo '✘')"
echo "  Barrier:$([ $BARRIER_EN -eq 1 ] && echo '✔' || echo '✘')"
echo "  BKOPS:  $([ $BKOPS_SUP -eq 1 ] && echo '✔' || echo '✘')"
echo "  Tag:    $([ $TAG_EN -eq 1 ] && echo '✔' || echo '✘')"

if [ $WARN_COUNT -gt 0 ]; then
  echo "  [WARN] ${WARN_COUNT} 个不一致项:"
  for w in "${WARNINGS[@]}"; do echo "    - $w"; done
fi

append_summary "规范校验" "版本:${SPEC_VER} 警告:${WARN_COUNT}"
