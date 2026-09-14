# 交接文档（Handoff）

> 面向接手本项目的下一个 agent。生成于 2026-09-14。
> 背景：模块已完成工程化（v1.1.6），用户将开发环境迁移至 Win11 + WSL2，本沙箱已完成迁移准备。
> 本文件仅含会话状态与协作约定；技术细节一律引用既有文档，不在此重复。

## 一、项目现状

| 项目 | 值 |
|---|---|
| 仓库 | https://github.com/Bonger34/fafu-checkin（public） |
| 版本 | v1.1.6（versionCode 8），已发布（Releases 页） |
| CI | 已就绪：push main 自动构建 dev 产物（Actions artifact）；**发布为手动流程** |
| 文档 | README（使用/发布）、docs/DEVELOPMENT.md（技术）、CHANGELOG.md（版本） |
| 设备侧 | 模块已安装并运行；21:30 自动签到待首次端到端验证 |

## 二、本会话完成的工作（时间顺序）

1. 逆向「数字FAFU」打卡链路并定位 H5 应用与接口（结论已固化到 docs/DEVELOPMENT.md §1）
2. 逆向请求签名算法与 token 机制；打通纯接口签到
3. 完成 KernelSU/Magisk 模块化（服务开关、动态描述、运行时文件收进模块目录）
4. 工程化：CI 自动构建 + 手动发布、开发版/发布版产物分离、更新检测（updateJson）
5. 修复若干问题（记录于 CHANGELOG.md 各版本条目与 git log）
6. 沙箱迁移准备（本文件与迁移包）

## 三、协作约定（用户偏好，重要）

- **发布方式**：手动发布（CI 只构建，不自动创建 Release、不自动同步 update.json）
- **发布说明**：以 CHANGELOG.md 对应小节为唯一来源（CI 构建时提取为 release-notes.md 草稿）
- **开发期代码保持干净**：一次性的迁移/清理逻辑不要写进代码，在会话中直接给出命令即可
- **描述文案**：使用绝对日期（如 `09-14`），不用「今日」等相对表述
- **版本号**：手动维护（module.prop 的 version / versionCode），不自动递增

## 四、下一步（无强制项）

1. 验证 21:30 自动签到：查看模块日志出现 `✅ 签到成功`（或 `✅ 补签成功`）
2. （可选）仓库分支保护、Dependabot 更新 actions 版本
3. 继续迭代时：改 module.prop 版本 + CHANGELOG → push → CI 构建 → 手动发布（流程见 README）

## 五、迁移状态

- 本沙箱（proot）已完成内容提取，可整体删除
- 敏感文件与未推送内容已打包：`migration-package.zip`（位置见会话末尾说明）
- 新环境（Win11 + WSL2）：`git clone` 仓库 + `sh build.sh` 即可恢复开发能力
- 设备侧无需迁移（模块独立于开发环境）

## Suggested skills

- 常规开发/修复：无必须技能，直接按 docs/DEVELOPMENT.md 操作
- 再次整理/交接文档：`handoff`、`writing-for-agents`

## 参考（勿重复，按需读取）

- [README.md](../README.md) — 使用、安装、发布流程
- [docs/DEVELOPMENT.md](DEVELOPMENT.md) — 系统知识、架构、调试、重新逆向
- [CHANGELOG.md](../CHANGELOG.md) — 版本历史
- `git log` — 完整提交记录
