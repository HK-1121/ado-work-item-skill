# ado-work-item

在 AI 编码助手（Codex / Claude Code）里读取并分析 Azure DevOps 工作项：**本体、评论、关联链接、附件截图**四块一起看，测试做完把结论**直接发到工作项 Discussion**。

写操作只开一项：**发评论**（`scripts/ado-comment.mjs`）。pass 只发文字、不配图；fail / partial / blocked 附失败截图，每张图带「图N」水印。**不改状态、不 @ 任何人、不建/转 bug。**

## 三条硬规矩

1. **一律简体中文**——评论、报告、回复都写简体，界面原文（字段名、按钮名、错码）照抄。
2. **测试数据一律新造**——本轮在 SIT 页面上造一张新案子当主证据；别人留下的、上一轮的案子只能做对照。
3. **评论一眼就懂**——一条一句、先说结果、不写机制，整段 6 条以内；**每条正文下面单独一行标 `---√` / `---×` / `---?`**（通过 / 不通过 / 不确定）。

细节见 `SKILL.md` 开头的「三条硬规矩」。

## 这是什么

这个能力由两块组成：

- **取数**：微软官方的 MCP 服务 `@azure-devops/mcp`，负责跟 Azure DevOps 说话
- **判断**：一套固定的读取流程 + 分析框架，负责决定看什么、怎么看、怎么下结论

MCP 人人一份、每个客户端配一次，还得用**自己的** PAT；真正值得复用的只有后者。所以这个仓库做成 **skill**，将来若要一键安装再包一层插件，内容不用重写。

读的时候四块缺一不可：

1. **本体** —— 标题、类型、状态、原因、区域、迭代、严重度、模块、环境、时间字段、描述正文
2. **评论** —— 全部评论及其作者与时间
3. **关联链接** —— 父子项、相关项、提交、PR、build
4. **附件** —— **有几份就看几份，一份不落**：`relations` 里的 `AttachedFile`、描述/评论里内联的 `<img>`、正文点名的文件名都要抓；每份都真打开（图看内容，pdf 渲染看版面，xls/xlsx 读表头/列宽/字体/单元格类型），不许只看文件名。样板和现状要分开写清各给了什么判据。

> 附件这条是硬要求，细则和踩坑见 `SKILL.md` 的「附件必须全部看完」一节（4328 就是因为第一轮只比了转换副本，把真实的列宽差异当成了噪声）。

分析完交两份东西，缺一不可：

1. **发到工作项的评论**——正文落 `output/<ID>/comment.txt`（纯文本，不写 `comment.md`）：`【test time】` / `【sit test result】` / `【description】` 三个标签 + 编号条目 + **失败条目的图号 `（图N）`**，和 4353 的评论同一格式（标签改用 `【test time】`、值带时分）。写完跑脚本发，不用人粘贴：

```powershell
# 在工作区根目录跑，<克隆目录> 换成你放 skill 的路径
node <克隆目录>\scripts\ado-comment.mjs --id 4431              # 发（自动查重、pass 不传图、fail 传失败截图）
node <克隆目录>\scripts\ado-comment.mjs --id 4431 --dry-run    # 只校验，不发
```

评论长这样（pass 时**不带任何图号、不传图**；fail 只给 `---×` 配图）：

```text
【test time】：2026/10/30 11:32
【sit test result】：partial
【description】：
1.新造 02- 案 02-2026-01239（P.I.% 5）出 F.7 后，CP05 自己多出一行 E330，Auto Gen. 是 Y
---√
2.memo 标题还是 Submission of G. . 330(R)，G.F. 的 F 没印出来（图1）
---×
```

图号就是上传顺序、也是文件名 `comment-NN` 的 NN：`（图1）` ↔ `comment-01-*.png`，多张写 `（图1、图2）`。**每张图在打包时自动烤「图N」水印**（白底标签带，不盖原图），读者在 ADO 里看不到文件名也能对上正文。写完用 `scripts/pack-comment.mjs` 打包，它会自动烤水印并核对「正文图号 ↔ 文件」。

结果标记是照着 2026/10/23 那条评论定的：`---√` 通过、`---×` 不通过、`---?` 不确定（要业务确认、只验了一半、环境卡住）。时间写 `yyyy/MM/dd HH:mm`（24 小时制、补零），写实测那一刻，不写建单日。`---` 后面不留空格——留了空格 Markdown 会把它当分隔线，报告里字就没了。整体结果仍只填 `pass` / `fail` / `partial` / `blocked`，规则是「原报障点修没修」，不是数 `×` 的个数。

2. **分析报告**——固定四段（**初始是什么问题 → 看完评论/修订现在是什么问题 → 怎么操作才能验证 → 需要造数据时怎么在页面里造**），每个结论后面跟截图 / PDF / SQL / commit，有卡点再加「卡点与处置」；结论在前，证据在后，不倒原始 JSON。报告是 Markdown，**图文一一对应**：每条结论下面紧跟它的图，开头一张「图号 ↔ 条目 ↔ 文件」索引表，图号沿用评论里的 `图N`（`（图2）` ↔ `comment-02-*.png`），不再另编「图 4-1」；同一张图里多个标注点用 ①② 标。

分工写死：评论只说验没验过、现在对不对，报告说为什么这么判、证据在哪。验到一半卡住（没数据、没权限、页面没入口）不用「未实测」收尾：先按步骤 / 数据 / 权限 / 环境四把刀定位，定位不出就带 2–3 个选项来问，把卡点打通再往下走。

**在哪儿验**：链路是 **SIT → IPT → UAT**，先上 SIT，SIT 验过推 IPT，IPT 验过再推 UAT。所以单子上写 `GCIS PP (UAT)` 也照样在 **SIT** 上验，SIT 就是第一站；两边数据不一样、案号对不上是正常的，按同样的业务形状造等价数据验同一段逻辑，不要写「SIT 没有这案，得去 UAT 看」。

**交付时只给链接和路径，不往对话里贴图。** 评论已经发进 ADO，回复里给「工作项链接 + 评论 id + 结果词 + 本地底稿路径」就行；会话里渲染出来的截图复制不了、下载不了，贴了也用不上。

图多的时候不用手工排序号，`scripts/pack-comment.mjs` 按 manifest 一次打包、烤水印并检查漏配：

```powershell
node scripts/pack-comment.mjs --manifest tmp\pack-4489.json --dry-run   # 先看计划
node scripts/pack-comment.mjs --manifest tmp\pack-4489.json             # 落到 output/<ID>/comment-NN-*.png
```

manifest 就是 `{ id, text?, items: [{ src, name, covers: [条目号] }] }`，顺序即上传顺序；
脚本会补零编号、调 `annotate.py --stamp` 给每张图烤「图N」水印、拦 0 字节源文件、列出「条目 N 没有配图」，并从 `text` 里读 `（图N）` 核对：引用不存在的图、图号跳号、条目没写图号都会报出来。**pass 评论 `items` 留空**（不打包图），非 pass 只放失败截图。

图上的红框、编号、批注和左右对比用 `scripts/annotate.py` 画（只依赖 Pillow，`python -m pip install pillow`）。对比图固定左旧右新、两边带标签，只拼两张：

```powershell
python scripts/annotate.py --info tmp\raw.png                    # 先看尺寸，方便定坐标
python scripts/annotate.py --spec tmp\anno-4507.json             # 框 + 编号 ① + 批注
python scripts/annotate.py --stamp old.png --out new.png --figure 3   # 补烤「图3」水印
python scripts/annotate.py --compare old.png new.png --labels "标准版（老系统）" "实际版（SIT）" --out output\4507\comment-01-cmp.png
```

spec 的字段（`sources` / `marks` / `shape`）见 `SKILL.md` 的「标注与对比拼图」一节。


适用场景：看某个 bug/issue 到底在说什么、追一条工作项的历史结论、判断某个问题是新系统还是老系统的问题、测试完把结论直接发回工作项、把一批工作项批量过一遍。

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

> **PAT scope**：只读要 `Work Items (Read)`；测试完自动发评论（`scripts/ado-comment.mjs`）还要 `Work Items (Read & Write)`，否则发评论会报 `HTTP 403`。PAT 用个人账号的，企业账号在组织里是另一个身份，会报 `TF400813`。

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

### 怎么对 AI 说

重启客户端。一句话就够，编号或链接都行：

```text
读工作项 4511
```

skill 会依次取本体、评论、关联链接、附件，再给结论。默认会读全四块并在环境里实测，所以不会秒回；只要判断、不要实测时，用下面 B 档第一句把实测省掉。

#### 四档说法

**A 默认全流程**（读 + 实测 + 评论 + 报告）

```text
读工作项 4511
```

也认 `分析工作项 4511`、`看下 4511`，或者直接贴工作项链接。

**B 限范围**（省时间，也用来压住不该做的事）

```text
工作项 4511 只看评论和修订，判断到底修没修；不实测、不用出评论
```

```text
工作项 4507 要实测：在 SIT 按页面走一遍，出评论 + 截图清单 + 报告
```

```text
批量过 4506、4507、4508，每个给一句结论，先别写报告
```

**C 指定交付口径**（平时不用，纠偏时用）

```text
按 ado-work-item 交付：评论块 + 截图清单 + 报告路径；评论按现象写、像人说话，编号 1.xxx 不加空格，截图只截打开就看到的样子
```

**D 它卡住时怎么回**

它会把卡点收敛成 2–3 个带代价的选项（要造数 / 要换 Post / 要等发布）。回答时给条件，不要给态度：

```text
用 02-2026-00806 走 CP08 转案，数据我来造
```

`你看着办`、`都行` 会让它继续猜，最后写出来的就是推断而不是实测。

#### 它只做三件事

读、分析、产出两份结论。**不改状态、不代发评论、不建链接**——评论永远由你粘进 Discussion。要写也单独说，并且先确认。

#### 客户端差异

Codex / Claude Code 装好重启就按 description 命中，`读工作项 4447` 即可。

DSH 里如果第一句被回「没有这个 skill / unknown」，在话里补上路径：

```text
按 <克隆目录>\SKILL.md 分析工作项 4511
```

skill 没自动加载时，只要客户端有 REST 兜底通道仍能读，只是少了「按 skill 自动走流程」这一层。第一句就报 unknown 的话，先确认 junction 在不在（`<工作区>\.agents\skills\ado-work-item`），再补路径。

默认组织和项目**不存在仓库里**：安装时由 `-Organization` / `-Project` 写进本机的 `SKILL.local.md`，这个文件在 `.gitignore` 里，不会提交、也不会跟着仓库跑到别人机器上。没生成过就跟 AI 说一句组织名和项目名，或者直接贴工作项 URL——URL 里的 org / project 优先级最高。
