# source-analysis skill

针对超大型 C/C++ 代码库(以 openGauss-server 为实战对象)的 Claude Code 源码分析技能,附带按功能点沉淀的知识图谱。

## 安装

将 `skills/source-analysis` 复制(或符号链接)到你的项目的 `.claude/skills/` 目录:

```bash
git clone https://github.com/<you>/<repo>.git
mkdir -p your-project/.claude/skills
cp -r <repo>/skills/source-analysis your-project/.claude/skills/
```

之后在 Claude Code 中输入 `/source-analysis` 并给出功能点即可。

## 组成

- `SKILL.md` — 分析方法论:模块定位、8 种入口点定位手法、SQL 生命周期、输出规范,以及"分析结果必须持久化到知识图谱"的约定
- `knowledge/<功能点>/knowledge-graph.md` — 知识图谱,四段式结构:
  - 概念节点表(ID / 概念 / 代码锚点 / 核心事实)
  - 关系边表
  - 场景条目(实际问题的根因链与处置)
  - 待深入清单
- `knowledge/ustore/tests/` — 可运行的验证脚本(如 Ustore × VACUUM 测试场景集)

## 已沉淀的功能点

| 功能点 | 内容摘要 |
|---|---|
| ustore | 原位更新引擎全貌:页/元组格式、TD 槽、UNDO 子系统、可见性、DML 决策树、VACUUM 耦合、扫描接口面(N1-N29) |
| table-storage-layout | 行→tuple→页容量模型:Astore 291 行/页 vs Ustore 538 行/页(含 sizeof 实证),TOAST 阈值与切块 |
| tidbitmap | TID 位图与 TidStore,"tuple offset out of range" 类报错的根因链 |

## 约定

- 知识图谱**存在则更新、不存在则新建**;多次分析按日期追加,不覆盖
- 节点 ID 稳定、顺序编号;跨功能点引用用 `[[功能点]]` 标记
- 每条核心事实必须带代码锚点(文件:行号),行号以分析时的源码为准
