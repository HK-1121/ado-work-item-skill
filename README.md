# ado-work-item

在 AI 编码助手（Codex / Claude Code）里读取并分析 Azure DevOps 工作项：**本体、评论、关联链接、附件截图**四块一起看，然后给出结论和证据。

边界是**只读 + 分析**。改状态、加评论、建链接不在能力范围内；真要写，也先人工确认。

## 这是什么

这个能力由两块组成：

- **取数**：微软官方的 MCP 服务 `@azure-devops/mcp`，负责跟 Azure DevOps 说话
- **判断**：一套固定的读取流程 + 分析框架，负责决定看什么、怎么看、怎么下结论

MCP 人人一份、每个客户端配一次，还得用**自己的** PAT；真正值得复用的只有后者。所以这个仓库做成 **skill**，将来若要一键安装再包一层插件，内容不用重写。

读的时候四块缺一不可：

1. **本体** —— 标题、类型、状态、原因、区域、迭代、严重度、模块、环境、时间字段、描述正文
2. **评论** —— 全部评论及其作者与时间
3. **关联链接** —— 父子项、相关项、提交、PR、build
4. **附件** —— 尤其截图；bug 的关键信息常常只在图里

分析输出固定这个顺序：问题现象 → 评论 → 链接 → 附件 → 判断 → 待确认。结论在前，证据在后，不倒原始 JSON。

适用场景：看某个 bug/issue 到底在说什么、追一条工作项的历史结论、判断某个问题是新系统还是老系统的问题、把一批工作项批量过一遍。

## 安装

先分清哪些是**每人不同的**、哪些是**公共的**：

| 谁提供 | 内容 |
|---|---|
| 每人不同 | 组织名、PAT、skill 挂载目录、客户端的配置文件位置 |
| 公共（本仓库已备好） | MCP 包与启动参数、配置文件结构、两个安装脚本、`SKILL.md` 的读取与分析流程、用法 |

支持的客户端：**Codex**（`~/.codex/config.toml`，脚本默认）与 **Claude Code**（见方式三最后一小节）。

### 方式一：AI 安装（推荐）

把下面这段**原样发给你的 AI**，剩下的它自己会做——它只需要问你两件事：组织名、skill 挂在哪。

```text
请帮我安装 ado-work-item skill。
仓库：https://github.com/HaydenSmith1121/ado-work-item-skill

按顺序做：
1. 先读仓库里的 README.md 和 SKILL.md，搞清楚这个 skill 做什么、要装什么。
2. 把仓库克隆到一个固定目录：先问我想放哪；我没意见就放在项目仓库之外的独立目录，别塞进我正在做的项目里。
3. 运行 scripts/install.ps1：
   - -Organization 用我给你的组织名（先问我一次）
   - -SkillsDir 用我要挂 skill 的目录（先问我一次）
   它会预装 @azure-devops/mcp、写 MCP 配置、把 skill 挂成链接；可以重复执行。
4. 装完告诉我，然后让我自己在终端跑一次 scripts/set-ado-pat.ps1 输入 PAT。
   不要让我把 PAT 贴进对话，也不要替我输入 PAT。
5. 最后告诉我：要重启哪个客户端、用哪句话验证装好了。

约束：
- 组织名和 PAT 归我，你只要问一次组织名，别自己猜。
- 不要改动配置里其它 MCP 服务的段落。
- 动手前先把要执行的命令和要写的路径列给我确认。
```

### 方式二：一键脚本

Windows / PowerShell 7；macOS、Linux 装了 pwsh 也能跑。三步，可重复执行：

```powershell
git clone https://github.com/HaydenSmith1121/ado-work-item-skill.git D:\harness\ado-work-item-skill

pwsh -File D:\harness\ado-work-item-skill\scripts\install.ps1 `
  -Organization <你的组织名> `
  -SkillsDir "<你要挂 skill 的工作区>\.agents\skills"

pwsh -File D:\harness\ado-work-item-skill\scripts\set-ado-pat.ps1
```

第一步装公共的部分（MCP 包 + 配置结构 + skill 链接），第二步提示你粘贴 PAT，输入不回显。写完重启客户端生效。

`install.ps1` 的其它开关：`-SkipSkillLink`（只配 MCP 不挂 skill）、`-SkipMcpInstall`（包已装好）、`-Domains`（默认 `core work work-items repositories`）、`-ConfigPath` / `-McpRoot`（换路径）。

### 方式三：手动安装

四步，前三步是公共的，第四步是你自己的。

**1. 装 MCP 包**

```powershell
npm install --prefix "$env:USERPROFILE\.codex\ado-mcp" @azure-devops/mcp --omit=dev --no-audit --no-fund
```

> 别直接用 `npx @azure-devops/mcp` 起服务：受限环境里写不了 npm 缓存，会以
> `connection closed: initialize response` 失败。预装一次、配置里直接指向入口文件最稳。

**2. 写 MCP 配置**（组织名换成你自己的）

```toml
[mcp_servers.azure-devops]
command = "node"
args = ["C:\\Users\\<你>\\.codex\\ado-mcp\\node_modules\\@azure-devops\\mcp\\dist\\index.js", "<你的组织名>", "--domains", "core", "work", "work-items", "repositories", "--authentication", "pat"]
startup_timeout_sec = 60
```

**3. 挂 skill**（Windows 用 junction，别复制文件，复制会出现两份不同步的）

```powershell
New-Item -ItemType Junction -Path "<工作区>\.agents\skills\ado-work-item" -Target "<克隆下来的仓库目录>"
```

**4. 写 PAT**（唯一属于你的一步）

在**有权限的那个账号**登录 `dev.azure.com/<你的组织>` 之后生成 PAT，Scopes 建议：`Work Items = Read & write`、`Project and Team = Read`，需要看代码再加 `Code = Read`。然后：

```powershell
pwsh -File <仓库目录>\scripts\set-ado-pat.ps1
```

脚本把 token 编码成 `base64(":" + PAT)` 写进 `[mcp_servers.azure-devops.env]` 的 `PERSONAL_ACCESS_TOKEN`，只覆盖不追加。

> **同一个邮箱可能是两个身份。** 微软账号里「个人」和「企业/学校」即使邮箱相同也是两个身份，权限常常只给其中一个。用错身份会报 `TF400813: The user '<GUID>' is not authorized`，换另一个身份重新生成 PAT 即可。

**Claude Code**：第一步和第四步一样，第二步换成

```bash
claude mcp add --transport stdio azure-devops -- npx -y @azure-devops/mcp <你的组织名> --authentication pat
```

第三步把 junction 换成 `ln -s`（macOS / Linux）或同样用 junction（Windows）。

### 装完怎么用

重启客户端，然后对 AI 说：

```text
读工作项 <编号>
```

比如 `读工作项 4447`，或者直接贴工作项链接。skill 会依次取本体、评论、关联链接、附件，再给结论。

默认组织和项目写在 `SKILL.md` 顶部那张表里（本仓库预置 `LD-23175` / `LD-ECCMS`）；换了团队就改那两行，或者每次直接给 URL——URL 里的 org / project 优先级更高。
