---
title: 我的 AI 开发环境演进
subtitle: 从 Copilot 聊天到 Native Helper + Hook 驱动平台
version: v0 → v5
date: 2026-04-23
author: 结合 git 记录整理
---

# 我的 AI 开发环境演进

## 为什么写这一篇

前两篇 presentation 各自只讲了一段：
[`personal-terminal-platform-v1.0.md`](./personal-terminal-platform-v1.0.md) 聚焦三天的 v1.0 里程碑，[`ai-workspace-sharing-outline.md`](./ai-workspace-sharing-outline.md) 是对外分享的提纲。这一篇补齐的是 **为什么会走到这里** —— 把本仓库之前 (`v0` → `v3`) 的阶段一起串起来，再用 git 记录把 `v4` / `v5` 钉死在时间线上。

一句话定位：

> 这套环境的主线不是"折腾终端"，而是 **AI 编码助手形态的每一次切换，都逼我把工作环境往前推一格**。

---

## 演进一览

| 版本 | 时段 | 触发 | 形态 | 留下的问题 |
|---|---|---|---|---|
| `v0` | 很长一段时间 | — | VS Code 里 GitHub Copilot **inline 代码补全 + 聊天侧边栏** | AI 只在"单行 / 单块建议 + 我接受"粒度写代码；跨文件、多步任务要人脑托管 |
| `v1` | 一段相当长的时间 | Copilot 开放 **Agent 模式** | 仍在 VS Code 里，但 Copilot 可以自主跨文件读 / 改 / 跑 task | Agent 被约束在编辑器进程模型里；跑 shell 长任务、多 pane 协作不自然 |
| `v2` | 年后 | 终端原生 Agent CLI 成熟（Claude Code、Codex CLI 等） | 在 Windows Terminal 里直接跑 Agent CLI | WT 对长会话 / 高频重绘不稳（[microsoft/terminal#19772](https://github.com/microsoft/terminal/issues/19772#issuecomment-3790206055)） |
| `v3` | `v2` 短暂之后 | 需要更稳的终端 | 换到 WezTerm，仅作为"更好的终端" | 只替换了终端，没有平台能力 |
| `v4` | 2026-03-28 → 2026-04-17 | 发现 WezTerm 是**编程式配置** | 基于 WezTerm 搭工作区管理 + 贴图，靠人找 tmux pane 续任务 | 宿主动作靠脚本堆叠；多任务要人脑保存状态 |
| `v5` | 2026-04-18 → 现在 | 宿主链路不稳、任务状态散 | Native helper + Agent CLI hook 驱动的 attention pipeline | 继续收口、继续抬高验证标准 |

下面每一段逐个展开，有 commit 的版本附上关键 commit 作为证据。

---

## v0 — GitHub Copilot 代码补全 + 聊天

### 形态

- 工作主场是 VS Code。
- Copilot 同时承担两个角色：
  - **Inline 代码补全**（tab completion）：在光标处给出单行 / 单块建议，我按 Tab 接受。这是 Copilot 最早的形态，也是整个 v0 里用得最多的部分。
  - **Chat 侧边栏**（后续加入）：我贴代码 / 提问题，它回解释或改写建议。
- AI 已经在**真正写代码**，但粒度是"它提议 → 我确认接受"。
- 终端是第二公民，只跑构建、测试、看日志。

### 这一步解决的

- 第一次把 LLM 拉进日常编辑流程；样板代码 / 重复结构的书写成本显著下降。
- 让我对"AI 在哪种粒度上帮得上忙"有了直觉：在**单行、单块、单段逻辑**上最强。
- 聊天侧边栏补齐了"这段代码该怎么改 / 为什么错"这类解释类交互。

### 这一步留下的问题

- AI 不能自己读项目、跨文件改动、跑命令、看结果再决定下一步。
  - 比如重命名一个被二十个文件引用的函数 —— Copilot 只能在当前光标处帮忙，没法扫全仓库改一遍。
- 每一次接受 / 拒绝都发生在光标位置，**没有任务粒度的自主执行**。
  - 比如修一个 bug 要手动在十来个位置依次"Tab 接受 → 小改 → 继续"，完不成"你把这个 bug 修了"这种任务级交付。
- "跨文件 / 跨工具"的协作仍然全靠我搬运上下文。
  - 比如测试跑红了，我得把错误栈从终端 copy 到 Chat，Copilot 给建议，我再贴回编辑器 —— 三次上下文搬运才换一次建议。

---

## v1 — Copilot Agent 模式（在 VS Code 里跑了很久）

### 触发

Copilot 推出 **Agent 模式**：AI 不再局限于"我接受一条补全"或"侧边栏回一段答复"，而是可以在 VS Code 内部**自主跨文件读、改、跑 task、拉 terminal**。这是 AI 从"单点建议者"升级为"任务级执行者"的第一次跃迁，而且全部发生在编辑器里。

### 形态

- 仍然以 VS Code 为中心，但 Agent 可以在工程上下文里**连续执行多步**。
- 大量日常任务（重构、批量改写、按描述生成实现、跑测试修 bug）从"我读建议 / 手动采纳"变成"它动手 / 我审查"。
- 这个阶段持续时间很长 —— 远比预期长 —— 因为它**显著提高了日常产出**，迁移成本看起来并不划算。

### 这一步解决的

- AI 第一次真的"动手"：跨文件改动、调用工具、看输出、继续迭代。
- 对"什么任务交给 Agent、什么任务自己做"有了稳定的经验。
- 审查粒度从"看一段建议"升级到"看一批 diff + task 输出"。

### 这一步留下的问题

> 注：VS Code 集成终端支持多路 / split，Agent 也能通过 `runInTerminal` 起并行进程、也能和 REPL 交互。这里的问题不是"做不到"，而是**按哪个模型做**。

- **Agent 的操作契约是编辑器 API 级，不是 shell 级**。
  - 比如想把 Agent 和 `fzf` / `tmux send-keys` / `watch` / 我自己的 shell 函数自然拼起来，中间始终隔着一层 `runInTerminal` / task system 的编辑器抽象；同样一件事在 tmux 里是一个 pipe，在编辑器里是一个 tool call。
- **Agent 的终端是 VS Code panel 里的一个子 UI，不是 tmux 里和我平等的一个 pane**。
  - 比如我想同时并排推进三四个独立 Agent 任务（不同分支、不同项目），底部 panel 的空间和切换成本都不适合；在 tmux 里这就是四个 pane 的事。
- 编辑器内的 Terminal 视图只是附属品，不是 Agent 的主场。
  - 比如 `pnpm build` 输出几千行滚屏，想翻回去找某条 warning，用编辑器集成终端远不如一个真正的终端 + tmux copy-mode。

---

## v2 — Agent CLI 回到终端（Windows Terminal）

### 触发

年后，终端原生的 Agent CLI 形态成熟（Claude Code / Codex CLI 等）。相比 VS Code Agent，终端原生 Agent：

- 天然活在 shell 里，跑长会话、跑后台服务、跑交互式流程都是一等场景；
- 不受编辑器布局束缚，多窗口 / 多 tab / 多 tmux pane 可以并行；
- 和 Git、tmux、OS 工具链的距离更近。

**交互主场从编辑器反向回到了终端。**

### 形态

- 直接在 Windows Terminal 里开 Agent CLI session 干活。
- AI 和我共用同一条 shell。
- 出现大量**长会话、长输出、连续重绘**的场景。

### 这一步解决的

- Agent 真正从编辑器解绑：它现在拥有完整的 shell 控制权。
- 多任务、多项目、多分支的并行成为可能。

### 这一步留下的问题

- Windows Terminal 对这种负载并不舒服 —— 具体触发了 [microsoft/terminal#19772](https://github.com/microsoft/terminal/issues/19772#issuecomment-3790206055) 这类问题。
  - 表现就是 Agent CLI 跑到一半 UI 卡住 / 输出错位 / 输入无回显，必须强关 tab 重开。
- 没有工作区、没有状态持久化、没有跨任务管理：一切靠终端 tab 和人脑。
  - 比如同时在做三件事（featureA、bugfix、写文档），我只能开三个 tab，靠 tab 标题肉眼辨认谁是谁；WT 窗口一关全没了；切回来要重新 `cd`、重新启 Agent、重新把上下文贴回去。

---

## v3 — 迁移到 WezTerm（仍只是终端替代）

### 触发

WT 在 Agent CLI 场景下的异常让我开始找替代品，最终落到 WezTerm。

### 形态

- 只是**换终端**，其它不变。
- 当时对 WezTerm 的认知还停留在"更稳、Unicode 更规范、性能好"的层面。

### 这一步解决的

- Agent CLI 场景下的稳定性问题。
- 为下一步"WezTerm 可编程"这个发现埋下了伏笔。

### 这一步留下的问题

- 仍然是"单终端 + 一堆窗口"的形态。
  - 每天开工还是"新建 tab → `cd` 到 repo → 启 Agent"，重复三遍，没有"打开项目 A"这种一键入口。
- 工作区、多任务、宿主动作都还没有抽象。
  - 比如我希望"在 Agent 里按一下就跳到 VS Code 对应文件"，当时只能 copy 路径到资源管理器，自己拖过去。

---

## v4 — WezTerm 成为 AI 开发平台的起点

> 时间：`2026-03-28` 起，至 `2026-04-17` 附近；这一段全部有 git 记录。

### 触发

某一刻注意到 **WezTerm 的配置是 Lua**，不是 ini。既然能编程，那就不只是终端 —— 它可以是一个个人工作平台的宿主。

### 这一段做了什么（按 commit 串）

**平台骨架**

- [`44ac488`](https://github.com/yunsii/wezterm-config/commit/44ac488) Initial commit（2026-03-28）—— 仓库开张。
- [`2a72f25`](https://github.com/yunsii/wezterm-config/commit/2a72f25) `feat(wezterm): complete initial WSL workspace setup`（2026-03-29）—— WSL 工作区第一版。
- [`47bae0f`](https://github.com/yunsii/wezterm-config/commit/47bae0f) `feat(wezterm): add runtime mode and launcher profiles`（2026-03-29）—— runtime / launcher profile 抽象。

**工作区与多任务**

- [`dc7e5b7`](https://github.com/yunsii/wezterm-config/commit/dc7e5b7) `feat(tmux): add git worktree navigation`（2026-03-29）
- [`e2fc1f1`](https://github.com/yunsii/wezterm-config/commit/e2fc1f1) `feat(scripts): add worktree task workflow`（2026-03-29）
- [`ec8069a`](https://github.com/yunsii/wezterm-config/commit/ec8069a) / [`b622979`](https://github.com/yunsii/wezterm-config/commit/b622979) worktree-task 布局重设计 + configure flow（2026-04-01）
- **这里第一次把"一个任务 = 一个分支 + 一个目录 + 一个 tmux 会话"绑起来。**

**贴图处理（用户提到的早期平台能力之一）**

- [`eba03fe`](https://github.com/yunsii/wezterm-config/commit/eba03fe) `feat(ui): streamline clipboard behavior in hybrid-wsl`（2026-03-31）
- [`eb2d8ea`](https://github.com/yunsii/wezterm-config/commit/eb2d8ea) `fix(ui): cache smart image paste in a background listener`（2026-04-04）—— 把图片粘贴从同步脚本做成**后台 listener 缓存**，这是第一段"不只是脚本，是长生命周期辅助进程"的雏形。

**人为找 pane 续任务**

- [`2487ae1`](https://github.com/yunsii/wezterm-config/commit/2487ae1) `feat(tmux): add popup command panel`（2026-04-02）—— 命令面板出现。
- 但这个阶段 **任务状态还是人脑托管的**：切回哪个 workspace、进哪个 pane，都要自己记。Agent 跑完了没、卡住了没，只能人眼去扫。

**AI Agent 作为一等公民**

- [`5410c67`](https://github.com/yunsii/wezterm-config/commit/5410c67) `refactor(agent): switch default agent CLI to claude and generalize docs`（2026-04-08）
- [`87b9db9`](https://github.com/yunsii/wezterm-config/commit/87b9db9) / [`c1443fc`](https://github.com/yunsii/wezterm-config/commit/c1443fc) / [`354ac88`](https://github.com/yunsii/wezterm-config/commit/354ac88) 统一 launcher profile、managed commands 走 login shell（2026-04-12/13）。
- [`52e1102`](https://github.com/yunsii/wezterm-config/commit/52e1102) `docs: add AI workspace sharing presentation outline`（2026-04-07）—— 这份 outline 是"我开始意识到这是一个平台而不是配置"的时间戳。

### 这一步解决的

- 有了工作区、worktree-task、贴图、命令面板、Agent launcher 这些**可组合的平台能力**。
- 多项目并行有了基础设施。

### 这一步留下的问题

- 宿主动作（VS Code 聚焦、Chrome 调起、剪贴板）还是一堆 PowerShell 脚本，启动慢、抖。
  - 比如按一下 Alt+O 去聚焦 VS Code，每次都要冷启一个 `powershell.exe`，几百毫秒到一秒才响应，连续按几下还会互相打架；剪贴板脚本偶发抖动，一次粘贴失败就得重来。
- Agent 的**真实状态**（正在跑 / 等我输入 / 跑完了 / 卡住了）对平台是不可见的；这是 v5 要解决的那根刺。
  - 比如我同时让四个 Agent 分头跑，想知道哪个已经跑完在等我答复，只能一个个切 pane 扫屏 —— 切过去才发现它十分钟前就停在"是否继续？"这一步。

---

## v5 — Native Helper + Hook 驱动

> 时间：`2026-04-18` 起至今；分两个子阶段。对应 [v1.0 里程碑](./personal-terminal-platform-v1.0.md) 及其之后。

### 子阶段 A：Native Helper（2026-04-18 → 2026-04-19）

Windows 侧从"每次调用都起一次 PowerShell"升级为**长期存活的 C# helper + IPC**。

关键 commit：

- [`1c62402`](https://github.com/yunsii/wezterm-config/commit/1c62402) `feat(alt-o): unify vscode focus through windows helper`（2026-04-18）
- [`ad4009b`](https://github.com/yunsii/wezterm-config/commit/ad4009b) `feat(host): unify windows runtime automation host`（2026-04-18）
- [`204a92c`](https://github.com/yunsii/wezterm-config/commit/204a92c) `refactor(wezterm): pluginize host integrations`（2026-04-18）
- [`1327468`](https://github.com/yunsii/wezterm-config/commit/1327468) `feat(wezterm): migrate hybrid host flow to native helper`（2026-04-18）
- [`1b538da`](https://github.com/yunsii/wezterm-config/commit/1b538da) `refactor(wezterm): finish rpc-only host helper flow`（2026-04-18）
- [`10e7b7a`](https://github.com/yunsii/wezterm-config/commit/10e7b7a) `fix(wezterm): finalize native host helper clipboard flow`（2026-04-19）
- [`bab5040`](https://github.com/yunsii/wezterm-config/commit/bab5040) `feat(wezterm): version synced runtime releases`（2026-04-18）—— runtime 开始有版本语义。
- [`e79ae01`](https://github.com/yunsii/wezterm-config/commit/e79ae01) `feat(scripts): add host helper release fallback`（2026-04-19）—— 无 dotnet 环境走 release fallback。
- [`299f63c`](https://github.com/yunsii/wezterm-config/commit/299f63c) `docs: add personal terminal platform v1.0 milestone`（2026-04-19）—— 把这次跃迁钉下来。

**这一步的本质**：宿主能力（VS Code 打开 / Chrome 调起 / 剪贴板 / 通知）不再是脚本堆，而是走 `helperctl → IPC → helper-manager.exe` 的**统一请求路径**，并且这个 helper **可构建、可发布、可升级、可回退**。

### 子阶段 B：Agent Attention Pipeline（2026-04-21 起）

平台开始**消费 Agent CLI 的 hook 事件**，主动把任务状态推给人 —— 而不是等人去巡检。

关键 commit：

- [`b903c23`](https://github.com/yunsii/wezterm-config/commit/b903c23) `feat(tmux): refresh status line from shell prompt hook`（2026-04-21）—— 状态栏开始依赖 shell prompt hook；为后续事件驱动铺路。
- [`ce60661`](https://github.com/yunsii/wezterm-config/commit/ce60661) `feat(attention): add agent-attention pipeline`（2026-04-21）—— **核心提交**，新增 `scripts/claude-hooks/emit-agent-status.sh`、`wezterm-x/lua/attention.lua`、`scripts/runtime/attention-*`，打通 `Agent CLI hook → 脚本 emit → attention state → WezTerm 状态渲染 → Alt+/ 跳转` 整条链路。
- [`9f3d1b1`](https://github.com/yunsii/wezterm-config/commit/9f3d1b1) `feat(attention): surface tmux pane in Alt+/ prefix`（2026-04-21）—— 定位到具体 pane。
- [`f2eac78`](https://github.com/yunsii/wezterm-config/commit/f2eac78) `feat(attention): make waiting reflect real blocked state`（2026-04-22）—— 把"等待"从超时猜测换成真实阻塞信号。
- [`f070193`](https://github.com/yunsii/wezterm-config/commit/f070193) `feat(attention): auto-clear done when its tmux pane is focused`（2026-04-22）
- [`a42599f`](https://github.com/yunsii/wezterm-config/commit/a42599f) `feat(attention): self-clean idle state, done entries, and stale rows`（2026-04-22）
- [`718e026`](https://github.com/yunsii/wezterm-config/commit/718e026) `feat(attention): add running state with tick-driven refresh and zero-delay focus-ack`（2026-04-23）—— running 态 + tick 刷新 + 零延迟 focus-ack。

**这一步的本质**：平台第一次拥有"Agent 端的事实视图" —— 哪个 pane 的 Agent 在跑、在等我、跑完了、卡死了，全部由 hook 事件推来，不再需要人去 pane 里扫。多任务并行的"人脑调度成本"被真正摊掉了。

### 这一步解决的

- 宿主动作链路统一、稳定、可发布。
- Agent 任务状态 **从靠人巡检 → 平台主动感知**。
- worktree-task + attention pipeline 合流后，**多任务并行从"开得起来" 变成"管得过来"**。

### 还留着的问题

- Codex 等其它 Agent CLI 的 hook 接入仍有空缺（参见 [`f607b43`](https://github.com/yunsii/wezterm-config/commit/f607b43) `docs(setup): document codex hook integration gap`）。
  - 比如现在用 Codex CLI 跑一个任务，attention pipeline 完全看不见它的 running / waiting 状态，只有 Claude Code 的 hook 是接好的。
- 非 Windows / 非 WSL 场景下，native helper 子系统是否值得保留还没有结论。
  - 比如如果搬到 macOS，`helper-manager.exe` 这层要整块换成别的实现（AppleScript? ObjC？），现在没方案。
- AI 协作本身的**纠偏与验证闭环**更多靠个人标准在维持，暂没形成项目级的 checklist。
  - 比如 Agent 跑完说"测试通过"，我得自己记得追问"这是不是真 smoke test，还是只 mock 了一层"；如果我哪天忘了追问，就会过一版看起来对、实则没验证的改动。

---

## 横向对照：每次跃迁发生了什么

| 跃迁 | 从 | 到 | 获得的新能力 |
|---|---|---|---|
| v0 → v1 | AI 做单点建议（补全 / 聊天） | AI 做任务级自主执行（跨文件读 / 改 / 跑 task） | 粒度从"单行"抬到"任务" |
| v1 → v2 | Agent 被编辑器进程模型约束 | Agent 活在 shell 里 | 长会话 / 多 pane / 后台任务都成了一等场景 |
| v2 → v3 | 把 WT 当终端 | 把 WezTerm 当终端 | 稳定性；埋下"配置可编程"的伏笔 |
| v3 → v4 | 终端仅是终端 | 终端是可编程平台 | 工作区 / worktree-task / 贴图 / 命令面板 / Agent launcher |
| v4 → v5 A | 宿主脚本堆 | Native helper + IPC | 统一控制面、可交付、可回退 |
| v4 → v5 B | 人巡检 Agent 状态 | 平台主动感知 | Hook 驱动的 attention pipeline |

每一次跃迁的共同模式是同一种：

> **AI 形态的一小步变化，都在揭露当前环境的一层抽象漏洞；把这层漏洞补上，环境就进化一格。**

---

## v5 上线之后：日常循环的真实形状

上面是演进叙事；这一节从**一天的实际日志切面**反推日常循环长什么样。数据来源是 WezTerm / runtime 两套日志 + `hotkey-usage.json` 计数器，单日窗口，具体项目与分支匿名化。

### 阶段 0 — 开工一次性铺开

- 启 WezTerm → `default` / `config` / `work` 三条 workspace 全开。
- `work` 下**多个项目 session 一批拉起**，全部在同一分钟开出来，说明有一个脚本化的早晨仪式。
- 一旦铺开，**一整天几乎不再新建 workspace** —— `workspace.switch-config` / `switch-work` / `cycle-next` 合计只有个位数次按键，workspace 切换绝大多数发生在预先定义好的那几条之间。

### 阶段 1 — 派活（loop 起点）

- 在某条 pane 打开 Agent CLI，给一个具体任务。
- 任务下发后，该 pane 的 attention 状态翻为 `running`，右侧状态栏 `⟳` 计数 +1。
- 这一阶段**没有固定快捷键**：派活就是在 pane 里打字；平台侧的信号是 `attention` 日志多一条 `running`。

### 阶段 2 — 被动等待（日常时间占比最大的阶段）

注意力不在某一条 pane 上，而在**全局 attention 总览**上：

| 入口 | 快捷键 | 一天按键次数（取样日） |
|---|---|---:|
| 打开 pending-task overlay 扫全局 | `Alt+/` | 78 |
| 跳到下一个 `done` | `Alt+.` | 62 |
| 跳到下一个 `waiting` | `Alt+,` | 33 |
| **attention 三入口合计** | | **173** |

这 173 次压过当天任何单一 workspace / tab / clipboard 动作。意味着：

> loop 不是由"我定时切 pane 去看 Agent"驱动的，而是由 attention pipeline 在状态翻转时把事件推给我，我按快捷键跳过去。

### 阶段 3 — 处理一个需要我介入的 pane

跳过去之后的典型动作（同一取样日）：

- **审视 diff / 核逻辑**：`Alt+v` 把当前目录丢给 VS Code，约 20+ 次。
- **调试前端**：`Alt+b` 拉 Chrome 调试 profile，约 20+ 次；与 `Alt+v` 几乎一比一 —— 编辑器和浏览器是并列的验证面，不是主副关系。
- **项目内细粒度导航**：`Alt+n` / `Alt+Shift+N` / `Alt+1..9` 合计数十次，**tab 层是单 session 内的主导航手段**。
- **几乎不运行时拆 pane**：split 全天个位数次，rotate 十几次 —— 用的是**早晨铺好的布局，运行时只轮转**。
- **收尾**：`Alt+Shift+X` 关当前 workspace 视图、`Alt+d` 回默认，作为 loop 的"回到起点"动作。

### 阶段 4 — 回到阶段 1 或继续停在阶段 2

从这里有两条路：

1. **给同一个 pane 派下一步** → 回到阶段 1。
2. **让 attention pipeline 继续代我巡检** → 停在阶段 2，在别的 workspace 做别的事，等下一个 `running → waiting / done` 翻转。

### loop 的几何形状

一天大概是这个节奏（小时分布来自日志事件计数）：

```
08:00 铺开  →  上午高峰 10-11  →  12:00 午休明显下跌  →  下午再起 13-15  →  16-17 次高峰  →  收尾
                    ↑                                          ↑
          loop 循环 4-5 次 / 小时级                    loop 循环 5-8 次 / 小时级
```

一次完整 loop 的典型时长在**数分钟到十几分钟**级（由 attention 条目的 30 分钟 TTL 反推，以及 `Alt+.` 当日 62 次 / 工作日约 8 小时 ≈ 平均每 8 分钟一次 done 跳转）。

### 一句话压缩

> **我今天的工作方式不是"我去轮询 Agent"，而是"Agent 通过 attention pipeline 轮询我"**。主循环是：早上一次铺开 → `Alt+/` 看总览 → `Alt+.` / `Alt+,` 跳到需要处理的 pane → `Alt+v` / `Alt+b` 借 VS Code 和 Chrome 做真实验证 → 回 pane 继续 —— 平均一天几十次循环，由 hook 驱动、由 tab 层做细粒度导航、pane 层近乎冻结。

---

## 贯穿始终的两条设计原则

上面那段循环之所以长成那个形状，是因为背后压了两条硬约束。它们不是某一个 commit 的事，而是**每次添加新交互时都必须满足的前置条件**，在 v4 后半段收紧、在 v5 兑现。

### 原则一 —— 尽可能无鼠标

- **项目级硬规则**：[`AGENTS.md`](../../AGENTS.md) 明文规定 —— 每个新增 / 改动的交互**必须**有键盘路径，鼠标绑定只能做 fallback（跨 pane 选文本、快速 pane 聚焦之类）。这条规则是在 [`d80b42c`](https://github.com/yunsii/wezterm-config/commit/d80b42c) `feat: codify keyboard-first UX and close mouse-only gaps` 里上升为硬规则的。
- **仓库里的 `mouse_bindings` 极简到只有两条**：`Ctrl+LeftClick` 打开链接、`Ctrl+LeftDown` 为 Nop（避免误点触发默认文本选择）。不绑中键粘贴、不绑右键菜单、不绑鼠标拖拽 —— 因为所有这些都要求我把手从键盘挪开。
- **命令面板 + 快捷键双通道**：[`wezterm-x/commands/manifest.json`](../../wezterm-x/commands/manifest.json) 里每个动作既注册 hotkey 又挂在 `Ctrl+Shift+P` palette 上；hotkey 记不住就 fuzzy 搜，整条流都不碰鼠标。刚补的三条 `attention.*`（见"v5 上线之后"一节上游的修复）也是按这条规则补进 manifest 的。
- **今日数据佐证**：hotkey 计数器前十名 **全部是纯键盘动作**（attention overlay / jump-done / workspace close / workspace default / tab.next / jump-waiting / ...）；WezTerm 日志里 `mouse_bindings` 类别事件数为 0。

### 原则二 —— 无头浏览器验证流程

- `Alt+b` 默认把 Chrome debug profile 启成 **headless**（[`6a6cd30`](https://github.com/yunsii/wezterm-config/commit/6a6cd30) `feat(chrome-debug): headless Alt+b + visible Alt+Shift+b`）；**显示窗口必须显式用 `Alt+Shift+b`**。默认态就是不占屏幕。
- 启动路径走 v5 子阶段 A 搭好的 Windows native helper IPC，带一套加固旗标：`--remote-allow-origins=http://localhost:<port>`（修 Chrome 111+ DevTools 白屏）、`--disable-extensions`、`--no-first-run`、`--no-default-browser-check`、`--headless=new`、`--window-size=1920,1080`（headless 默认是 800×600，MCP 截图和视口相关抓取会走样）。可见态和 headless 如果端口冲突，helper 会先终结旧进程树释放 Chrome 的 singleton lock，再切新模式 —— 模式切换本身也不抢焦点。
- **这对 Agent 协作是一等大事**：Agent 通过 MCP 的 `--browser-url=http://localhost:<port>` 直接连上这个实例，自主跑 DOM 调试 / 截图 / 端到端验证，**既不抢我的焦点、也不在任务栏闪、更不会把窗口推到前台**。
- **状态栏看得见**：右侧有一段固定宽度的 badge（`CDP·H·9222` headless / `CDP·V·9222` visible / `CDP·-·<port>` idle），三种状态占同样字符数，bar 宽度不抖。
- **对比老路径**：以前的验证闭环是"我手工启 Chrome → 切到它 → Agent 等我贴截图"；现在是"Agent 通过 browser-url 自己接管 → 我完全不用切焦点"。v5 里那句"真实验证闭环"里的"真实"——很大程度是靠这条 headless 流兑现的。

### 两条原则合流的系统结果

- 人这一侧：**完全键盘驱动** —— tab 层导航 + attention overlay + workspace 切换，手不离键盘。
- Agent 这一侧：**完全 headless 驱动** —— hook 事件 + native helper + headless Chrome，不抢 GUI 焦点。
- 合起来，**人与 Agent 的交互面都不依赖"可见 GUI 焦点"**。焦点抢夺、窗口跳跃、任务栏闪烁 —— 这些在 GUI 密集工作流里非常高频的噪音，在这套流里几乎不出现。这是 v5 能把多任务并行从"开得起来"压到"管得过来"的结构性前提。

---

## 下一步（方向，不是承诺）

- **把 attention pipeline 的事件源从单一 Agent CLI 扩到多种**，让平台对 Agent 生态的感知层是厂商无关的。
- **把控制面的"契约"文档化**，不只是 AGENTS 指南，而是 agent 可发现、可调用的 capability manifest。
- **真正压一次跨机器场景**：非 Windows / 非 WSL 下哪些层应该保留、哪些退化成 no-op。
- **把"AI 快速推进 + 人纠偏 + 真实验证"从工作习惯升级成项目级 checklist**，减少每次依赖个人标准。

---

## 一句话结尾

> 从 v0 到 v5，表面上换的是编辑器、终端、平台架构；实际上换的是 **AI 在我工作流里的位置** —— 从光标处的单点建议者，到编辑器里的任务执行者，到终端里的一等公民，再到一个有真实状态、被平台主动感知、被 hook 驱动的协作对象。
