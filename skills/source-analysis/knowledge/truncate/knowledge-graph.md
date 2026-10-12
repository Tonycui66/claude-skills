# truncate 知识图谱

> 功能点:`truncate`(TRUNCATE TABLE 的内核实现,含 openGauss 回收站扩展)。
> 分析日期:2026-10-12

## 一、概念节点

| ID | 概念 | 代码锚点 | 核心事实 |
|---|---|---|---|
| N1 | ExecuteTruncate | [tablecmds.cpp:4827](../../../../../src/gausskernel/optimizer/commands/tablecmds.cpp#L4827) | 主入口;非分区表走 RelationSetNewRelfilenode,分区表逐分区 TruncateOnePart [:4881](../../../../../src/gausskernel/optimizer/commands/tablecmds.cpp#L4881);完成后 ReindexRelation 重建索引为空 [:4858](../../../../../src/gausskernel/optimizer/commands/tablecmds.cpp#L4858) |
| N2 | RelationSetNewRelfilenode | [relcache.cpp:5058](../../../../../src/common/backend/utils/cache/relcache.cpp#L5058) | **换壳而非重建**:① GetNewRelFileNode 分配新物理文件号 [:5078-5088](../../../../../src/common/backend/utils/cache/relcache.cpp#L5078-L5088) → ② RelationCreateStorage 建空文件 [:5150](../../../../../src/common/backend/utils/cache/relcache.cpp#L5150) → ③ RelationDropStorage 登记 commit 时 unlink 旧文件 [:5161](../../../../../src/common/backend/utils/cache/relcache.cpp#L5161) → ④ 原位 UPDATE pg_class(relfilenode 换新、relpages/reltuples 归零、relfrozenxid 置新)[:5196-5216](../../../../../src/common/backend/utils/cache/relcache.cpp#L5196-L5216) |
| N3 | 可回滚性 | relcache.cpp:5161 注释 | "Schedule unlinking of the old storage at transaction commit"——旧文件 commit 才删,abort 则原样保留 ⇒ TRUNCATE 在事务内可回滚 |
| N4 | toast/索引联动 | [tablecmds.cpp:4840-4849](../../../../../src/gausskernel/optimizer/commands/tablecmds.cpp#L4840-L4849) | toast 表同样换新 relfilenode(AccessExclusiveLock);索引定义保留、文件重建为空;序列默认不重置(RESTART IDENTITY 才动) |
| N5 | 回收站扩展(tcap) | [tcap_truncate.cpp:113,167](../../../../../src/gausskernel/storage/tcap/tcap_truncate.cpp#L113) | `enable_recyclebin` 开启时把旧 relfilenode 记入 pg_recyclebin ⇒ 支持 TRUNCATE 闪回;限制:与 truncate 触发器互斥 [:336](../../../../../src/gausskernel/storage/tcap/tcap_truncate.cpp#L336);openGauss 独有,社区 PG 无 |
| N6 | CStore/segment 特化 | relcache.cpp:5079-5113 | 段页式走 seg_alloc_segment;列存额外换 cudesc/delta/CU 文件——换壳策略对存储引擎统一 |

## 二、关系边

| From | To | 关系 | 说明 |
|---|---|---|---|
| N1 | N2 | 调用 | 每张被 truncate 的表(含 toast)各一次 |
| N2 | N3 | 保证 | unlink 延迟到 commit ⇒ 回滚安全 |
| N1 | N5 | 可选钩子 | enable_recyclebin 时旧文件入回收站而非直接删 |
| N5 | N3 | 修改 | 回收站开启时"commit 删除"变为"commit 转入 pg_recyclebin" |
| N2 | N6 | 分流 | 存储形态决定分配新文件的方式 |

## 三、场景条目

### S1 「TRUNCATE 是不是 drop+create」判读(2026-10-12)
- **答案:不是**。catalog 行与 OID 不变、权限/依赖/外键/视图引用全保留、索引定义保留(文件重建空);仅替换 relfilenode 指向的新空文件
- 与 drop+create 的可观测差异:OID 不变(pg_class 查询可证)、依赖对象健在、可在事务中回滚
- 运维注意:①旧文件 commit 时才释放,长事务会延迟空间归还;②AccessExclusiveLock 全表排他;③recyclebin 开启后空间占用=新文件+回收站旧文件,PURGE 前不释放;④统计信息归零,建议 truncate 后 ANALYZE(或依赖 autovacuum)
- 验证:`CREATE TABLE t(a int); INSERT...; SELECT oid, relfilenode FROM pg_class WHERE relname='t';` → TRUNCATE → oid 不变、relfilenode 变;`BEGIN; TRUNCATE t; ROLLBACK;` → 数据完好(N3)

## 四、待深入

- [ ] 回收站完整机制:gs_recyclebin 查询、PURGE/闪回语法、rcybaseid 匹配逻辑(tcap_truncate.cpp:426)
- [ ] 全局临时表(GTT)truncate 的特殊路径(modifyPgClass=false,relfilenode 存 gtt cache)
- [ ] 并发事务持快照读旧文件期间 commit unlink 的安全性(smgr 引用计数)
