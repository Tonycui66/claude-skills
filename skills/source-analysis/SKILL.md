---
name: source-analysis
description: 分析 openGauss-server 源码。当用户要求分析源码、梳理执行流程、定位某个功能/参数/系统表/函数的实现、或理解内核模块架构时使用。
---

# openGauss-server 源码分析指南

本仓库是 openGauss 数据库服务端内核(PostgreSQL 9.2.4 衍生,大量 C++ 化改造,含 MOT 内存引擎、行列混合存储、线程池、Ustore 等特性)。分析时遵循下面的模块地图和方法论。

## 1. 模块地图

### 入口与请求处理 (`src/gausskernel/process/`)
| 目录 | 职责 | 关键文件 |
|---|---|---|
| `main/` | 进程入口 | `main.cpp` |
| `tcop/` | 流量控制/查询调度 | `postgres.cpp`(exec_simple_query 主流程)、`utility.cpp`(DDL/工具语句)、`pquery.cpp`、`stmt_retry.cpp`(语句重试) |
| `postmaster/` | 后台服务进程(gaussdb、checkpointer、walwriter、autovacuum、bgwriter、stat、Audit、Separeator 等) | |
| `threadpool/` | 线程池模型(worker/listener/会话分发) | |
| `stream/` | 跨节点并行/SMP 流线程 | |
| `job/` | 定时任务 scheduled job | |
| `globalplancache/` | 全局计划缓存 GPC | |

### SQL 引擎
- **解析器** `src/common/backend/parser/`:词法 `scan.l`、语法 `gram.y`(所有 SQL 语句的语法入口)、`analyze.cpp`(语法树→Query)、`keywords.cpp`+`kwlookup.cpp`(关键字表)。
- **重写** `src/gausskernel/optimizer/rewrite/`:查询重写、行级安全 RLS。
- **优化器** `src/gausskernel/optimizer/`:核心在 `plan/`(生成 Plan,`planmain.cpp`/`createplan.cpp`)、`path/`(代价与路径)、`prep/`(预处理 parse_analyze 后的 plan 流程)、`commands/`(explain 等)、`statistics/`(统计信息与采样)、`geqo/`(遗传查询优化)、`gplanmgr/`(计划管理)、`opfusion/`(见 runtime)。
- **执行器** `src/gausskernel/runtime/`:
  - `executor/`:传统 volcano 迭代器执行器(`execMain.cpp`、`nodeSeqscan.cpp`、`nodeIndexscan.cpp`、`nodeAgg.cpp` 等,节点名均为 `node*.cpp`)。
  - `vecexecutor/`:向量化执行(列存/向量化算子,`vec*.cpp`)。
  - `opfusion/`:算子下推/旁路(exec_simple 路径,简单语句跳过优化器直接执行)。
  - `codegen/`:LLVM 表达式编译加速。
- **PL/pgSQL 及过程语言** `src/pl/`、`src/common/pl/`。

### 存储引擎 (`src/gausskernel/storage/`)
- `access/`:表访问方法。`heap/`(Astore 行存堆表)、`ustore/`(Ustore 事务型行存,UNDO 回滚段在 `access/undo/`)、`transam/`(事务、MVCC、CLOG/XLOG:`xact.cpp`、`varsup.cpp`)、`index/`(B-tree 等)、`nbtree/`。
- `buffer/`:缓冲区管理(bufmgr、buffer partition)。
- `cstore/`:列存储(CU 压缩单元)。
- `mot/`:MOT 内存引擎(`core/`、`fdw_adapter/`,通过 FDW 挂接)。
- `lmgr/`:锁管理(lock、lwlock)。
- `replication/`:流复制、逻辑解码;`xlog_share_storage/`、`dss/`(共享存储)。
- `smgr/`、`file/`:存储介质管理。
- `bulkload/`:GDS 并行导入。

### 分布式
- `src/common/backend/pgxc/`、`src/common/pgxc/`、`src/common/backend/pgxc_single/pool/`:分布式框架与 pooler 连接池。
- `src/include/distributelayer/`。

### 公共基础
- `src/common/backend/`:继承自 PG 的后端公共代码(catalog、commands、utils、nodes 等,**很多核心代码在这里而不是 gausskernel**)。
- `src/gausskernel/cbb/`:公共基础组件(communication 通信 libcomm、security、utils、resource)。
- `src/gausskernel/security/`:安全(加密、脱敏、账本数据库 gs_ledger)。
- `src/gausskernel/dbmind/`:自治/智能优化相关。
- `src/bin/`:客户端与工具(gsql、initdb、pg_ctl、gs_guc、pg_dump、gs_probackup 等)。
- `src/include/`:几乎全部头文件,按子系统分目录(`access/`、`catalog/`、`executor/`、`optimizer/` 等)。改代码通常要同时看 `.h` 在这里的定义。

## 2. 一条 SQL 的生命周期(单机)

```
gsql/客户端 → 通信层 libcomm → 线程池分发
→ tcop/postgres.cpp exec_simple_query
  → parser: pg_parse_query (gram.y → 语法树 RawStmt)
  → analyze: parse_analyze (→ Query)
  → rewrite: QueryRewrite
  → optimizer: pg_plan_query (path → plan)
  → executor: ExecutorStart/Run/End (或 opfusion 旁路 / 向量化计划)
→ storage: buffer manager → heap/ustore/cstore/mot → WAL
```

DDL/工具语句走 `tcop/utility.cpp` 的 `ProcessUtility`。后台写进程看 `postmaster/`。

## 3. 定位代码的方法论(按切入信号)

按以下优先级从"已知信号"定位实现:

1. **语法/SQL 关键字**:先在 `src/common/backend/parser/gram.y` 搜关键字,顺着产生的节点(如 `T_CreateStmt`)再搜处理函数;关键字集合在 `parser/keywords/`。
2. **GUC 参数**:主文件 `src/common/backend/utils/misc/guc.cpp`,按主题拆分的定义在 `src/common/backend/utils/misc/guc/`(guc_memory / guc_network / guc_resource / guc_security / guc_sql / guc_storage 等);从参数名能直接跳到使用点(全局变量名通常与参数一致,如 `enable_indexscan`)。
3. **系统函数/内置函数**:`src/common/backend/catalog/pg_proc.cpp`(及 `pg_proc_ext.cpp`)是内置函数定义表 → 找到 oid 和 C 函数名 → 全局搜函数名。
4. **系统表/系统视图**:`src/include/catalog/`(头文件中 `#define` 定义列布局与 oid),视图定义在 `system_views.sql`。
5. **错误信息**:用错误文本(或 errcode 如 `ERRCODE_...`)全局搜索,顺藤摸瓜到抛错点。
6. **执行计划算子名**:EXPLAIN 输出的节点名 ↔ `runtime/executor/node*.cpp` / `vecexecutor/vec*.cpp` 一一对应。
7. **日志/错误码**:GA-LOG 的 module 名、`distribute_errmsg.txt`、错误码范围表。
8. **已知 PG 对应物**:openGauss 保留大量 PG 9.2 结构,PG 中熟悉的函数名(`heap_insert`、`ExecInitNode` 等)大概率同名或仅大小写/命名空间差异。

## 4. 搜索与阅读技巧

- 用 `Grep`(ripgrep)而非全文 grep;代码量大,先限定目录(如只在 `src/gausskernel/storage/access/` 下搜)再扩大。
- C++ 化命名:类名/函数常带 `Kn` 前缀?否——注意 openGauss 常见前缀:`Vec*`(向量化)、`Mot*`、`Ustore`、`gs_`(工具/特性名)。函数体大量沿用 PG C 风格(下划线命名)。
- 头文件与实现分离:`src/include` 与实现目录平行,看数据结构先去 `src/include/<子系统>/`。
- 语法树/计划节点定义:`src/include/nodes/parsenodes.h`、`plannodes.h`、`nodes.h`;新增节点需同步 `outfuncs.c`/`copyfuncs.c`/`readfuncs.c`。
- 构建入口:`build.sh` / `configure`(GNUmakefile 体系),分析代码不需要编译,但了解 macro 开关(如 `ENABLE_MULTIPLE_NODES`、`ENABLE_MOT`)有助于区分分布式/单机分支代码——**大量代码被 `#ifdef ENABLE_MULTIPLE_NODES` 包裹,分析时注意当前模式**。
- 找调用链:从入口函数用 Grep 找调用者(`rg "FuncName\(" -t cpp`),自底向上或自顶向下双向逼近,绘制调用链时给出行号引用。

## 5. 输出要求

分析源码时,结论必须落到具体文件与行号引用(`file:line`),并区分:
- **代码事实**(在哪个文件做了什么)
- **推断**(基于命名/注释的合理猜测,需标注)

涉及执行流程时,画出调用链(文本树或 mermaid),标注关键函数所在文件。涉及行为差异(单机/分布式、行存/列存、Astore/Ustore/MOT)时明确指出适用分支。

## 6. 知识图谱沉淀(强制)

每完成一个功能点的源码分析,必须把结果存入对应功能点的知识图谱:`.claude/skills/source-analysis/knowledge/<功能点>/knowledge-graph.md`(如 `ustore/`、`opfusion/`、`threadpool/`)。文件结构固定为四部分:

1. **概念节点表**(ID/概念/代码锚点/核心事实)——每个分析过的机制一行,锚点带 `file:line` 相对链接
2. **关系边表**(From/To/关系/说明)——节点间的调用、包含、引用、缓解等关系
3. **设计取舍/场景条目**——每次深化分析(如机制对比、风险场景)按日期追加小节
4. **待深入清单**——本次未展开的点,供下次追加

同一功能点的分析结束时执行:**知识图谱文件已存在则更新(在既有结构上追加新节点/边/场景/待深入项,不覆盖既有内容),不存在则按上述四段式新建**。节点 ID 保持稳定(新增节点续号);与其他功能点的交叉引用用 `[[功能点名]]` 标记(如 Ustore 的 UNDO 机制关联 `[[undo]]` `[[opfusion]]`)。已存在:`ustore`。
