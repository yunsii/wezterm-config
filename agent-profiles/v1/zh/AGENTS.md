# User-Level AGENTS（中文对照）

Source of truth:
[../en/AGENTS.md](../en/AGENTS.md)

本文档是英文版用户级 agent profile 的中文对照参考。
若中英文存在表述差异，以英文版为准。
默认 agent 入口应指向英文版，而不是中文版。

先读英文版入口。
按下方 Task Routing 表只加载当前任务下一份相关主题文档。
不要预加载整个 profile。

## 范围与优先级

这是用户级指导，不是项目级指导。

它用于跨仓库、跨语言、跨工具都相对稳定的默认规则。
如果存在项目级文档，应与本文件组合使用。
当项目约束与用户级默认值冲突时，以项目约束为准。

## 默认工作模型

默认循环如下：

1. 先理解现有系统，再改动
2. 找到最窄的归属区域
3. 做能闭环任务的最小改动
4. 优先自动验证
5. 汇报改动内容、验证方式和剩余不确定性

无阻塞时持续推进。
完整的人工介入升级条件见 [validation.md](./validation.md)。

## Task Routing

先读本文件，再打开匹配的主题文件。
仅在当前文件明确指向，或任务跨越边界时，才加载更多主题文件。

- 测试策略、完成标准、人工验证阈值 → [validation.md](./validation.md)
- 结构、抽象、模块边界、可靠性、性能 → [implementation.md](./implementation.md)
- 重组既有代码或替换子系统 → [refactor.md](./refactor.md)
- 规则归属于文档、脚本、hook、skill 还是 plugin → [automation.md](./automation.md)
- 工具选择、调用顺序、批量化 → [tool-use.md](./tool-use.md)
- 创建、拆分或维护面向 agent 的文档 → [documentation.md](./documentation.md)
- 宿主侧副作用（剪贴板、聚焦应用、打开浏览器、本地通知等）→ [platform-actions.md](./platform-actions.md)
- commit、分支、合并、push、PR/MR → [vcs.md](./vcs.md)
- 最终响应和进度更新 → [reporting.md](./reporting.md)
- 多个合理方案之间的打破平局 → [preferences.md](./preferences.md)

## 默认姿态

每个主题一句话，便于入口扫读。
完整规则在对应的主题文件中。

- 验证：以最轻有效路径自证，不要把用户当作主要测试者
- 重构：先理解再改结构；重构与行为变化分离
- 实现：优先简单、显式、可观察、可回退；避免投机性抽象
- 自动化：稳定性重要时，优先把规则做成实现而不是停留在说明层
- 工具使用：专用工具优先于 shell；独立调用批量并行；只读 shell 合并；写入前先读
- 文档：分层且精简；每条规则只有一个真实来源
- 宿主动作：窄、显式、可回退；secret、破坏性或难回退的动作先确认
- 版本控制：永不自动 commit / push / 跳 hook / 强推 main；历史归用户所有
- 汇报：说明改了什么、如何验证、还剩哪些不确定
- 偏好：仅当正确性、安全性或本地约定没有先行决定时，才按偏好打破平局
- 语言：默认用简体中文回复；代码、标识符、commit message、现存英文文档保持英文。完整规则见 [preferences.md](./preferences.md)
