# Ustore 知识图谱

> 功能点:`ustore`(原位更新引擎)。每次针对 Ustore 的源码分析结果都追加到本文件,保持节点/边结构。
> 分析日期:2026-10-09

## 一、概念节点

| ID | 概念 | 代码锚点 | 核心事实 |
|---|---|---|---|
| N1 | Ustore 引擎 | `src/gausskernel/storage/access/ustore/`(实现)、`src/include/access/ustore/`(头文件) | 事务型行存,旧版本不入表页,写入独立 UNDO 空间 |
| N2 | 表选择机制 | [guc.cpp:2053](../../../../../src/common/backend/utils/misc/guc.cpp#L2053)、[rel.h:272](../../../../../src/include/utils/rel.h#L272) | GUC `enable_default_ustore_table` 或建表 `WITH (storage_type=ustore)`;类型存于 Relation.storage_type |
| N3 | UHeap 页面格式 | [knl_upage.h:230-274](../../../../../src/include/access/ustore/knl_upage.h#L230-L274) | 页头 → TD 区 → RowPtr 区 → 行数据;比 Astore 多 TD 区 |
| N4 | 页头 UHeapPageHeaderData | [knl_upage.h:260](../../../../../src/include/access/ustore/knl_upage.h#L260) | 额外字段:td_count、pd_prune_xid、pd_xid_base/pd_multi_base(32位xid基址) |
| N5 | TD 槽(事务目录) | [knl_utype.h:29-40](../../../../../src/include/access/ustore/knl_utype.h#L29-L40) | 16B:xactid(64位,MSB 区分 XID/CSN)+ undo_record_ptr(16位zone+32位块+16位偏移) |
| N6 | RowPtr | [knl_upage.h:248](../../../../../src/include/access/ustore/knl_upage.h#L248) | 15位offset+2位flags+15位len;状态机 RP_UNUSED/NORMAL/REDIRECT/DEAD;删除行无存储时 offset 打包可见性+TD号 |
| N7 | 元组 UHeapDiskTupleData | [knl_utuple.h:144-152](../../../../../src/include/access/ustore/knl_utuple.h#L144-L152) | 无 xmin/xmax,仅 xid(短)+td_id(8位);锁信息在 flag 的 UHEAP_*_LOCK 位 |
| N8 | DML 入口 | UHeapInsert [knl_uheap.cpp:563](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L563)、UHeapDelete [:2013](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L2013)、UHeapUpdate [:2407](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L2407) | 原位写 + 生成 UNDO 记录 + LogUHeap*WAL |
| N9 | UNDO 记录类型 | [knl_uundotype.h:249-257](../../../../../src/include/access/ustore/undo/knl_uundotype.h#L249-L257) | UNDO_INSERT/MULTI_INSERT/DELETE/INPLACE_UPDATE/UPDATE/UBT_*;内容按 UREC_INFO_* 裁剪;inplace 更新用 XOR 差量 |
| N10 | 可见性判断 | UHeapTupleSatisfiesVisibility [knl_uvisibility.cpp:176](../../../../../src/gausskernel/storage/access/ustore/knl_uvisibility.cpp#L176) | TD.xactid 为 CSN 且 ≤ 快照 CSN → 快路径直接判;否则走 undo 链回放 |
| N11 | Undo 遍历状态机 | [knl_uundotype.h:146-155](../../../../../src/include/access/ustore/undo/knl_uundotype.h#L146-L155) | TRAVERSAL_COMPLETE/STOP/ABORT(强丢)/END(已丢)/ENDCHAIN(链尾) |
| N12 | UndoZone | [knl_uundozone.h:76](../../../../../src/include/access/ustore/undo/knl_uundozone.h#L76)、ZoneGroup [:392](../../../../../src/include/access/ustore/undo/knl_uundozone.h#L392) | 按持久级三档(PERMANENT/UNLOGGED/TEMP),线程池+NUMA 时按节点再分;每会话绑定 zone 串行写 |
| N13 | UndoSpace | [knl_uundospace.h:54](../../../../../src/include/access/ustore/undo/knl_uundospace.h#L54) | 独立 relfilenode 文件(UNDO_*_DIR 目录),buffer 管理复用 |
| N14 | MiniSlot | [knl_uundotype.h:158-163](../../../../../src/include/access/ustore/undo/knl_uundotype.h#L158-L163) | 每事务一槽:endUndoPtr/startUndoPtr/xactId/dbId,供回滚与回收遍历 |
| N15 | 同步回滚 | TryExecuteUndoActions [xact.cpp:8354](../../../../../src/gausskernel/storage/access/transam/xact.cpp#L8354) → ExecuteUndoActions | abort 路径同步应用 undo(latest_urp→first_urp) |
| N16 | Undo 应用实现 | [knl_undoaction.cpp](../../../../../src/gausskernel/storage/access/ustore/knl_undoaction.cpp) | VerifyAndDoUndoActions [:62](../../../../../src/gausskernel/storage/access/ustore/knl_undoaction.cpp#L62)、ExecuteUndoActionsPage [:257](../../../../../src/gausskernel/storage/access/ustore/knl_undoaction.cpp#L257)、UHeapUndoActions [:343](../../../../../src/gausskernel/storage/access/ustore/knl_undoaction.cpp#L343)、UpdateTupleHeaderFromUndoRecord [:895](../../../../../src/gausskernel/storage/access/ustore/knl_undoaction.cpp#L895) |
| N17 | 异步回滚 | [knl_undolauncher.cpp:58](../../../../../src/gausskernel/storage/access/ustore/knl_undolauncher.cpp#L58) + knl_undoworker.cpp | undo 链超过单事务限额时 fork 后台 worker 异步应用 |
| N18 | UndoRecycler | [knl_uundorecycle.cpp](../../../../../src/gausskernel/storage/access/ustore/undo/knl_uundorecycle.cpp) | 后台线程,按 undo_retention_time + 全局 xid 冻结水位推进丢弃 |
| N19 | 页面修剪 Pruning | UHeapPagePruneOptPage [knl_pruneuheap.cpp:111](../../../../../src/gausskernel/storage/access/ustore/knl_pruneuheap.cpp#L111)、Opt [:430](../../../../../src/gausskernel/storage/access/ustore/knl_pruneuheap.cpp#L430)、Execute [:744](../../../../../src/gausskernel/storage/access/ustore/knl_pruneuheap.cpp#L744) | pd_prune_xid 水位过后清 TD 引用,截短 undo 链;页面记 potential_freespace |
| N20 | 崩溃恢复 | [knl_uredo.cpp](../../../../../src/gausskernel/storage/access/ustore/knl_uredo.cpp)、knl_uextremeredo.cpp、knl_uundoxlog.cpp | Ustore 页面与 undo 均有 WAL;undo 损坏走极端恢复;未提交事务 undo 由恢复后路径应用 |
| N21 | 周边模块 | knl_uam.cpp(AM接口)、knl_uscan.cpp(扫描)、knl_utuptoaster.cpp(TOAST)、knl_uhio.cpp(IO)、knl_uvacuumlazy.cpp(vacuum) | Ustore 专用配套;索引走 UBTree(pg_am.h:156) |
| N22 | Undo 相关 GUC | [guc_storage.cpp](../../../../../src/common/backend/utils/misc/guc/guc_storage.cpp) | undo_zone_count [:3853](../../../../../src/common/backend/utils/misc/guc/guc_storage.cpp#L3853)、undo_space_limit_size [:3825](../../../../../src/common/backend/utils/misc/guc/guc_storage.cpp#L3825)、undo_limit_size_per_transaction [:3839](../../../../../src/common/backend/utils/misc/guc/guc_storage.cpp#L3839)、undo_retention_time [:3988](../../../../../src/common/backend/utils/misc/guc/guc_storage.cpp#L3988) |
| N23 | VACUUM 分流 | TableRelationVacuum [vacuum.cpp:1907-1915](../../../../../src/gausskernel/optimizer/commands/vacuum.cpp#L1907-L1915) | `RelationIsUstoreFormat(rel)` ? `LazyVacuumUHeapRel` : astore `lazy_vacuum_rel`;autovacuum 同路径 |
| N24 | Ustore VACUUM 第一遍 | LazyScanUHeap [knl_uvacuumlazy.cpp:191](../../../../../src/gausskernel/storage/access/ustore/knl_uvacuumlazy.cpp#L191) | 逐页:先 `UHeapPagePruneGuts` [:338](../../../../../src/gausskernel/storage/access/ustore/knl_uvacuumlazy.cpp#L338) 修剪,再按 RowPtr 状态分拣:RP_UNUSED 跳过、RP_REDIRECT(已删无存储)**跳过不碰**、RP_DEAD 直接收、RP_NORMAL 走 `UHeapTupleSatisfiesOldestXmin`([knl_uvisibility.cpp:1654](../../../../../src/gausskernel/storage/access/ustore/knl_uvisibility.cpp#L1654))判 DEAD/RECENTLY_DEAD;死元组入共享 TidStore(`dead_items_add` [:434](../../../../../src/gausskernel/storage/access/ustore/knl_uvacuumlazy.cpp#L434)) |
| N25 | Ustore VACUUM 第二遍 | LazyVacuumUHeap [:131](../../../../../src/gausskernel/storage/access/ustore/knl_uvacuumlazy.cpp#L131) → LazyVacuumUPage [:81](../../../../../src/gausskernel/storage/access/ustore/knl_uvacuumlazy.cpp#L81) | 迭代 TidStore → 每页 RowPtrSetUnused + `UPageRepairFragmentation` 碎片整理 + `LogUHeapClean` WAL + FSM 登记;无索引表第一遍就地清理([:441-454](../../../../../src/gausskernel/storage/access/ustore/knl_uvacuumlazy.cpp#L441-L454)) |
| N26 | 强制旁路 VACUUM | ForceVacuumUHeapRelBypass [:580](../../../../../src/gausskernel/storage/access/ustore/knl_uvacuumlazy.cpp#L580) | 仅 autovacuum 用途:跳过堆扫描,把 RecentGlobalDataXmin 推到 globalRecycleXid(undo 回收水位),只清索引并推进 relfrozenxid;**全树未发现调用方**(推断:外部调度预留或遗留代码) |
| N27 | 无 VisibilityMap | knl_uvacuumlazy.cpp:650 注释 | "UStore don't have VisibilityMap"——无 all-visible 快路径,旁路清理里 newRelAllvisible 恒 0 |
| N28 | VACUUM×UNDO 耦合 | LazyScanUHeap 注释 [:170-189](../../../../../src/gausskernel/storage/access/ustore/knl_uvacuumlazy.cpp#L170-L189) | ① 判死需 undo 链遍历(丢弃进度影响判死);② 回收行指针时 VACUUM 自身写 undo(有索引时);③ TID 复用保护:标记 unused 的行指针打包 TD 槽信息,VACUUM 事务提交前 TID 不复用 |
| N29 | 扫描接口面 | TableAmRoutine [tableam.cpp:1161](../../../../../src/gausskernel/storage/access/table/tableam.cpp#L1161) + [knl_uscan.h:26](../../../../../src/include/access/ustore/knl_uscan.h#L26) | 一套 TableScanDesc 接口承载多模式:scan_begin(顺序)/begin_bm(位图)/begin_sampling(TABLESAMPLE)/begin_parallel(并行)/index_fetch_*(索引回表)/tuple_fetch_row_version(TID 扫描);UHeapScanDescData 用 rs_bitmapscan/rs_samplescan/rs_parallel/dop 标志复用同一机制 |
| N30 | DML 的 undo 生成点 | Insert→UHeapPrepareUndoInsert [knl_uheap.cpp:646](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L646)/MultiInsert [:3510](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L3510);Delete→UHeapPrepareUndoDelete [:2227](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L2227) | **每条 INSERT/DELETE/原位 UPDATE 都写 undo**:insert 记录"新插入"事实(回滚删除+abort 判定),delete/update 保存旧元组数据;频繁 DML ⇒ undo 线性增长,至 undo_retention_time 过期由 Recycler 回收 |
| N31 | undo 链的物理形态 | GetPrevUrp [knl_uundoapi.cpp:749](../../../../../src/gausskernel/storage/access/ustore/undo/knl_uundoapi.cpp#L749) + GetPrevRecordLen [knl_uundorecord.cpp:201](../../../../../src/gausskernel/storage/access/ustore/knl_uundorecord.cpp#L201) | 同一事务的 undo 记录在 log 中**物理连续**:每条记录尾部存前一条的长度(2B),回溯 = 当前偏移−prevLen;页上 TD 槽(16B:xactid+UndoRecPtr)指向该事务在该页的最新记录,由此进入链头;跨事务版本链靠 DELETE/UPDATE 记录携带的 TD 信息(need_old_xact_info)串接 |
| N32 | undo 观测函数族 | [pgundostatfuncs.cpp](../../../../../src/common/backend/utils/adt/pgundostatfuncs.cpp)(单机模式,分布式报不支持) | gs_stat_undo(全局水位)/gs_undo_meta(zone 级水位)/gs_undo_translot(事务槽列表)/gs_undo_translot_dump_xid(按 xid 走链)/gs_undo_dump_record·gs_undo_dump_xid(逐记录 dump)/gs_undo_dump_parsepage_mv(页面 MVCC 解析);签名均为数字参数:**gs_undo_meta(type,zoneId,location)** type∈{0=zone,1=translot组,2=undoSpace,3=slotSpace} location∈{0=共享内存,1=磁盘};**gs_undo_translot(type,zoneId)**;用法样例:src/test/regress/sql/test_ustore_undo_tool.sql |
| N33 | undo 水位体系 | gs_stat_undo 列 [pgundostatfuncs.cpp:702-786](../../../../../src/common/backend/utils/adt/pgundostatfuncs.cpp#L702-L786) + zone 水位 [knl_uundozone.h:91-102](../../../../../src/include/access/ustore/undo/knl_uundozone.h#L91-L102) | **全局**(gs_stat_undo):global_recycle_xid、oldest_xmin、undo_threshold(=undo_space_limit_size×FORCE_RECYCLE_PERCENT=0.8,[knl_uundorecycle.cpp:77](../../../../../src/gausskernel/storage/access/ustore/undo/knl_uundorecycle.cpp#L77))、curr_used_undo_size、max_undo_chain_len、create/discard_undo_file_count;**Zone 级**(gs_undo_meta(0,zoneId,0) 列名 insert/discard/end/used/lsn):insertUrecPtr=写入水位、discardUrecPtr=正常回收水位(retention 驱动)、forceDiscardUrecPtr=强制丢弃水位(空间压力驱动),insert−discard 差=活 undo;**槽级**:recycleTSlotPtr/recycleXid/frozenXid(LogUndoZoneInfo 宏 [knl_uundozone.h:63-74](../../../../../src/include/access/ustore/undo/knl_uundozone.h#L63-L74) 打印全部,仅 DEBUG 日志);GUC:undo_retention_time(默认 259200s)、undo_space_limit_size(默认 256GB,guc_storage.cpp:3825) |

## 二、关系边

| From | To | 关系 | 说明 |
|---|---|---|---|
| N2 | N1 | 配置 | storage_type 决定走 Ustore |
| N3 | N5 | 包含 | 页面含 TD 区 |
| N5 | N9 | 寻址 | TD.undo_record_ptr 指向 undo 记录 |
| N7 | N5 | 引用 | 元组 td_id 指向页上 TD 槽(8位) |
| N8 | N9 | 生成 | DML 写对应类型 undo 记录 |
| N8 | N20 | 记日志 | LogUHeapInsert/Delete/Update |
| N9 | N9 | prevurp 链 | 同 TD 槽多次修改形成 undo 链,多版本在链上 |
| N10 | N5 | 读取 | 可见性判断先读 TD |
| N10 | N11 | 状态机 | 需 undo 时遍历状态机 |
| N10 | N19 | 缓解 | 修剪截短链,减少回放 |
| N15/N17 | N16 | 执行 | 同步/异步回滚都落到 Undo 应用 |
| N16 | N13 | 读写 | 应用 undo 需读 undo 空间 |
| N18 | N11 | 产生 ABORT | 强制丢弃 → 遍历遇 ABORT |
| N18 | N22 | 受控 | 回收受 retention/space_limit GUC 约束 |
| N14 | N18 | 依据 | MiniSlot 提供事务 undo 起止,供回收遍历 |
| N12 | N13 | 管理 | Zone 管理物理 Space |
| N19 | N4 | 使用 | 依赖 pd_prune_xid 水位 |
| N23 | N24/N25 | 分流 | Ustore 表走专属 VACUUM,复用 astore 的 LVRelStats/TidStore/lazy_vacuum_index 机制 |
| N24 | N10 | 依赖 | 判死走 Ustore 可见性(undo 遍历),[[tidbitmap]] 的 TidStore 检查同样生效 |
| N18 | N24 | 制约 | RP_REDIRECT 行需 undo 已丢弃才能由 VACUUM 回收,回收进度与 UndoRecycler 联动 |
| N18 | N26 | 输入 | globalRecycleXid 驱动旁路 VACUUM 的 frozenxid 推进 |
| N25 | N20 | 记日志 | LogUHeapClean 为 Ustore 专属 WAL 记录 |
| N30 | N31 | 写入 | 同事务连续 DML 的 undo 记录物理相邻,TD 槽指向链头(最新记录) |
| N31 | N14 | 寻址 | 链的起止由事务槽(MiniSlot)的 start/end URP 界定 |
| N32 | N31 | 解析 | dump 函数复用 GetPrevUrp 走链逻辑 |
| N32 | N18 | 观测 | gs_undo_meta/translot 反映 Recycler 回收进度 |
| N33 | N18 | 驱动 | discard 水位由 Recycler 推进,受 oldest_xmin/retention 约束;forceDiscard 由空间压力驱动(呼应 N17/N18) |
| N33 | N26 | 供给 | global_recycle_xid 是旁路 VACUUM 推进 frozenxid 的输入 |
| N33 | N14 | 界定 | insert−discard 差值即"尚未回收的 undo",与 MiniSlot 起止对应 |

## 三、设计取舍场景(2026-10-09 深化分析)

### S1 写放大转移
- **事实**:表页原位覆盖新值,旧值进 undo → 表页不膨胀;代价 = undo 写入 + 回收负担 + TD/锁协调(DML_MAX_RETRY_TIMES 100000,[knl_upage.h:29](../../../../../src/include/access/ustore/knl_upage.h#L29))
- **对比**:Astore 每次更新在表页追加新版本,靠 VACUUM 回收;Ustore 把膨胀问题转移到 undo 空间
- **适用**:OLTP 高频更新场景收益最大

### S2 读路径复杂化
- **事实**:旧快照读需沿 undo 链回放,最坏 O(链长);缓解 = CSN 快路径(N10,多数读最新数据的查询不碰 undo)+ Pruning(N19)
- **风险模式**:长查询快照越旧 → 链越长;且修剪不敢剪其所需版本 → 长事务/长查询双重恶化
- **锚点**:[knl_uvisibility.cpp:176](../../../../../src/gausskernel/storage/access/ustore/knl_uvisibility.cpp#L176)

### S3 回滚廉价
- **事实**:undo 存修改前完整状态;回滚 = 应用 undo,字节级还原页面,无 Astore 式"abort 残留物"延迟清理;成本与事务大小成正比,做完即净
- **路径**:小事务同步(xact.cpp:8354),长链异步(UndoWorker,N17)

### S4 空间风险点与兜底
- **事实**:undo 可回收 ⇔ 无活快照需要 + retention 期满;长事务阻塞回收 → 空间逼近 undo_space_limit_size
- **兜底**:强制丢弃(force discard)后,旧快照遍历遇 UNDO_TRAVERSAL_ABORT 报 `snapshot too old! the undo record has been force discard`([knl_uvisibility.cpp:632-651](../../../../../src/gausskernel/storage/access/ustore/knl_uvisibility.cpp#L632-L651),含 globalRecycleXid/forceDiscardURecPtr 等诊断信息)
- **定位**:把"磁盘满全库停写"的系统性故障换为"单查询报错退出"的局部失败(类比 Oracle ORA-01555)
- **运维推论**:盯长事务/长查询;undo_retention_time 勿过大;监控 snapshot too old 频率

### S5 Ustore 与 VACUUM 的结合(2026-10-09)
- **结构**:入口分流([vacuum.cpp:1907](../../../../../src/gausskernel/optimizer/commands/vacuum.cpp#L1907))→ 两遍式 lazy vacuum(与 astore 同构):第一遍 `LazyScanUHeap` 修剪+收死元组(共享 TidStore,超 budget 触发批间索引清理),第二遍 `LazyVacuumUHeap` 摘行指针+碎片整理;索引清理复用 astore 的 `lazy_vacuum_index`(UBTree bulk delete)
- **Ustore 特有**:①判死依赖 undo 可见性,undo 被回收/强丢的行可直接判 DEAD 或报错;②"已删无存储"行(RowPtrIsDeleted)vacuum 不碰,等 UndoRecycler 推进后下轮处理;③有索引时 vacuum 回收行指针也写 undo;④无 VisibilityMap;⑤旁路接口 ForceVacuumUHeapRelBypass 跳堆只清索引,用 globalRecycleXid 推进 frozenxid(树内无调用方,存疑)
- **与 [[tidbitmap]] 的联系**:同一条 TidStore 代码,但 MAX_OFFSET_IN_BITMAP=1015(tidstore.cpp:92),故 "294" 报错非此路径

### S6 原位更新何时劣化为 astore 式(2026-10-09)
- **判定主干**:[UHeapUpdate](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L2407) 内 `useInplaceUpdate` 决策:
  1. `needToast`(新元组 ≥ UTOAST_TUPLE_THRESHOLD=2008B 且含变宽列,或新旧任一含外部 toast 指针)[:2648](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L2648) → 必非原位 [:2660](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L2660)
  2. `newtupsize <= oldtupsize` → 原位 [:2691](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L2691)
  3. 否则先 `UHeapPagePruneOpt` 修剪腾空间,成功且 `RowPtr offset + newtupsize <= BLCKSZ` → 原位扩展 [:2778-2783](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L2778-L2783)
  4. 上层 `allowInplaceUpdate=false`[:2775](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L2775)(执行器在表有 AFTER ROW UPDATE 触发器或 mlog 物化日志表时置 false,[nodeModifyTable.cpp:2178-2184](../../../../../src/gausskernel/runtime/executor/nodeModifyTable.cpp#L2178-L2184))
  5. 都不满足 → 非原位 [:2794](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L2794)
- **非原位=astore 行为回归**:旧版本留页(UHEAP_UPDATED+ctid 指新位置)→ 膨胀回归靠 VACUUM(S5);新元组 `RelationGetBufferForUTuple` 选页,同页放不下跨页 [:2835](../../../../../src/gausskernel/storage/access/ustore/knl_uheap.cpp#L2835);ctid 变→索引列被改时需更新索引(原位更新 ctid 不变、索引免更新,是 ustore 核心优势)
- **边界**:变长缩小仍原位;同大小变长原位+XOR 差量 undo;跨分区更新走 delete+insert;TD 槽不足是等待重试非劣化;`useLinkUpdate`(链接更新)预留机制,树内无置 true 路径

### S7 频繁 INSERT/DELETE 的 undo 链与观测(2026-10-10)
- **会否产生 undo**:会。每条 INSERT 写 URecHeapInsert 型 undo(N30),每条 DELETE 写 URecHeapDelete 型(旧元组全量入 undo);频繁 DML ⇒ undo 空间线性增长,**但不是泄漏**——事务提交后经过 undo_retention_time(默认按 GUC)由 UndoRecycler 异步回收,水位回落
- **链形态**:同事务内记录物理连续、尾存 prevLen 回溯;页 TD 槽→该事务该页最新记录;跨事务版本链靠 delete/update 记录携带的 TD 信息
- **观测路径**(单机模式,分布式 ereport 不支持):
  ```sql
  -- ① 全局水位与回收状态
  SELECT * FROM gs_stat_undo();
  -- ② zone 级水位(insert/discard/end/used/lsn;第2参 -1 表全部 zone)
  SELECT * FROM gs_undo_meta(0, -1, 0);
  -- ③ 事务槽列表:每个产生 DML 的 xact 一行(xid/起止 URP;第1参 0=共享内存 1=磁盘)
  SELECT * FROM gs_undo_translot(0, -1);
  -- ④ 按事务走链:从该 xact 最新记录回溯列出全部 undo 记录
  SELECT * FROM gs_undo_dump_xid(<xid>);
  -- ⑤ 单条记录内容(xid/cid/reloid/utype/blockno/prevurp/payloadlen)
  SELECT * FROM gs_undo_record(<urp>);
  ```
  **勘误**(2026-10-12):初版把 ②③ 参数写成布尔。实签名:`gs_undo_meta(type, zoneId, metaLocation)`,type∈{0=zone,1=translot组,2=undoSpace,3=slotSpace},metaLocation∈{0=共享内存,1=磁盘};`gs_undo_translot(type, zoneId)`
  ```
- **演示**:会话 A `BEGIN;` 循环 INSERT+DELETE 不提交 → 会话 B 查 ②③ 可见本 xact 的 undo 增长;A 回滚后可见性靠这些 undo 判 abort(呼应 S3 回滚廉价);A 提交等待 retention 过期后再查 ②,计数回落
- **回归样例**:`src/test/regress/sql/test_ustore_undo_tool.sql`(undo 工具函数用法全集)

### S8 undo 水位线的获取与健康判读(2026-10-12)
- **三级水位**(N33):全局(gs_stat_undo)/Zone 级(gs_undo_meta type=0,列 insert/discard/end/used/lsn)/槽级(allocateTSlotPtr/recycleTSlotPtr/recycleXid,仅 DEBUG 日志 LogUndoZoneInfo 输出)
- **水位语义**:insert=写入头,discard=正常回收尾(retention 到期后 Recycler 推进),end(forceDiscard)=强制丢弃尾(used 超 undo_threshold=undo_space_limit_size×0.8 时推进,丢弃未过期 undo,读旧版本报 snapshot too old,呼应 S4);回收边界受 GetGlobalOldestXmin 约束——**discard 卡住不动 ⇒ 有长事务**
- **监控 SQL**:
  ```sql
  -- 全局:global_recycle_xid 是否前进、curr_used_undo_size 与 undo_threshold 的距离
  SELECT global_recycle_xid, oldest_xmin, curr_used_undo_size, undo_threshold,
         create_undo_file_count, discard_undo_file_count FROM gs_stat_undo();
  -- 各 zone 活 undo 量(insert−discard):差值持续增大 = 回收跟不上
  SELECT * FROM gs_undo_meta(0, -1, 0);
  ```
- **判读**:① global_recycle_xid 不动 + translot 里存在老 xact → 长事务(S5/T2 机制);② curr_used_undo_size 逼近 undo_threshold → 即将强丢,关注 oldest_xmin 对应事务;③ discard_undo_file_count 增长正常回收,create−discard 差=未回收文件数
- **注**:src/bin/libog_query/src_mock.cpp 中的 gs_undo_meta 等只是 libog_query 的 mock 桩,非真实现;真身在 pgundostatfuncs.cpp

## 四、测试场景(2026-10-09)

T1-T8 测试集见 [tests/ustore_vacuum_test.sql](tests/ustore_vacuum_test.sql),与 S5 机制一一对应:

| 场景 | 验证机制 | 关键观测 |
|---|---|---|
| T1 基础回收 | LazyVacuumUPage + 碎片整理 + FSM | pg_relation_size 复用、n_dead_tup 清零 |
| T2 长事务阻塞 | SatisfiesOldestXmin RECENTLY_DEAD→nkeep | 快照持有前后 dead_tup 对比、oldestXmin 前进 |
| T3 UNDO 回收联动 | RP_REDIRECT 行等 undo 丢弃 | gs_undo_meta/translot + 两轮 vacuum 尺寸对比 |
| T4 vacuum 自回滚 | vacuum 回收行指针写 undo | 白盒 `SET ustore_unit_test='UHEAP_LAZY_VACUUM'`(guc_sql.cpp:4587)注入失败 |
| T5 无索引单遍 | hasindex=false 就地清页 | VERBOSE 日志 "removed N row versions" |
| T6 索引清理 | lazy_vacuum_index + UBTree | 索引尺寸收缩 + TID 复用后扫描正确 |
| T7 并发 DML | ConditionalLockBuffer 跳页 | 双会话无死锁、数据一致 |
| T8 autovacuum 链路 | TableRelationVacuum 分流 | 日志 "vacuuming uheap" 字样 |

仓库自带回归基线:`src/test/regress/sql/ustore_subpartition_analyze_vacuum.sql`(分区+local/global索引)。白盒注入机制:`ustore_unit_test` GUC 按名字激活 knl_whitebox_test.cpp 中的 stub。

## 五、待深入(下次分析追加)

- [ ] 可见性状态机逐行分析(FetchTransInfoFromUndo 回放循环)
- [ ] opfusion 对 Ustore 的旁路条件
- [ ] UBTree 与 UNDO_UBT_* 记录的联动
- [ ] undo zone 绑定会话的分配策略(numa/threadpool 场景)
- [ ] UndoRecycler 回收水位推进细节(globalRecycleXid 与 undo_retention_time 的精确交互,呼应 S7)
