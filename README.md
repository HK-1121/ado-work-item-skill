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

分析输出固定四段（测试视角）：**初始是什么问题 → 看完评论/修订现在是什么问题 → 怎么操作才能验证 → 需要造数据时怎么在页面里造**。结论在前，证据在后，不倒原始 JSON。

适用场景：看某个 bug/issue 到底在说什么、追一条工作项的历史结论、判断某个问题是新系统还是老系统的问题、把一批工作项批量过一遍。

## 安装

先分清哪些是**每人不同的**、哪些是**公共的**：

| 谁提供 | 内容 |
|---|---|
| 每人不同 | 组织名、PAT、skill 挂载目录、客户端的配置文件位置 |
| 公共（本仓库已备好） | MCP 包与启动参数、配置文件结构、两个安装脚本、`SKILL.md` 的读取与分析流程、用法 |

支持的客户端：**Codex**（`~/.codex/config.toml`，脚本默认）与 **Claude Code**（见方式三最后一小节）。

### 方式一：AI 安装（推荐）

把下面这段**原样发给你的 AI**。它会先自检哪些已经装过、哪些还需要下载，只问你两件事：组织名、skill 挂哪。

```text
请帮我安装 ado-work-item skill。仓库：https://github.com/HK-1121/ado-work-item-skill

按这个顺序做：
1. 先读仓库里的 README.md 和 SKILL.md，弄清它做什么。
2. 把仓库克隆到一个固定目录（先问我想放哪；没意见就放在我正在做的项目之外）。记下这个绝对路径，后面都用它。
3. 先做一次预检，把结果读给我听：
   pwsh -File <克隆目录>\scripts\install.ps1 -Check
   它会报 MCP 包在不在、客户端配置有没有、PAT 写没写、skill 挂没挂；已经完成的不要重复做。
4. 问我两件事：Azure DevOps 组织名、skill 要挂到哪个目录。然后正式安装：
   pwsh -File <克隆目录>\scripts\install.ps1 -Organization <组织名> -Project <默认项目名> -SkillsDir <skills 目录>
5. 装完自己验证三条并告诉我结果：配置文件里有 [mcp_servers.azure-devops]、MCP 入口文件存在、skill 链接指向克隆目录。
6. 最后告诉我：先让我去 Azure DevOps 点复制 PAT，再让我自己在终端跑一次 <克隆目录>\scripts\set-ado-pat.ps1——它从剪贴板读、联网校验，会把结果打给我。然后告诉我重启哪个客户端、用哪句话验证。

约束：
- 路径一律用我这台机器的真实值（$env:USERPROFILE 之类），**不要照抄任何示例路径**——示例里的路径不是我的。
- 组织名、项目名、PAT 都是我的：组织名和项目名问我一次；PAT 只让我自己复制到剪贴板并亲手跑脚本，不要让我贴进对话，也不要替我跑那一步。
- 只动 azure-devops 这一段配置，其它 MCP 服务的内容不要碰。
- 动手前把要执行的命令列给我确认一次。
```

### 方式二：一键脚本

Windows / PowerShell 7；macOS、Linux 装了 pwsh 也能跑。三步，可重复执行：

```powershell
git clone https://github.com/HK-1121/ado-work-item-skill.git <克隆目录>

pwsh -File <克隆目录>\scripts\install.ps1 -Check          # 先看现状，不改任何东西

pwsh -File <克隆目录>\scripts\install.ps1 `
  -Organization <你的组织名> `
  -Project <默认项目名> `
  -SkillsDir "<你要挂 skill 的工作区>\.agents\skills"

# 先在浏览器里点 PAT 的复制按钮，再跑这行（脚本从剪贴板读，并联网校验）
pwsh -File <克隆目录>\scripts\set-ado-pat.ps1
```

`-Check` 只报告不改动；正式那步装公共的部分（MCP 包 + 配置 + skill 链接 + 本机默认值），已完成的会跳过；最后一步从剪贴板取 PAT 并联网校验，成功会打 `[成功]`。写完重启客户端生效。

`install.ps1` 的其它开关：`-SkipSkillLink`（只配 MCP 不挂 skill）、`-SkipMcpInstall`（包已装好，跳过下载）、`-Domains`（默认 `core work work-items repositories`）、`-ConfigPath` / `-McpRoot`（换路径）。macOS / Linux 上挂载改用符号链接，脚本自己判断。

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
args = ["<MCP_ROOT>\\node_modules\\@azure-devops\\mcp\\dist\\index.js", "<你的组织名>", "--domains", "core", "work", "work-items", "repositories", "--authentication", "pat"]
startup_timeout_sec = 60
```

`<MCP_ROOT>` 就是上一步 `npm install --prefix` 用的那个目录：Windows 默认 `%USERPROFILE%\.codex\ado-mcp`，macOS / Linux 默认 `~/.codex/ado-mcp`。不想手算，就让 `install.ps1` 直接写。

**3. 挂 skill**（Windows 用 junction，别复制文件，复制会出现两份不同步的）

```powershell
New-Item -ItemType Junction -Path "<工作区>\.agents\skills\ado-work-item" -Target "<克隆下来的仓库目录>"
```

**4. 写 PAT**（唯一属于你的一步）

在**有权限的那个账号**登录 `dev.azure.com/<你的组织>` 之后生成 PAT，Scopes 建议：`Work Items = Read & write`、`Project and Team = Read`，需要看代码再加 `Code = Read`。然后：

```powershell
pwsh -File <仓库目录>\scripts\set-ado-pat.ps1
```

**PAT 怎么交给脚本**：默认从**剪贴板**读——在 ADO 页面上点复制按钮，然后跑脚本，**不用往终端里粘**（终端的安全输入提示符粘 PAT 容易丢字符，也看不出成没成）。脚本会打印长度和首尾各 4 位让你核对，写完还会真的调一次 `dev.azure.com/<org>/_apis/projects` 验证：`200` 才算通，`401` 是无效或过期，`403` 是 scope 不够。

脚本把 token 编码成 `base64(":" + PAT)` 写进 `[mcp_servers.azure-devops.env]` 的 `PERSONAL_ACCESS_TOKEN`，只覆盖不追加。

其它可用开关：`-Prompt`（确实想用终端粘贴）、`-TokenFile <路径>`（从文件读，读完自动删文件）、`-NoVerify`（跳过联网校验）、`-Force`（已有 PAT 时不再提示）。

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

默认组织和项目**不存在仓库里**：安装时由 `-Organization` / `-Project` 写进本机的 `SKILL.local.md`，这个文件在 `.gitignore` 里，不会提交、也不会跟着仓库跑到别人机器上。没生成过就跟 AI 说一句组织名和项目名，或者直接贴工作项 URL——URL 里的 org / project 优先级最高。
