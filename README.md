# ado-work-item

在 AI 编码助手（Codex / Claude Code）里读取并分析 Azure DevOps 工作项：本体、评论、关联链接、附件截图。

- 组织：`LD-23175`
- 项目：`LD-ECCMS`
- 工作项地址形如 `https://dev.azure.com/LD-23175/LD-ECCMS/_workitems/edit/<ID>`

## 为什么是 skill 而不是插件

这个能力由两块组成：微软官方的 MCP 服务（负责取数）+ 一套固定的读取与分析流程（负责判断）。MCP 每人一份、每客户端配一次，且要用 **自己的** PAT，插件代劳不了凭据；流程才是真正需要复用的部分。所以本体做成 skill，插件以后如果需要一键安装再包一层即可，内容不用重写。

## 安装

### 1. 装 MCP 服务

Codex（写入 `~/.codex/config.toml`）：

```toml
[mcp_servers.azure-devops]
command = "node"
args = ["<预装目录>\\node_modules\\@azure-devops\\mcp\\dist\\index.js", "LD-23175", "--domains", "core", "work", "work-items", "repositories", "--authentication", "pat"]
startup_timeout_sec = 60
```

Claude Code：

```bash
claude mcp add --transport stdio azure-devops -- npx -y @azure-devops/mcp LD-23175 --authentication pat
```

**别用 `npx` 直接起服务**（除非缓存里已经有包）：沙箱里写不了 npm 缓存，会以
`connection closed: initialize response` 失败。预装一次更稳：

```powershell
npm install --prefix "$env:USERPROFILE\.codex\ado-mcp" @azure-devops/mcp --omit=dev --no-audit --no-fund
```

### 2. 写入 PAT

在 **个人账号** 登录 `dev.azure.com/LD-23175` 的状态下生成 PAT（Scopes：Work Items = Read & write，Project and Team = Read，需要看代码再加 Code = Read），然后：

```powershell
pwsh -File scripts\setup-ado-pat.ps1
```

贴进去回车即可（不回显）。脚本把 token 编码成 `base64(":" + PAT)` 写进
`[mcp_servers.azure-devops.env]` 的 `PERSONAL_ACCESS_TOKEN`，重复执行只覆盖不追加。

重启 AI 客户端后生效。

### 3. 挂 skill

把本仓库克隆到一个固定位置，再挂进 skills 目录（Windows 用 junction，不要复制文件，避免两份不同步）：

```powershell
git clone https://github.com/<owner>/ado-work-item-skill.git D:\harness\ado-work-item-skill
New-Item -ItemType Junction -Path "<工作区>\.agents\skills\ado-work-item" -Target "D:\harness\ado-work-item-skill"
```

## 用法

跟助手说「读工作项 4447」，或直接贴 URL。skill 会依次取本体、评论、关联链接、附件，然后给出结论和证据。

## 验证

```text
读工作项 4447
```

返回内容里应包含状态、严重度、描述、评论数、关联项，以及附件截图的解读。若报 `TF400813`，说明 PAT 是拿企业账号建的——同一邮箱在微软里是两个身份，换个人账号重建。

## 目录

```
SKILL.md                  给助手看的流程与分析框架
README.md                 给人看的安装与排障
scripts/setup-ado-pat.ps1 写入 PAT
```
