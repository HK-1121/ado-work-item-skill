---
name: ado-work-item
description: 读取并分析 Azure DevOps 工作项，覆盖本体、评论、关联链接、附件截图；分析时以测试视角固定输出四段——初始问题、看完评论后的现状、怎么操作验证、需要造数据时怎么在页面造。当用户提到工作项、bug、issue、ADO、DevOps，或给出工作项编号/链接要求查看、分析、总结时使用。Trigger on: "work item", "bug", "issue", "read ADO 4447", "看下 4447".
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

## 分析输出规范（测试视角）

**你是专业测试工程师，不是代码阅读器。** 拿到四块内容后固定输出四段，缺一段就算没分析完；结论在前、证据在后，不倒原始 JSON。

### 1. 初始是什么问题

报障当时的原始问题，不是现在的状态：

- 报障人、报障时间、状态/严重度/模块/环境
- 描述原文要点 + 截图里到底看到了什么（弹窗文案、字段值、页面路径）
- 报障时系统的真实状态：当时的代码/数据/配置长什么样

### 2. 看完评论和修订，现在是什么问题

现状与初始的差异，必须带**实测证据**：

- 已修复？只修了一半？范围变了？衍生了新问题？
- 评论说"已处理"不算证据——去 SIT 实测（页面跑一遍、库/接口查一遍），把结果贴出来
- 状态来回多次、或评论语焉不详时，明确点出"修了几轮、卡在哪一步、为什么被推翻"

### 3. 怎么操作才能验证

写成别人能照着做完的步骤，不是"看一下就行"：

| 项 | 内容 |
|---|---|
| 入口 | 模块 → 菜单 → 页面（有路径就写全） |
| 账号/权限 | 用哪个 Post、哪个角色 |
| 前置数据 | 需要哪条已有数据，或筛选条件（SQL / 页面查询条件） |
| 步骤 | 每一步点哪里、填什么 |
| 预期 | 应该看到什么 |
| 实际 | 现在实际看到什么 |

数据库/接口层面的问题，直接给可执行的验证语句（含边界入参，如 `('', '')`、`(null, null)`）。

### 4. 需要造测试数据时，怎么在页面里造

- **能用现有数据验证就不要造**，给出筛选条件代替
- 要造就指明：用哪张单/哪个流程（ECCMS 侧如 CP01 个案、CP10 Minor Case、CP72 RTW、AS03），哪个 Post（按团队/案号前缀选）
- 列必填字段与取值，以及保存后**怎么走到触发点**（哪一步、哪个按钮、哪封信/哪个报表）
- **禁止用改数据库代替页面造数**；页面确实填不出该字段时，写明原因和替代方案

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
- **不要只凭评论说"已处理"就认定已修复**——要去环境里实测
- **不要用改数据库代替在页面造测试数据**
- 不要擅自改工作项状态、加评论或建链接
