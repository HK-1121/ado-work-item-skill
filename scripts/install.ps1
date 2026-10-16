<#
一键安装 ado-work-item skill（Windows / PowerShell 7）。

做三件事，都可重复执行：
  1. 把 @azure-devops/mcp 预装到固定目录（避免用 npx 现拉，沙箱里会失败）
  2. 往 AI 客户端的 MCP 配置里写入 azure-devops 服务（组织名由你指定）
  3. 把本仓库挂成 skills 目录下的链接（可选，不要就加 -SkipSkillLink）

不含任何密钥。PAT 由本人另外跑 scripts\set-ado-pat.ps1 输入。

最小用法：
    pwsh -File scripts\install.ps1 -Organization <你的组织名>

常用参数：
    -Organization     Azure DevOps 组织名（地址里 dev.azure.com/ 后面那段）
    -SkillsDir        要挂 skill 的目录，例如 "<工作区>\.agents\skills"
    -ConfigPath        默认 ~/.codex/config.toml（Claude Code 请自行按其文档配置）
    -McpRoot           MCP 包预装目录，默认 ~/.codex/ado-mcp
    -Domains          启用的域，默认 core work work-items repositories
    -SkipSkillLink    只装 MCP + 配置，不挂 skill
    -SkipMcpInstall   已有包时跳过 npm 安装
#>
[CmdletBinding()]
param(
    [string]$Organization,
    [string]$SkillsDir,
    [string]$ConfigPath = "$env:USERPROFILE\.codex\config.toml",
    [string]$McpRoot = "$env:USERPROFILE\.codex\ado-mcp",
    [string[]]$Domains = @('core', 'work', 'work-items', 'repositories'),
    [switch]$SkipSkillLink,
    [switch]$SkipMcpInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $McpRoot 'node_modules\@azure-devops\mcp\dist\index.js'

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# 1. 组织名：每人不同
if (-not $Organization) {
    $Organization = (Read-Host 'Azure DevOps 组织名（地址里 dev.azure.com/ 后面那段）').Trim()
}
if ([string]::IsNullOrWhiteSpace($Organization)) { throw '组织名不能为空，未做任何修改。' }

# 2. MCP 服务：公共部分
if (Test-Path -LiteralPath $entry) {
    Step "MCP 包已就绪：$entry"
}
elseif ($SkipMcpInstall) {
    throw "找不到 $entry，但指定了 -SkipMcpInstall。"
}
else {
    Step "安装 @azure-devops/mcp 到 $McpRoot（首次需要联网，约 20 秒）"
    npm install --prefix $McpRoot '@azure-devops/mcp' --omit=dev --no-audit --no-fund | Out-Null
    if (-not (Test-Path -LiteralPath $entry)) { throw "安装后仍找不到 $entry。" }
}

# 3. 写客户端配置：结构是公共的，组织名是每人的
$cfgDir = Split-Path -Parent $ConfigPath
if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
$txt = if (Test-Path -LiteralPath $ConfigPath) { Get-Content -Raw -LiteralPath $ConfigPath } else { '' }

foreach ($table in 'mcp_servers\.azure-devops\.env', 'mcp_servers\.azure-devops') {
    $txt = [regex]::Replace($txt, "(?ms)^\[$table\].*?(?=^\[|\z)", '')
}

$entryToml = $entry -replace '\\', '\\'
$domainList = ($Domains | ForEach-Object { '"' + $_ + '"' }) -join ', '
$block = @"
[mcp_servers.azure-devops]
command = "node"
args = ["$entryToml", "$Organization", "--domains", $domainList, "--authentication", "pat"]
startup_timeout_sec = 60
"@

$txt = $txt.TrimEnd() + "`n`n" + $block + "`n"
[IO.File]::WriteAllText($ConfigPath, $txt, (New-Object Text.UTF8Encoding($false)))

$check = Get-Content -Raw -LiteralPath $ConfigPath
if ($check -notmatch '(?m)^\[mcp_servers\.azure-devops\]') { throw "写入后校验失败：$ConfigPath" }
Step "已写入 MCP 配置：$ConfigPath（组织 $Organization）"

# 4. 挂 skill：可选
if ($SkipSkillLink -or -not $SkillsDir) {
    Step '跳过挂载 skill（未给 -SkillsDir 或指定了 -SkipSkillLink）'
}
else {
    if (-not (Test-Path -LiteralPath $SkillsDir)) { New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null }
    $link = Join-Path $SkillsDir 'ado-work-item'
    if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            # 只删链接本身，绝不递归删目标
            [IO.Directory]::Delete($link, $false)
            Step "移除旧链接：$link"
        }
        else {
            throw "$link 已存在且不是链接，未改动。请先确认那里是什么。"
        }
    }
    New-Item -ItemType Junction -Path $link -Target $repoRoot | Out-Null
    Step "已挂载 skill：$link -> $repoRoot"
}

Write-Host ''
Write-Host '下一步（只能人工做）：' -ForegroundColor Yellow
Write-Host "  pwsh -File `"$PSScriptRoot\set-ado-pat.ps1`" -ConfigPath `"$ConfigPath`""
Write-Host '  粘贴 PAT 后重启 AI 客户端生效。'
