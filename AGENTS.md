## Agent skills

### Issue tracker

Issue 与 spec 都作为 GitHub issue 存放（Bonger34/fafu-checkin），统一用 `gh` CLI 操作。见 `docs/agents/issue-tracker.md`。

### Triage labels

五个标准 triage 角色直接使用同名标签（`needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` / `wontfix`）。见 `docs/agents/triage-labels.md`。

### Domain docs

单上下文：仓库根 `CONTEXT.md` + `docs/adr/`。见 `docs/agents/domain.md`。

### 真机验证的交付物

让人做真机验证前，先把 CI 产出的 dev 包交出来：PR 分支只跑 `Check`，不会自动构建；必须用
`gh workflow run build.yml --ref <branch>` 手动触发 `Build`，等它成功，把 artifact
（`fafu-checkin-dev-<short-sha>`）或下载后的 zip 一并给出。只给分支 / PR 链接不算交付。

