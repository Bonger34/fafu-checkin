# 领域文档

各工程技能在探索本仓库代码时应如何消费领域文档。

## 探索之前先读这些

- 仓库根的 **`CONTEXT.md`**；或
- 仓库根的 **`CONTEXT-MAP.md`**（若存在）：它指向每个上下文各一份 `CONTEXT.md`，读取与主题相关的每一份。
- **`docs/adr/`**：读取与你即将改动的领域相关的 ADR。多上下文仓库中还要检查 `src/<context>/docs/adr/` 里的上下文级决策。

若这些文件不存在，**静默继续**：不要指出缺失，也不要主动建议创建。`/domain-modeling` 技能（经由 `/grill-with-docs` 与 `/improve-codebase-architecture` 抵达）会在术语或决策真正被敲定时惰性创建它们。

## 文件结构

单上下文仓库（绝大多数仓库）：

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

多上下文仓库（根目录存在 `CONTEXT-MAP.md`）：

```
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← 全系统级决策
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← 上下文级决策
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

**本仓库：单上下文**——仓库根 `CONTEXT.md` + `docs/adr/`。两者目前都还不存在，这是正常的：按需惰性创建。

## 使用术语表的词汇

当你的产出要命名某个领域概念时（issue 标题、重构提案、假设、测试名），使用 `CONTEXT.md` 中定义的术语，不要漂移到术语表明确避免的同义词。

若你需要的概念还不在术语表里，这是一个信号：要么你在发明项目并不使用的语言（重新考虑），要么确实存在空缺（记下来交给 `/domain-modeling`）。

## 与 ADR 冲突时要点明

若你的产出与既有 ADR 矛盾，明确提出来，而不是悄悄覆盖：

> _与 ADR-0007（event-sourced orders）冲突，但值得重新讨论，因为……_
