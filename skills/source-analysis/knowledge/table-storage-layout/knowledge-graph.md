# table-storage-layout 知识图谱

> 功能点:`table-storage-layout`(行→tuple→页面的容量模型,横跨 Astore/Ustore/TOAST)。
> 分析日期:2026-10-09

## 一、概念节点

| ID | 概念 | 代码锚点 | 核心事实 |
|---|---|---|---|
| N1 | 行=元组模型 | (架构) | 一行=1 tuple;超出页容量限制时由 TOAST 切块成多个 toast tuple |
| N2 | Astore 页容量 | MaxHeapTuplesPerPage [htup.h:536](../../../../../src/include/access/htup.h#L536) | (8192−24页头)/(24头+4行指针)=**291/页**;MinHeapTupleSize=24 [htup.h:523](../../../../../src/include/access/htup.h#L523);MaxHeapTupleSize=8160 |
| N3 | Ustore 页容量 | [knl_upage.h:203](../../../../../src/include/access/ustore/knl_upage.h#L203) | 页头 **56B**(TransactionId 为 uint64,c.h:487!)+TD区(默认4槽[rel.h:451](../../../../../src/include/utils/rel.h#L451)×16B)→(8192−56−64)/(**11+4**)=**538/页**;理论极限(8192−56)/15=542;经编译实证(sizeof 验证程序)确认 |
| N4 | 元组头尺寸 | HeapTupleHeaderData 23B / UHeapDiskTupleData 9B([knl_utuple.h:144](../../../../../src/include/access/ustore/knl_utuple.h#L144)) | Ustore 无 xmin/xmax,头小14B;对齐均 MAXALIGN(8) |
| N5 | TOAST 阈值 | [tuptoaster.h:45-51](../../../../../src/include/access/tuptoaster.h#L45-L51) | TOAST_TUPLES_PER_PAGE=4 → TOAST_TUPLE_THRESHOLD=2032B(8K页);超过先压缩后外置 |
| N6 | TOAST 切块 | TOAST_MAX_CHUNK_SIZE [tuptoaster.h:89](../../../../../src/include/access/tuptoaster.h#L89) | 2032−24−4−4−4=**1996B/chunk**;行占 tuple 数=1+Σceil(列长/1996);改此值需 initdb |
| N7 | 实测工具 | contrib/pgstattuple、pageinspect | pgstattuple→每行均摊字节;pg_column_size→单行序列化尺寸;heap_page_items→逐页逐tuple;pg_relation_size fork 区分 main/toast |
| N8 | Ustore 索引目标 | UTOAST_INDEX_TARGET [tuptoaster.h:70](../../../../../src/include/access/tuptoaster.h#L70) | DefaultTdMaxUHeapTupleSize/16,索引键压缩阈值(对应 astore 的 509B) |

## 二、关系边

| From | To | 关系 | 说明 |
|---|---|---|---|
| N5 | N6 | 推导 | chunk 大小由"每页4个最大块"反推 |
| N1 | N6 | 规则 | 行>阈值→1+切块数个 tuple |
| N2/N3 | [[tidbitmap]] | 呼应 | "294"越界报错:294>291(Astore上限),公式与报错吻合 |
| N3 | [[ustore]] N3-N7 | 细化 | Ustore 页格式节点的容量量化 |
| N4 | N2/N3 | 决定 | 元组头尺寸进入每页行数公式 |

## 三、场景条目

### S1 页容量速查(8K 页,2026-10-09)
- Astore:上限 291 行/页,行头 23B;Ustore:上限 **538** 行/页(默认TD=4),行头 11B 但页固定开销 120B(56页头+64TD)
- **教训**:TransactionId 在 openGauss 是 uint64(c.h:487)而非 PG 的 uint32,手算前必须核实 typedef;结构体大小用编译器 sizeof 实证,勿凭字段目测
- TOAST:整行>2032B 触发,chunk=1996B;例:10240B text → 1 主壳 + 6 chunk = 7 tuple
- 估算公式:每页行数 ≈ 可用空间/(MAXALIGN(头+列数据+对齐)+4 行指针)

### S2 表膨胀是否连带索引膨胀(2026-10-09)
- **判定式:新版本是否换了 ctid**。换 → 写新索引条目 → 索引膨胀;不换 → 零增长
- Astore:非 HOT 更新必换 ctid → 索引膨胀;HOT(不改索引列+同页)免更新,但页越满越难 HOT,与表膨胀互相加剧
- [[ustore]]:原位更新 ctid 不变 → 索引零增长(核心优势);非原位(S6 劣化)退回 astore 行为
- UBTree 特化:索引条目自带 xmin/xmax(`UBTreeItupGetXminXmax` [ubtree.h:683](../../../../../src/include/access/ubtree.h#L683)),可独立判死;配套 UNDO_UBT_INSERT/DELETE 维护
- **索引不缩容**:VACUUM 只清死条目,索引页不归还 OS(表可截尾,索引不可),真缩容靠 REINDEX
- 与 [[tidbitmap]] S1 呼应:索引陈旧条目/损坏正是 "294" 类报错的来源

## 四、待深入

- [ ] 变长列对齐细节(short varlena 1B 头 vs 4B 头在行内的实际偏移计算)
- [ ] UTOAST 与 astore TOAST 行为差异
- [ ] 32K 页(BLCKSZ=32768)下各常数的换算
