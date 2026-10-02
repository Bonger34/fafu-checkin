# Issue tracker：GitHub

本仓库的 issue 与 spec 都以 GitHub issue 的形式存放。所有操作统一使用 `gh` CLI。

## 约定

- **新建 issue**：`gh issue create --title "..." --body "..."`；多行正文用 heredoc 或 `--body-file`。
- **读取 issue**：`gh issue view <number> --comments`，需要时用 `jq` 过滤评论，并一并取回标签。
- **列出 issue**：`gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`，配合 `--label` / `--state` 过滤。
- **评论**：`gh issue comment <number> --body "..."`
- **加 / 去标签**：`gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **关闭**：`gh issue close <number> --comment "..."`

仓库由 `git remote -v` 推断；在克隆目录内执行时 `gh` 会自动识别。

## PR 作为 triage 入口

**不使用 PR 作为需求入口：no。**（若本仓库把外部 PR 当作功能请求处理，把这里改成 `yes`；`/triage` 会读取这一行。）

当该开关为 `yes` 时，PR 走与 issue 相同的标签与状态，使用对应的 `gh pr` 命令：

- **读取 PR**：`gh pr view <number> --comments`，diff 用 `gh pr diff <number>`。
- **列出待 triage 的外部 PR**：`gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments`，只保留 `authorAssociation` 为 `CONTRIBUTOR`、`FIRST_TIME_CONTRIBUTOR`、`NONE` 的条目（去掉 `OWNER` / `MEMBER` / `COLLABORATOR`）。
- **评论 / 打标签 / 关闭**：`gh pr comment`、`gh pr edit --add-label` / `--remove-label`、`gh pr close`。

GitHub 的 issue 与 PR 共用同一套编号，因此裸写的 `#42` 可能是其中任一种：先用 `gh pr view 42` 解析，取不到再退回 `gh issue view 42`。

## 当某个技能要求「发布到 issue tracker」

新建一个 GitHub issue。

## 当某个技能要求「取出对应工单」

执行 `gh issue view <number> --comments`。

## Wayfinding 操作

供 `/wayfinder` 使用。**map** 是一个 issue，其**子** issue 是工单。

- **Map**：单个 issue，带 `wayfinder:map` 标签，正文承载 Notes / Decisions-so-far / Fog。用 `gh issue create --label wayfinder:map` 创建。
- **子工单**：作为 map 的 GitHub sub-issue 关联（用 `gh api` 调 sub-issues 端点）。若环境未启用 sub-issue，则把子工单加入 map 正文的任务列表，并在子工单正文顶部写 `Part of #<map>`。标签用 `wayfinder:<type>`（`research` / `prototype` / `grilling` / `task`）。认领后把工单指派给推进者。
- **阻塞关系**：用 GitHub 原生 issue 依赖表示（在 UI 中可见的规范形式）。用 `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>` 添加边，其中 `<blocker-db-id>` 是阻塞者的**数据库 id**（`gh api repos/<owner>/<repo>/issues/<n> --jq .id`，不是 `#number`，也不是 `node_id`）。GitHub 通过 `issue_dependencies_summary.blocked_by` 报告未关闭的阻塞者数量。若依赖功能不可用，退回在子工单正文顶部写 `Blocked by: #<n>, #<n>`。所有阻塞者都关闭时，该工单才算解除阻塞。
- **frontier 查询**：列出 map 下所有未关闭的子工单（`gh issue list --state open`，以 sub-issue / 任务列表限定范围），剔除有未关闭阻塞者（`issue_dependencies_summary.blocked_by > 0`，或 `Blocked by` 行里仍有未关闭 issue）以及已有指派者的条目；按 map 顺序取第一个。
- **认领**：`gh issue edit <n> --add-assignee @me`，这是本次会话的第一次写操作。
- **结清**：`gh issue comment <n> --body "<答案>"`，然后 `gh issue close <n>`，再把上下文指针（要点 + 链接）追加到 map 的 Decisions-so-far。
