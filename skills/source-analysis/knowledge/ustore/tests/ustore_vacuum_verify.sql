-- ============================================================================
-- ustore vacuum 结论验证用例集(配套 S9/N34 分析结论)
-- 运行环境:openGauss 单机实例(Linux);分布式模式下 gs_undo_* 会报不支持
-- 执行方式:gsql -d postgres -f ustore_vacuum_verify.sql 2>&1 | tee verify.log
-- 每个用例标注了【预期】;跑完把 verify.log 发回即可判读
-- ============================================================================

\echo ======== T9 VACUUM VERBOSE 支持 + 水位对账 ========

SELECT version();

DROP TABLE IF EXISTS t9_vac_verify;
CREATE TABLE t9_vac_verify (id int, val text) WITH (STORAGE_TYPE=USTORE);
INSERT INTO t9_vac_verify SELECT g, md5(g::text) FROM generate_series(1, 10000) g;
DELETE FROM t9_vac_verify WHERE id % 2 = 0;

-- 【预期】输出 "vacuuming uheap "public.t9_vac_verify" oldestXmin:XXXX"
--          以及 "found 5000 removable, 5000 nonremovable row versions ..."
-- 【老版本 2.x 表现】同样正常(lazy vacuum 早期就支持)
VACUUM VERBOSE t9_vac_verify;

-- 【预期】global_recycle_xid ≈ 上面 VERBOSE 输出的 oldestXmin(水位耦合证据)
SELECT global_recycle_xid, oldest_xmin, curr_used_undo_size, undo_threshold
FROM gs_stat_undo();

\echo ======== T10 频繁 DML 的 undo 增长与回收回落 ========

DROP TABLE IF EXISTS t10_undo_growth;
CREATE TABLE t10_undo_growth (id int) WITH (STORAGE_TYPE=USTORE);

-- 基线
SELECT curr_used_undo_size FROM gs_stat_undo();
SELECT insert, discard, used FROM gs_undo_meta(0, 0, 0);   -- zone 0 水位

-- 模拟频繁 insert/delete(10 轮)
INSERT INTO t10_undo_growth SELECT g FROM generate_series(1, 2000) g;
DELETE FROM t10_undo_growth WHERE id % 2 = 0;
INSERT INTO t10_undo_growth SELECT g FROM generate_series(1, 2000) g;
DELETE FROM t10_undo_growth WHERE id % 2 = 0;

-- 【预期】curr_used_undo_size / zone insert 水位明显上涨(undo 随 DML 线性增长)
SELECT curr_used_undo_size FROM gs_stat_undo();
SELECT insert, discard, used FROM gs_undo_meta(0, 0, 0);

-- 等待 undo_retention_time 过期后回收(默认 3 天太久,尝试会话级调小;
-- 若报错说明该 GUC 不可会话级设置,改用观察法:隔天再查一次对比)
SET undo_retention_time = 60;   -- 若报错:该 GUC 不允许会话级设置,跳过 SET 继续往下,靠延长观察对比

VACUUM t10_undo_growth;
SELECT pg_sleep(70);
VACUUM t10_undo_growth;

-- 【预期】undo 水位回落(discard 接近 insert),表大小稳定不膨胀
SELECT curr_used_undo_size FROM gs_stat_undo();
SELECT insert, discard, used FROM gs_undo_meta(0, 0, 0);
RESET undo_retention_time;

\echo ======== T11 VACUUM FULL 支持(版本判定) ========

DROP TABLE IF EXISTS t11_vacfull;
CREATE TABLE t11_vacfull (id int, val text) WITH (STORAGE_TYPE=USTORE);
INSERT INTO t11_vacfull SELECT g, repeat('x', 100) || g FROM generate_series(1, 20000) g;
DELETE FROM t11_vacfull WHERE id % 2 = 0;

SELECT pg_size_pretty(pg_relation_size('t11_vacfull')) AS size_before;

-- 【预期-新版本】正常完成,INFO 横幅含 "vacuuming uheap";size_after 明显缩小
-- 【预期-老版本 2.x】INFO: skipping "t11_vacfull" --- Don't vacuum full
--   ustore table,this feature to be released in the future.  → size 不变
VACUUM FULL t11_vacfull;

SELECT pg_size_pretty(pg_relation_size('t11_vacfull')) AS size_after;

\echo ======== T12 lazy vacuum 不做物理冻结(语义差异) ========

DROP TABLE IF EXISTS t12_freeze;
CREATE TABLE t12_freeze (id int) WITH (STORAGE_TYPE=USTORE);
INSERT INTO t12_freeze SELECT g FROM generate_series(1, 5000) g;

SELECT relfrozenxid64 FROM pg_class WHERE relname = 't12_freeze';

-- 【预期】relfrozenxid64 前进到 ≈ globalRecycleXid(水位),但元组头未被
--   物理改写(无 pageinspect 对照时,以 relfrozenxid64 前进值为准);
--   对照 astore 表跑同样语句,astore 的 relfrozenxid 来自 FreezeLimit 真实冻结
VACUUM FREEZE t12_freeze;
SELECT relfrozenxid64 FROM pg_class WHERE relname = 't12_freeze';
SELECT global_recycle_xid FROM gs_stat_undo();   -- 对照:应与上面值接近

\echo ======== T13 oldestXmin 耦合:长事务压住 removable 计数 ========
-- 需要两个会话;下面标注【会话A】【会话B】按序手动执行

-- 【会话A】
--   BEGIN;
--   SELECT count(*) FROM t9_vac_verify;          -- 建立快照
-- 【会话B】
--   DELETE FROM t9_vac_verify WHERE id <= 1000;  -- id 1..1000(奇数行还在)
--   VACUUM VERBOSE t9_vac_verify;
-- 【预期】removable 计数 < 1000(长事务的快照压住 oldestXmin,部分行不可清)
--   且 oldestXmin 值不再前进
-- 【会话A】
--   COMMIT;
-- 【会话B】
--   VACUUM VERBOSE t9_vac_verify;
-- 【预期】第二轮 removable 计数回升(≈ 剩余全部死行),oldestXmin 前进
--   判读要点:两轮 oldestXmin 值差 = 长事务对 undo 回收水位的阻塞量(S8 判读)

\echo ======== 完成;请回传完整日志 ========
