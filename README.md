# eMMC 兼容性测试套件

Rock 5B 平台 · Linux 6.1.43 · fio

## 快速开始

```bash
# 1. 环境准备
sudo ./setup_env.sh

# 2. 快速验证（~5分钟）
sudo ./run_all.sh quick

# 3. FTL/NAND 深度排查（~1小时）
sudo ./run_all.sh deep

# 4. 全量测试
sudo ./run_all.sh all

# 5. 分析结果
./analyze.sh
```

## 测试架构

```
常规性能测试 ──→ 顺序/随机/混合/延迟/压力
    │
画像扫描测试 ──→ 块大小扫描/队列深度扫描
    │
FTL内部测试 ──→ GC压力/写放大/SLC缓存/竞态
    │
NAND物理测试 ──→ 读干扰/边界对齐/数据完整性
    │
稳定性测试 ──→ 热降频/稳定态/不规则IO
```

## 测试项目详解

### 常规性能

| 测试 | 脚本 | 说明 |
|------|------|------|
| 顺序读写 | `tests/sequential.sh` | 128K~4M连续IO，测吞吐 |
| 随机读写 | `tests/random.sh` | 4K~64K随机IO，变队列深度 |
| 混合读写 | `tests/mixed.sh` | 30%/50%/70%/90% 四种读写比 |
| 延迟测试 | `tests/latency.sh` | QD=1下 P50/P99/P99.9/P99.99 |
| 压力测试 | `tests/stress.sh` | 高并发+多Job+延迟分位 |

### 画像扫描

| 测试 | 脚本 | 说明 |
|------|------|------|
| 块大小扫描 | `tests/bs_scan.sh` | 512B~8M 共15种尺寸遍历 |
| 队列深度扫描 | `tests/qd_scan.sh` | QD=1~128 + 多Job并发 |

### 定位 FTL 问题

| 测试 | 脚本 | 检测目标 |
|------|------|---------|
| **GC压力** | `tests/ftl_gc_stress.sh` | GC延迟尖峰频率和幅度，100ms粒度监测5分钟 |
| **写放大** | `tests/write_amplification.sh` | FTL内部写放大因子，不同模式对比推算 |
| **SLC缓存** | `tests/slc_cache.sh` | SLC缓存大小、拐点位置、TLC直写速度 |
| **多线程竞态** | `tests/multithread_contention.sh` | 读挨饿、写挨饿、32线程死锁检测 |

### 定位 NAND/Controller 问题

| 测试 | 脚本 | 检测目标 |
|------|------|---------|
| **读干扰** | `tests/read_disturb.sh` | 50万次读干扰后数据是否损坏 |
| **数据完整性** | `tests/data_integrity.sh` | 多pattern校验、跨EB边界、延迟读取 |
| **边界对齐** | `tests/erase_block_boundary.sh` | 跨page/block边界IO、partial page program |
| **不规则IO** | `tests/erratic_io.sh` | 非标块大小、混合engine、sync风暴 |
| **热降频** | `tests/thermal_throttle.sh` | 温升监测、throttle事件检测、恢复验证 |

## 用法

```bash
# 快速验证
sudo ./run_all.sh quick

# 性能画像（理解eMMC特性）
sudo ./run_all.sh profiling

# FTL/NAND深度排查
sudo ./run_all.sh deep

# 数据完整性专项
sudo ./run_all.sh integrity

# 单项测试
sudo ./run_all.sh ftl_gc slc_cache contention

# 指定设备+参数
sudo ./run_all.sh --device /dev/mmcblk1 --runtime 30 deep

# 干运行
sudo ./run_all.sh --dry-run all
```

## 问题诊断速查

| 症状 | 应运行测试 | 可能原因 |
|------|-----------|---------|
| 写入一段时间后变慢 | `slc_cache` `ftl_gc` `thermal` | SLC填满/GC触发热降频 |
| IO延迟忽高忽低 | `ftl_gc` `latency` `steady_state` | GC尖峰/控制器调度 |
| 多任务时读卡顿 | `contention` `stress` | 读挨饿/固件优先级问题 |
| 文件损坏/数据丢失 | `data_integrity` `read_disturb` `boundary` | NAND比特翻转/映射错误 |
| 特定场景下hang死 | `erratic_io` `contention` | 固件在特定IO组合下死锁 |
| 全盘快写满时极慢 | `fill` `slc_cache` `write_amp` | GC工作量大/写放大过高 |

## 输出目录

```
results/
├── summary.txt           # 性能摘要
├── device_info.txt       # 设备信息
├── logs/                 # 时序日志(IOPS/BW/延迟)
│   ├── gc_lat*.log       # GC延迟时序
│   ├── thermal_bw.log    # 热降频带宽时序
│   └── steady_*.log      # 稳定态日志
├── gc_round*.json        # GC各轮结果
├── starvation_*.json     # 竞态测试
├── thermal_*.json        # 热测试
├── intel_*.json          # 完整性校验
└── report_*.md           # 可读报告
```

## 注意事项

- **需要 root 权限**：裸设备测试需要直接访问块设备
- **数据安全**：测试会覆写 eMMC 数据，确保已备份重要文件
- **散热**：长时间测试可能导致 eMMC 过热降速，建议加散热片
- **寿命**：全盘填充和稳定态测试会产生较多写入，注意写入量
- **`serialize_overlap=1`**：如果用 `numjobs > 1` 配合 `--verify` 做并发写+校验，必须加 `--serialize_overlap=1`，否则多 job 写区域重叠会导致假阳性校验失败（当前脚本中无此用法，仅提醒自行扩展时注意）
