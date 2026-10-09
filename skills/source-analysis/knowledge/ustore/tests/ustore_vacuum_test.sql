-- ============================================================================
-- Ustore × VACUUM 集成测试场景集
-- 依据:knowledge/ustore/knowledge-graph.md 场景 S5(两遍式 VACUUM 与 UNDO 耦合)
-- 运行环境:openGauss 2.0+ 实例(Linux),gsql -f 本文件
-- 说明:每个场景 T* 独立,可单独执行;验证点标注了对应代码机制
-- ============================================================================

-- ============================================================================
-- T1 基础回收:VACUUM 后页面空间复用(机制:LazyVacuumUPage + UPageRepairFragmentation + FSM)
-- ============================================================================
\set T1 echo
DROP TABLE IF EXISTS t1_ustore_vac;
CREATE TABLE t1_ustore_vac (id int primary key, val text) WITH (STORAGE_TYPE=USTORE);
INSERT INTO t1_ustore_vac SELECT g, md5(g::text) FROM generate_series(1, 10000) g;

-- 基线:表大小与死元组统计
SELECT pg_size_pretty(pg_relation_size('t1_ustore_vac')) AS size_before,
       relpages FROM pg_class WHERE relname = 't1_ustore_vac';

DELETE FROM t1_ustore_vac WHERE id % 2 = 0;
VACUUM t1_ustore_vac;

-- 验证点 1:死元组清零(n_dead_tup = 0),活元组 = 5000
SELECT n_live_tup, n_dead_tup, last_vacuum FROM pg_stat_user_tables WHERE relname = 't1_ustore_vac';

-- 验证点 2:重新插入同量数据,表大小不应翻倍(死元组空间被复用)
INSERT INTO t1_ustore_vac SELECT g, md5(g::text) FROM generate_series(20001, 25000) g;
SELECT pg_size_pretty(pg_relation_size('t1_ustore_vac')) AS size_after_reuse;
-- 预期:size_after_reuse 明显小于"不 vacuum 直接插入"的对照;若接近翻倍说明回收未生效

-- ============================================================================
-- T2 长事务阻塞 VACUUM(机制:UHeapTupleSatisfiesOldestXmin 的 RECENTLY_DEAD 分支,nkeep 保留)
-- ============================================================================
DROP TABLE IF EXISTS t2_ustore_vac;
CREATE TABLE t2_ustore_vac (id int, val text) WITH (STORAGE_TYPE=USTORE);
INSERT INTO t2_ustore_vac SELECT g, 'v' || g FROM generate_series(1, 5000) g;

-- 会话 A(保持打开,不要提交!):
--   BEGIN;
--   SELECT count(*) FROM t2_ustore_vac;   -- 建立快照
-- 会话 B:
DELETE FROM t2_ustore_vac WHERE id <= 3000;
VACUUM t2_ustore_vac;
-- 验证点 1:A 未提交时,死元组应保留(n_dead_tup 不清零或表大小不降)
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 't2_ustore_vac';

-- 会话 A 执行:COMMIT;
-- 会话 B:
VACUUM t2_ustore_vac;
-- 验证点 2:A 提交后同一命令应回收 3000 行(n_dead_tup -> 0)
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 't2_ustore_vac';

-- 日志佐证:DEBUG 级别下可见 "vacuuming uheap ... oldestXmin:xxx"
--   会话 A 持快照时与提交后各跑一次,对比 oldestXmin 前进情况:
--   SET client_min_messages TO DEBUG1; VACUUM VERBOSE t2_ustore_vac;

-- ============================================================================
-- T3 UNDO 回收联动:已删无存储行(RP_REDIRECT)等 undo 丢弃后才能回收
--     (机制:S5 特有①②;观测:gs_undo_meta / gs_undo_translot)
-- ============================================================================
DROP TABLE IF EXISTS t3_ustore_vac;
CREATE TABLE t3_ustore_vac (id int, val text) WITH (STORAGE_TYPE=USTORE);
INSERT INTO t3_ustore_vac SELECT g, 'v' || g FROM generate_series(1, 3000) g;

-- 观察 undo 空间基线(zone_id 0 起,-1 表示全部)
SELECT * FROM gs_undo_meta(0, -1, 0);

DELETE FROM t3_ustore_vac;
VACUUM t3_ustore_vac;

-- 验证点 1:undo 保留期内(默认 undo_retention_time 未过),行指针为 REDIRECT 状态
--   vacuum 不会真正回收其空间 → pg_relation_size 几乎不降
SELECT pg_size_pretty(pg_relation_size('t3_ustore_vac')) AS size_with_undo_retained;

-- 等待 undo 过期(生产值大,测试建议会话级调小后重启或直接等待;也可调低
--   undo_space_limit_size 触发强制丢弃路径)。undo 丢弃后:
SELECT * FROM gs_undo_translot(0, -1);
VACUUM t3_ustore_vac;
SELECT pg_size_pretty(pg_relation_size('t3_ustore_vac')) AS size_after_undo_discard;
-- 预期:丢弃后的这轮 VACUUM 才能回收 REDIRECT 行指针,空间明显下降

-- ============================================================================
-- T4 VACUUM 失败自回滚(机制:S5 特有②——vacuum 回收行指针时自身写 undo)
--     需要二进制带白盒框架:SET ustore_unit_test = 'UHEAP_LAZY_VACUUM'
-- ============================================================================
-- SET ustore_unit_test = 'UHEAP_LAZY_VACUUM';   -- 注入 LazyVacuumUPage 失败
-- VACUUM t3_ustore_vac;                          -- 预期:WARNING/ERROR,vacuum 中止
-- RESET ustore_unit_test;
-- 验证点:失败后表数据可正常查询、可再次 VACUUM 成功(自身 undo 回滚生效)
--   SELECT count(*) FROM t3_ustore_vac; VACUUM t3_ustore_vac;

-- ============================================================================
-- T5 无索引表:第一遍就地清理(机制:LazyScanUHeap 中 hasindex=false 直接管页)
-- ============================================================================
DROP TABLE IF EXISTS t5_ustore_vac;
CREATE TABLE t5_ustore_vac (id int, val text) WITH (STORAGE_TYPE=USTORE);
INSERT INTO t5_ustore_vac SELECT g, 'v' || g FROM generate_series(1, 5000) g;
DELETE FROM t5_ustore_vac WHERE id <= 4000;

SET client_min_messages TO DEBUG1;
VACUUM VERBOSE t5_ustore_vac;
RESET client_min_messages;
-- 验证点:日志出现 "removed 4000 row versions in N pages",且单遍完成
--   (有索引时索引清理与页清理分两批,日志顺序不同)

-- ============================================================================
-- T6 索引清理正确性(机制:lazy_vacuum_index 复用 + UBTree bulk delete)
-- ============================================================================
DROP TABLE IF EXISTS t6_ustore_vac;
CREATE TABLE t6_ustore_vac (id int, val text) WITH (STORAGE_TYPE=USTORE);
CREATE INDEX idx_t6 ON t6_ustore_vac(id);
INSERT INTO t6_ustore_vac SELECT g, 'v' || g FROM generate_series(1, 8000) g;

SELECT pg_size_pretty(pg_relation_size('idx_t6')) AS idx_before;
DELETE FROM t6_ustore_vac WHERE id % 3 <> 0;
VACUUM t6_ustore_vac;
SELECT pg_size_pretty(pg_relation_size('idx_t6')) AS idx_after;

-- 验证点 1:索引空间明显收缩(约 2/3 条目已删)
-- 验证点 2:索引扫描结果完整(只剩 id 为 3 的倍数)
SELECT count(*) FROM t6_ustore_vac;                       -- 预期 2667
SELECT count(*) FROM t6_ustore_vac WHERE id < 8000;        -- 走 idx_t6 的计划,预期 2667
-- 验证点 3:TID 复用安全:删除后新插入行若复用 TID,索引扫描不得读到错误行
INSERT INTO t6_ustore_vac VALUES (999999, 'newrow');
SELECT * FROM t6_ustore_vac WHERE id = 999999;             -- 预期恰好一行

-- ============================================================================
-- T7 并发 DML vs VACUUM(机制:LazyVacuumUHeap 的 ConditionalLockBuffer 失败跳页)
--     两个 gsql 会话同时执行:
--     会话 A: VACUUM t6_ustore_vac;
--     会话 B: UPDATE t6_ustore_vac SET val = 'c' WHERE id % 100 = 0;
-- 验证点:双方都能完成,无死锁报错;之后数据一致:
--   SELECT count(*) FROM t6_ustore_vac;
--   持续压测可循环交替执行 20 轮后跑一致性校验
-- ============================================================================

-- ============================================================================
-- T8 autovacuum 链路(机制:TableRelationVacuum 分流 → LazyVacuumUHeapRel)
-- ============================================================================
ALTER TABLE t1_ustore_vac SET (autovacuum_vacuum_scale_factor = 0.01);
-- 触发:批量更新后等待 autovacuum worker(观察 last_autovacuum)
UPDATE t1_ustore_vac SET val = 'x' WHERE id % 10 = 0;
-- 验证点(等待数分钟后):
SELECT last_autovacuum, n_dead_tup FROM pg_stat_user_tables WHERE relname = 't1_ustore_vac';
-- 日志验证:确认日志中出现 "vacuuming uheap" 而非 astore 的 "vacuuming table"
--   (grep 服务端日志:grep "vacuuming uheap" pg_log/)

-- ============================================================================
-- 回归基线:仓库自带分区表用例(并行执行参考,非本脚本部分)
--   src/test/regress/sql/ustore_subpartition_analyze_vacuum.sql
--   含 range-list 二级分区 + local/global 索引 + delete + vacuum 全流程
-- ============================================================================
