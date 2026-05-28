#!/bin/bash
# ============================================================
# 擦除块/页边界测试 (Erase Block Boundary)
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  擦除块/页边界测试 (Boundary)"
echo "========================================"
reset_device

RESULTS=()

echo ""
echo "--- eMMC 物理参数 ---"
DEV_NAME=$(basename "$EMMC_DEV")
BLOCK_SIZE=$(cat /sys/block/${DEV_NAME}/queue/physical_block_size 2>/dev/null || echo "512")
LOGICAL_BLOCK=$(cat /sys/block/${DEV_NAME}/queue/logical_block_size 2>/dev/null || echo "512")
MIN_IO=$(cat /sys/block/${DEV_NAME}/queue/minimum_io_size 2>/dev/null || echo "512")
OPT_IO=$(cat /sys/block/${DEV_NAME}/queue/optimal_io_size 2>/dev/null || echo "0")
ERASE_SIZE=$(cat /sys/block/${DEV_NAME}/queue/discard_granularity 2>/dev/null || echo "?")

echo "  物理块大小: ${BLOCK_SIZE} bytes"
echo "  逻辑块大小: ${LOGICAL_BLOCK} bytes"
echo "  最小IO大小: ${MIN_IO} bytes"
echo "  TRIM粒度: ${ERASE_SIZE} bytes"
echo ""

echo "--- 跨页边界测试 ---"
echo "  测试在不同页边界处的读写行为..."
echo "  (每个offset只在第一次出现时测试)"

PAGE_SIZES=(16384 32768 65536)
ERASE_BLOCKS=(2097152 4194304 8388608)
declare -A SEEN_OFFSETS

for page in "${PAGE_SIZES[@]}"; do
  for eb in "${ERASE_BLOCKS[@]}"; do
    for offset in $page $((page - 512)) $((page + 512)) $eb $((eb - 4096)) $((eb + 4096)); do
      [ $offset -lt 0 ] && continue
      # 跳过已测offset
      [ -n "${SEEN_OFFSETS[$offset]}" ] && continue
      SEEN_OFFSETS[$offset]=1

      echo -n "  offset=${offset} (page=${page} eb=${eb}) ... "
      fio --filename="$EMMC_DEV" \
          --direct=1 \
          --rw=write \
          --bs=4096 \
          --size=4096 \
          --offset=$offset \
          --iodepth=1 \
          --ioengine=libaio \
          --name=bndry_w_off${offset} \
          --output=/dev/null \
          --verify=crc32c \
          --verify_pattern=0xdeadbeef \
          --verify_state_save=0 2>/dev/null || true

      rc=0
      fio --filename="$EMMC_DEV" \
          --direct=1 \
          --rw=read \
          --bs=4096 \
          --size=4096 \
          --offset=$offset \
          --iodepth=1 \
          --ioengine=libaio \
          --name=bndry_r_off${offset} \
          --output=/dev/null \
          --verify=crc32c \
          --verify_pattern=0xdeadbeef \
          --verify_state_save=0 \
          --verify_fatal=1 2>/dev/null || rc=$?

      if [ $rc -eq 0 ]; then
        echo "OK"
      else
        echo "校验失败!"
        RESULTS+=("FAIL: offset=${offset}")
      fi
    done
  done
done

echo ""
echo "--- 跨擦除块连续写测试 ---"
echo "  在多擦除块上连续写并校验..."

eb_size=4194304
test_size=$((eb_size * 3))

fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=write \
    --bs=16k \
    --size=$test_size \
    --offset=0 \
    --iodepth=8 \
    --ioengine=libaio \
    --name=bndry_cross_eb \
    --output=/dev/null \
    --verify=crc32c \
    --verify_pattern=0xdeadbeef \
    --verify_state_save=0 2>/dev/null || true

rc=0
fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=read \
    --bs=16k \
    --size=$test_size \
    --offset=0 \
    --iodepth=8 \
    --ioengine=libaio \
    --name=bndry_cross_eb_verify \
    --output="${RESULT_DIR}/boundary_cross_eb.json" \
    --output-format=json \
    --verify=crc32c \
    --verify_pattern=0xdeadbeef \
    --verify_state_save=0 \
    --verify_fatal=1 2>/dev/null || rc=$?

if [ $rc -eq 0 ]; then
  echo "  [PASS] 跨3个擦除块写+校验通过"
else
  echo "  [FAIL] 跨擦除块数据不一致!"
fi

echo ""
echo "--- 边界/跨页数据完整性测试 (fio verify) ---"
echo "  原理: 每个测试用例 写→立即校验(同块大小), 互不影响"
echo ""

PP_BASE=3145728
FAIL_PP=0

# ----- 测试1: 不同块大小在页边界偏移处写+校验 -----
echo "  测试1: 512B~4K 在页边界附近写入+校验"
for delta in 0 512 1024 2048 3072 3584 4096; do
  for bs in 512 1024 2048 4096; do
    off=$((PP_BASE + delta))
    rc=0
    fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=$bs --size=$bs \
        --offset=$off --iodepth=1 --ioengine=libaio --name=pp_w_${bs}_${delta} \
        --output=/dev/null \
        --verify=crc32c --verify_pattern=0xdeadbeef --verify_state_save=0 \
        2>/dev/null || true
    fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=$bs --size=$bs \
        --offset=$off --iodepth=1 --ioengine=libaio --name=pp_r_${bs}_${delta} \
        --output=/dev/null \
        --verify=crc32c --verify_pattern=0xdeadbeef --verify_state_save=0 --verify_fatal=1 \
        2>/dev/null || rc=$?
    if [ $rc -ne 0 ]; then
      echo "    [FAIL] bs=$bs offset=$off"
      FAIL_PP=1
    fi
  done
done
echo "    [DONE]"

# ----- 测试2: 同一 LBA 反复覆盖, 每次写后立即校验 -----
echo "  测试2: 同一 LBA 反复覆盖(512→1K→2K→4K→8K), 每次写后校验"
OVERLAP_OFF=$((PP_BASE + 65536))
for bs in 512 1024 2048 4096 8192; do
  rc=0
  fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=$bs --size=$bs \
      --offset=$OVERLAP_OFF --iodepth=1 --ioengine=libaio --name=pp_ov_w_${bs} \
      --output=/dev/null \
      --verify=crc32c --verify_pattern=0xdeadbeef --verify_state_save=0 \
      2>/dev/null || true
  fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=$bs --size=$bs \
      --offset=$OVERLAP_OFF --iodepth=1 --ioengine=libaio --name=pp_ov_r_${bs} \
      --output=/dev/null \
      --verify=crc32c --verify_pattern=0xdeadbeef --verify_state_save=0 --verify_fatal=1 \
      2>/dev/null || rc=$?
  if [ $rc -ne 0 ]; then
    echo "    [FAIL] 重复覆盖 bs=$bs"
    FAIL_PP=1
  fi
done
echo "    [DONE]"

# ----- 测试3: 跨 16KB 边界写入 -----
echo "  测试3: 跨 16KB/NAND页边界写入"
BOUND=$((PP_BASE + 16 * 1048576))
for bs in 512 1024 2048 4096; do
  for adj in -256 0 256; do
    off=$((BOUND + adj))
    [ $off -le 0 ] && continue
    rc=0
    fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=$bs --size=$bs \
        --offset=$off --iodepth=1 --ioengine=libaio --name=pp_bd_w_${bs}_${adj} \
        --output=/dev/null \
        --verify=crc32c --verify_pattern=0xdeadbeef --verify_state_save=0 \
        2>/dev/null || true
    fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=$bs --size=$bs \
        --offset=$off --iodepth=1 --ioengine=libaio --name=pp_bd_r_${bs}_${adj} \
        --output=/dev/null \
        --verify=crc32c --verify_pattern=0xdeadbeef --verify_state_save=0 --verify_fatal=1 \
        2>/dev/null || rc=$?
    if [ $rc -ne 0 ]; then
      echo "    [FAIL] 跨页 bs=$bs offset=$off"
      FAIL_PP=1
    fi
  done
done
echo "    [DONE]"

if [ $FAIL_PP -eq 0 ]; then
  echo "  [PASS] 页边界/反复覆盖数据完整性通过"
else
  echo "  [FAIL] 数据完整性检查失败!"
  RESULTS+=("FAIL: page boundary / overwrite data integrity")
fi

echo ""
echo "====== 边界测试结果 ======"
if [ ${#RESULTS[@]} -eq 0 ]; then
  echo "  [PASS] 所有边界测试通过"
else
  echo "  [FAIL] 以下边界测试失败:"
  for r in "${RESULTS[@]}"; do
    echo "    $r"
  done
fi
append_summary "边界测试" "$([ ${#RESULTS[@]} -eq 0 ] && echo PASS || echo "FAIL: ${#RESULTS[@]} errors")"
