---
name: ado-work-item
description: 读取并分析 Azure DevOps 工作项，覆盖本体、评论、关联链接、附件截图。当用户提到工作项、bug、issue、ADO、DevOps，或给出工作项编号/链接要求查看、分析、总结时使用。Trigger on: "work item", "bug", "issue", "read ADO 4447", "看下 4447".
metadata:
  origin: ado-work-item-skill
---

# Azure DevOps 工作项读取与分析

## 能力边界

**只做两件事：读工作项、分析工作项。** 写操作（改状态、加评论、关联链接、创建）不在本 skill 范围内；用户明确要求时必须先确认再执行。

「读」的完整范围是四块，缺一不可：

1. **本体** —— 标题、类型、状态、原因、区域、迭代、严重度、模块、环境、时间字段、描述正文
2. **评论** —— 全部评论及其作者与时间
3. **关联链接** —— 父子项、相关项、提交、PR、build
4. **附件** —— 尤其是截图，bug 报告的关键信息通常只在图里

## 前置条件

需要 `azure-devops` MCP（微软官方 `@azure-devops/mcp`）已配置，并用 **个人账号** 的 PAT 认证。

一次性安装见 `README.md`；已经装过就跳过。

## 读取流程

### 输入解析

按这个优先级确定组织和项目，**不要猜**：

1. 用户给了 URL → 用 URL 里的 org 和 project
2. 用户点名了组织或项目 → 用用户说的
3. 否则读同目录的 `SKILL.local.md`（安装脚本生成的本机文件，不入库，形如 `organization: xxx` / `project: yyy`）
4. 都没有 → 问用户，问清楚再读

组织名只影响 MCP 服务连哪个 org；项目名在每次调用时传。

```
1. 本体 + 关联：wit_work_item  action=get  id=<ID>  project="<项目>"  expand="All"
   - expand="All" 才会带上 relations（关联项、提交、PR、附件）
   - expand 与 fields 互斥：只要特定字段时才用 fields
2. 评论：wit_work_item  action=list_comments  workItemId=<ID>  project="<项目>"
3. 历史（需要时）：action=list_revisions
4. 附件：从 relations 里找 AttachedFile（URL 形如 .../_apis/wit/attachments/<GUID>），
   用 wit_work_item_attachment  attachmentId=<GUID>  savePath="tmp" 下载后看图
```

Codex 里工具名带前缀：`mcp__azure_devops__wit_work_item`、`mcp__azure_devops__wit_work_item_attachment`。Claude Code 里是 `mcp__azure-devops__wit_work_item`。

批量查：`action=get_batch`，`ids=[...]`。查「分配给我的」：`action=my`。

## 分析框架

拿到四块内容后，按这个结构输出，**结论在前，证据在后**：

- **问题本身**：一句话说清现象；附状态、严重度、模块、环境、复现数据（如案件号）
- **评论**：谁、什么时候、说了什么；有分歧或结论时点名
- **链接**：提交/PR/关联工作项，指出它说明了什么
- **附件**：截图里能看到什么（弹窗文案、字段值、页面路径）
- **判断**：现象与期望的差距在哪、可能的成因、证据是否充分
- **待确认**：缺什么信息、需要谁回答

不要把原始 JSON 倒给用户，说人话。

## 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `TF400813: The user '<GUID>' is not authorized` | 认证用了企业账号，它在组织里是另一个身份 | 用个人账号的 PAT，重跑 `scripts/set-ado-pat.ps1` |
| `PERSONAL_ACCESS_TOKEN is not set` | 配置里没有 env 表 | 跑 `scripts/set-ado-pat.ps1`：默认从剪贴板读 PAT，写完会联网校验 |
| MCP `connection closed: initialize response` | 服务用 `npx` 现拉包时写不了 npm 缓存 | 预装到固定目录，配置里直接用 node 指向入口（见 README） |
| 附件返回一长串 base64 | 没给 `savePath` | 加 `savePath="tmp"` 落盘再看 |

## 不要做的事

- 不要因为 MCP 不可用就直接换浏览器读——先报错给用户，让他决定
- 不要跳过评论和附件就下结论
- 不要擅自改工作项状态、加评论或建链接
