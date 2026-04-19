---
title: 我的 AI 工作环境分享
subtitle: WezTerm + tmux + Git Worktree + AI CLI 的一体化终端开发环境
---

# 我的 AI 工作环境分享

> 演示大纲 — 面向技术同事

---

## 一、为什么需要一套「管理型」终端环境

- 日常开发中反复切项目、开终端、敲命令的隐性成本
- AI 编码助手（Claude Code / Codex）兴起后，终端成为主战场
- 目标：**一套键盘驱动的环境，把项目管理、Git 分支、AI 对话都收进同一个窗口**

---

## 二、整体架构一览

```
┌─────────────────────────────────────────────────┐
│  WezTerm（终端模拟器 / UI 宿主）                   │
│  ┌───────────┬───────────┬───────────┐          │
│  │ default   │  work     │  config   │ ← 工作区  │
│  └───────────┴───────────┴───────────┘          │
│        │            │            │               │
│        ▼            ▼            ▼               │
│      原生终端    tmux 会话    tmux 会话           │
│                 ┌──────────────────┐             │
│                 │ 窗口1: 主worktree │             │
│                 │ 窗口2: task/xxx  │             │
│                 │ 窗口3: task/yyy  │             │
│                 └──────────────────┘             │
│                        │                        │
│                 Git Worktree 映射                 │
│                 每个任务 = 独立分支 + 独立目录       │
└─────────────────────────────────────────────────┘
```

### 关键组件

| 层级 | 工具 | 职责 |
|------|------|------|
| UI 层 | WezTerm | 终端渲染、工作区管理、快捷键分发 |
| 会话层 | tmux | 多窗口/多面板、状态栏、会话持久化 |
| 版本控制 | Git Worktree | 并行任务隔离，每个任务独立目录和分支 |
| AI 层 | Codex / Claude Code | 在终端内直接对话、生成代码、执行任务 |
| 追踪层 | WakaTime | 编码时间自动统计，状态栏实时展示 |

### 支持的运行模式

- **hybrid-wsl**：Windows 桌面 WezTerm + WSL 内 tmux 运行时
- **posix-local**：Linux / macOS 原生运行

---

## 三、工作区模型

### 三个核心工作区

| 工作区 | 快捷键 | 用途 |
|--------|--------|------|
| `default` | `Alt+d` | WezTerm 原生终端，临时操作 |
| `work` | `Alt+w` | 日常项目开发，tmux 管理多个项目标签页 |
| `config` | `Alt+c` | 终端配置本身的维护 |

- `Alt+p`：轮换切换所有工作区
- `Alt+Shift+x`：关闭当前非默认工作区

### 工作区内部结构

- 每个管理型工作区 = 一个 tmux 会话
- 每个项目 = 一个 tmux 窗口（标签页标题自动取项目目录名）
- 每个 Git Worktree = 一个 tmux 窗口，按需创建

---

## 四、键盘驱动的工作流

### 项目导航

| 快捷键 | 功能 |
|--------|------|
| `Alt+w` | 打开/切换到工作工作区 |
| `Alt+v` | 在 VS Code 中打开当前 worktree 根目录 |
| `Alt+b` | 启动 Chrome 调试浏览器 |
| `Ctrl+k v` / `Ctrl+k h` | 垂直/水平分屏 |

### Git Worktree 操作

| 快捷键 | 功能 |
|--------|------|
| `Alt+g` | 弹出 worktree 选择器（当前仓库族） |
| `Alt+Shift+g` | 循环切换下一个 worktree |

### 命令面板

| 快捷键 | 功能 |
|--------|------|
| `Ctrl+Shift+P` | 弹出 tmux 命令面板（仓库共享 + 机器本地命令） |

### 智能复制粘贴

- `Shift+拖拽`：tmux 面板内选择文本
- `Super+拖拽`：跨面板的 WezTerm 级文本选择
- `Ctrl+v`：智能粘贴（hybrid-wsl 下支持剪贴板图片缓存）

---

## 五、tmux 状态栏 — 实时上下文感知

```
 ┌─────────────────────────────────────────────────────┐
 │ repo-name  main  +3 ~2 -1  ^0 =0  Node v20.11.0    │  ← 第一行
 │ linked:2 · primary                                   │  ← 第二行
 │ WakaTime: 3h 42m                                     │  ← 第三行
 └─────────────────────────────────────────────────────┘
```

### 展示信息

- **仓库名** + **分支名** + **Git 变更统计**（增/改/删）
- **远程同步状态**：`^N` 领先 / `vN` 落后 / `=0` 已同步 / `x0` 无上游
- **Worktree 角色**：`primary` 或 `linked`，以及关联 worktree 数量
- **Node.js 版本**（支持 nvm 回退）
- **WakaTime 编码时间**（缓存 60 秒，异步刷新）

### 刷新策略

- 混合机制：焦点变更 → 后台刷新 + 30 秒兜底轮询
- 每个段位保持稳定占位，数据不可用时显示占位符，避免状态栏闪烁

---

## 六、AI 工作流集成（重点）

### 6.1 worktree-task：AI 任务的完整生命周期

```
  用户提出需求
       │
       ▼
  ┌──────────────┐
  │ worktree-task │
  │    launch     │
  └──────┬───────┘
         │
         ├── 创建 Git Worktree（独立分支 task/xxx）
         ├── 在 tmux 中打开新窗口
         └── 启动 AI CLI（Codex / Claude Code）并注入任务 prompt
                │
                ▼
         AI 在隔离环境中编码
                │
                ▼
  ┌──────────────┐
  │ worktree-task │
  │   reclaim     │
  └──────┬───────┘
         │
         ├── 清理 tmux 窗口
         ├── 移除 worktree
         └── 已合并的分支自动删除，未合并的保留
```

### 核心理念

- **一个任务 = 一个分支 + 一个目录 + 一个 AI 会话**
- AI 在完全隔离的环境中工作，不影响主 worktree
- 多个 AI 任务可以并行进行，互不干扰

### 配置示例

```bash
# config/worktree-task.env
WT_PROVIDER=tmux-agent          # 使用 tmux 作为任务载体
WT_PROVIDER_AGENT_COMMAND=claude  # 默认 AI CLI
WT_POLICY_BRANCH_PREFIX=task/    # 分支前缀
WT_POLICY_RECLAIM_DIRTY=refuse   # 未提交的更改拒绝回收
```

### 6.2 wezterm-runtime-sync：配置即代码

- 所有配置集中在 Git 仓库中管理
- 通过 sync skill 一键部署到目标机器
- WezTerm 自动热重载，改完即生效

### 6.3 Claude Code Skills 扩展

- 以独立 skill 形式封装可复用的自动化操作
- 每个 skill 有完整的文档（SKILL.md）+ 脚本 + 代理配置
- 通过 Claude Code 或 Codex 自然语言调用

---

## 七、日常工作流演示路线

> 建议现场 Demo 的操作顺序

1. **启动**：打开 WezTerm → `Alt+w` 进入工作工作区 → 展示已管理的项目标签
2. **状态栏**：切换几个 tmux 窗口，展示状态栏实时更新（仓库、分支、变更数）
3. **Worktree 切换**：`Alt+g` 打开选择器 → 选择一个 linked worktree → 观察状态栏变化
4. **AI 任务启动**：用 worktree-task 创建一个新任务 → 观察新 tmux 窗口自动打开 + AI CLI 启动
5. **并行工作**：在主 worktree 继续开发，同时 AI 在另一个窗口独立工作
6. **任务回收**：worktree-task reclaim → 展示清理过程
7. **命令面板**：`Ctrl+Shift+P` 打开命令面板 → 展示自定义命令
8. **编辑器集成**：`Alt+v` 从当前 worktree 直接打开 VS Code

---

## 八、配置分层设计

```
wezterm-config/               ← Git 仓库（source of truth）
├── wezterm.lua               ← WezTerm 入口
├── tmux.conf                 ← tmux 配置
├── wezterm-x/
│   ├── lua/                  ← WezTerm Lua 运行时模块
│   ├── workspaces.lua        ← 公开的工作区基线定义
│   ├── local.example/        ← 配置模板（提交到 Git）
│   └── local/                ← 私有配置（gitignored，不提交）
│       ├── constants.lua     ← 运行模式、Shell、主题
│       ├── shared.env        ← WakaTime API Key 等
│       ├── workspaces.lua    ← 私有项目目录
│       └── command-panel.sh  ← 本机命令面板扩展
├── scripts/runtime/          ← tmux 状态栏、worktree 操作脚本
├── skills/                   ← Claude Code / Codex Skills
│   ├── wezterm-runtime-sync/ ← 运行时同步
│   └── worktree-task/        ← 任务 worktree 管理
└── docs/                     ← 主题化项目文档
```

### 设计原则

- **公开 vs 私有分离**：模板提交到 Git，敏感配置 gitignored
- **配置即代码**：所有变更可追溯、可回滚
- **sync 部署**：修改仓库 → 运行 sync → WezTerm 热重载

---

## 九、要点总结

| 亮点 | 说明 |
|------|------|
| 键盘驱动 | 几乎所有操作都有快捷键，减少鼠标依赖 |
| 任务隔离 | Git Worktree 实现真正的并行任务隔离 |
| AI 原生集成 | AI CLI 作为一等公民融入工作流 |
| 上下文感知 | 状态栏实时展示仓库/分支/变更/worktree 状态 |
| 配置即代码 | 整套环境可版本控制、可复现 |
| 跨平台 | hybrid-wsl 和 posix-local 双模式支持 |

---

## 十、Q&A

- 仓库地址：（填入你的仓库链接）
- 相关工具：[WezTerm](https://wezfurlong.org/wezterm/) / [tmux](https://github.com/tmux/tmux) / [Claude Code](https://claude.ai/claude-code) / [Codex](https://github.com/openai/codex)
