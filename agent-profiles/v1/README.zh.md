# Agent Profile v1（中文说明）

Source of truth:
[README.md](./README.md)

本文档是 `agent-profiles/v1/README.md` 的中文对照说明。
若中英文存在表述差异，以英文版为准。

## 用途

这套 profile 是一个带版本号的用户级 agent 配置包。
它定义跨仓库可复用的个人工作规则，包括：

- 执行方式
- 验证纪律
- 重构策略
- 自动化边界
- 文档组织
- 汇报方式

它被托管在仓库中，便于版本化和复用，但本身不绑定某一个具体项目。

## 结构

- [README.md](./README.md)：英文版总说明，也是说明层的真实来源
- [en/AGENTS.md](./en/AGENTS.md)：英文主入口
- [zh/AGENTS.md](./zh/AGENTS.md)：中文对照入口

`en/` 和 `zh/` 下的主题文件一一镜像：

- [en/validation.md](./en/validation.md)
- [en/implementation.md](./en/implementation.md)
- [en/refactor.md](./en/refactor.md)
- [en/automation.md](./en/automation.md)
- [en/documentation.md](./en/documentation.md)
- [en/reporting.md](./en/reporting.md)
- [en/preferences.md](./en/preferences.md)

规则层面以 `en/` 为准。
`zh/` 主要用于阅读、翻译、对照和维护。

## 如何接入

默认入口：

- [en/AGENTS.md](./en/AGENTS.md)

推荐兼容映射：

- `AGENTS.md -> agent-profiles/v1/en/AGENTS.md`
- `CLAUDE.md -> agent-profiles/v1/en/AGENTS.md`

建议的用户级 Claude 接入：

- `~/.claude/CLAUDE.md -> /absolute/path/to/repo/agent-profiles/v1/en/AGENTS.md`

优先采用单一真实来源配合符号链接的兼容入口。
避免把同样内容复制到多个文件。

## 如何加载

1. 先读 [en/AGENTS.md](./en/AGENTS.md)
2. 只加载当前任务下一份相关的主题文档
3. 不要预加载整个 profile
4. 只有在需要双语阅读、翻译或对照时才使用 `zh/`

## 链接约定

文档导航使用 Markdown 链接。
符号链接、兼容入口、别名映射使用 `source -> target` 记法。

例如：

- [en/AGENTS.md](./en/AGENTS.md)
- `AGENTS.md -> agent-profiles/v1/en/AGENTS.md`

## 版本策略

- `v1` 是当前稳定版本
- 非破坏性细化继续在 `v1` 内演进
- 结构性重设计应发布为 `v2`

## 维护规则

- `en/` 和 `zh/` 保持文件名镜像
- 先改英文，再同步中文
- 主入口保持短小
- 详细规则下沉到主题文档
- 必须稳定执行的规则，优先做成自动化，而不是只写在文档里
