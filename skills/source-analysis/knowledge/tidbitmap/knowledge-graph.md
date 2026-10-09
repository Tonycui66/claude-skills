# tidbitmap 知识图谱

> 功能点:`tidbitmap`(TID 位图 + TidStore 死元组收集)。按日期追加分析结果。
> 分析日期:2026-10-09

## 一、概念节点

| ID | 概念 | 代码锚点 | 核心事实 |
|---|---|---|---|
| N1 | TIDBitmap | [tidbitmap.cpp:275](../../../../../src/common/backend/nodes/tidbitmap.cpp#L275) | 位图扫描构建的 TID 集合,哈希表按 block 分桶;容量受 work_mem 预算约束(`tbm_calculate_entries` [:431](../../../../../src/common/backend/nodes/tidbitmap.cpp#L431)) |
| N2 | max_tuples_page | [tidbitmap.cpp:57-58](../../../../../src/common/backend/nodes/tidbitmap.cpp#L57-L58) | 单页元组上限:Astore=`MaxHeapTuplesPerPage`(8K页≈291),Ustore=`MaxPossibleUHeapTuplesPerPage`(更大) |
| N3 | 越界防护检查(位图) | [tidbitmap.cpp:474-479](../../../../../src/common/backend/nodes/tidbitmap.cpp#L474-L479) | `tbm_add_tuples` 校验 ctid offset∈[1,max_tuples_page],越界报 `tuple offset out of range: %u`,带 MOD_EXECUTOR 标签 |
| N4 | TidStore | [tidstore.cpp:200-208](../../../../../src/gausskernel/storage/access/common/tidstore.cpp#L200-L208) | VACUUM 收集死元组的基数树存储,同一检查在 `TidStoreSetBlockOffsets` [:251](../../../../../src/gausskernel/storage/access/common/tidstore.cpp#L251)、[:272](../../../../../src/gausskernel/storage/access/common/tidstore.cpp#L272)(无模块标签) |
| N5 | 调用方 | vacuumlazy.cpp | `TidStoreSetBlockOffsets` 被 VACUUM 堆扫描阶段调用 |
| N6 | 错误内存语义 | (通用机制) | ereport(ERROR) → longjmp 中止语句 → 查询内存上下文整体 Reset(tbm 释放);ErrorContext 每次重置 → 无累积泄漏 |

## 二、关系边

| From | To | 关系 | 说明 |
|---|---|---|---|
| N1 | N2 | 依赖 | 位图构建校验按表 AM 选上限(ustore 标志切换,[:316](../../../../../src/common/backend/nodes/tidbitmap.cpp#L316)) |
| N3 | N1 | 守护 | 越界即 ERROR 中止位图构建 |
| N4 | N5 | 被调用 | VACUUM 死元组收集 |
| N3/N4 | N6 | 触发 | 报错走回滚链,内存不累积 |

## 三、场景条目

### S1 「tuple offset out of range: 294」频繁出现(2026-10-09)
- **含义**:294 越过 Astore 8K 页元组上限(≈291)→ 索引中存在指向页面不可能位置的 ctid → **索引损坏/索引与页面不一致**的强信号(Ustore 上限更大,294 越界基本判定 Astore)
- **内存影响**:不持续增长;错误路径干净回滚(tbm 受 work_mem 约束且随语句中止释放);代价是反复中止语句/VACUUM 失败的 CPU/IO/日志量
- **间接风险**:VACUUM 路径反复失败 → 死元组堆积 → 表/索引磁盘间接膨胀
- **处置**:区分来源(日志带 MOD_EXECUTOR=位图,否则=VACUUM)→ 定位表/index → REINDEX → 仍出现则查页面/存储一致性;短期 `enable_bitmapscan=off` 止血
- **精确语义**(2026-10-09 补):291 是按最小行倒推的物理槽位上界,非实际行数;报错发生在索引 ctid 装入位图时的静态校验=索引条目声称了物理不可能的位置。**误报排查**:tbm_create 的 is_ustore 默认 false([tidbitmap.h:75](../../../../../src/include/nodes/tidbitmap.h#L75)),GIN 内部位图不传该参([ginget.cpp:139](../../../../../src/gausskernel/storage/access/gin/ginget.cpp#L139));但 DDL 禁止 ustore 建 GIN/btree(仅 ubtree/hnsw,[indexcmds.cpp:853-862](../../../../../src/gausskernel/optimizer/commands/indexcmds.cpp#L853-L862)),常规位图路径 is_ustore 从 RTE 经计划正确传递(createplan.cpp:3426)→ ustore 表常规路径无此误报

## 四、待深入

- [ ] TidStore 基数树结构细节(与 PG PG18 dead-tuple store 的差异)
- [ ] lossy 模式(pages_per_chunk/words_per_page)的内存-精度权衡
- [ ] [[ustore]] 位图路径 is_ustore 分支与 Ustore 上限的推导
