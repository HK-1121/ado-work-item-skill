<#
安装 ado-work-item skill。三个动作，全部可重复执行，已完成的会自动跳过：
  1. 预装 @azure-devops/mcp
  2. 往 AI 客户端的 MCP 配置里写 azure-devops 服务
  3. 把本仓库挂进 skills 目录，并生成只属于本机的 SKILL.local.md

先看现状（不改任何东西）：
    pwsh -File scripts\install.ps1 -Check

正式安装：
    pwsh -File scripts\install.ps1 -Organization <组织名> -Project <项目名> -SkillsDir <skills 目录>

参数：
    -Organization  Azure DevOps 组织名（地址里 dev.azure.com/ 后面那段）
    -Project       默认项目名，写进本机 SKILL.local.md
    -SkillsDir     要挂 skill 的目录，例如 "<工作区>\.agents\skills"；不传就只配 MCP
    -ConfigPath    默认 $env:USERPROFILE\.codex\config.toml
    -McpRoot       默认 $env:USERPROFILE\.codex\ado-mcp
    -Domains       默认 core work work-items repositories
    -Check         只报告状态，不写任何文件
    -SkipSkillLink 只配 MCP，不挂 skill
    -SkipMcpInstall 包已在 -McpRoot 时跳过 npm

不含任何密钥。PAT 由本人另外跑 scripts\set-ado-pat.ps1 输入。
#>
[CmdletBinding()]
param(
    [string]$Organization,
    [string]$Project,
    [string]$SkillsDir,
    [string]$ConfigPath = "$env:USERPROFILE\.codex\config.toml",
    [string]$McpRoot = "$env:USERPROFILE\.codex\ado-mcp",
    [string[]]$Domains = @('core', 'work', 'work-items', 'repositories'),
    [switch]$Check,
    [switch]$SkipSkillLink,
    [switch]$SkipMcpInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $McpRoot 'node_modules\@azure-devops\mcp\dist\index.js'
$localFile = Join-Path $repoRoot 'SKILL.local.md'
$isWindowsHost = if ($null -eq $IsWindows) { $true } else { $IsWindows }

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Done($msg) { Write-Host "  [已完成] $msg" -ForegroundColor Green }
function Todo($msg) { Write-Host "  [待执行] $msg" -ForegroundColor Yellow }
function Skip($msg) { Write-Host "  [跳过]   $msg" -ForegroundColor DarkGray }

function Get-LocalSetting($key) {
    if (-not (Test-Path -LiteralPath $localFile)) { return $null }
    $line = Select-String -LiteralPath $localFile -Pattern "^$key\s*:\s*(.+)$" | Select-Object -First 1
    if ($line) { return $line.Matches[0].Groups[1].Value.Trim() }
    return $null
}

function Get-ConfigOrg {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $ConfigPath),
        '(?ms)^\[mcp_servers\.azure-devops\].*?args\s*=\s*\[[^\]]*?"([^"]+)"\s*,\s*"--domains"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Test-HasPat {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
    return [bool](Select-String -LiteralPath $ConfigPath -Pattern '^PERSONAL_ACCESS_TOKEN\s*=' -Quiet)
}

function Get-SkillLinkState {
    if (-not $SkillsDir) { return 'not-asked' }
    $link = Join-Path $SkillsDir 'ado-work-item'
    if (-not (Test-Path -LiteralPath $link)) { return 'missing' }
    $item = Get-Item -LiteralPath $link -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return 'conflict' }
    $target = if ($item.Target) { @($item.Target)[0] } else { $null }
    if ($target -and ($target.TrimEnd('\') -ieq $repoRoot.TrimEnd('\'))) { return 'ok' }
    return 'other-target'
}

# ---------- 检查模式：只报告 ----------
if ($Check) {
    Write-Host '当前状态' -ForegroundColor Cyan
    if (Test-Path -LiteralPath $entry) { Done "MCP 包：$entry" } else { Todo "MCP 包：需要下载到 $McpRoot" }

    if (Test-Path -LiteralPath $ConfigPath) {
        $org = Get-ConfigOrg
        if ($org) { Done "客户端配置：$ConfigPath（已有 azure-devops，组织 $org）" }
        else { Todo "客户端配置：$ConfigPath 存在，但还没有 azure-devops 段" }
    }
    else { Todo "客户端配置：$ConfigPath 不存在，安装时会新建" }

    if (Test-HasPat) { Done 'PAT：已写入' } else { Todo 'PAT：未写入（需本人跑 set-ado-pat.ps1）' }

    switch (Get-SkillLinkState) {
        'not-asked' { Skip 'skill 链接：未指定 -SkillsDir，本次不挂' }
        'ok' { Done "skill 链接：$SkillsDir\ado-work-item -> $repoRoot" }
        'missing' { Todo "skill 链接：$SkillsDir\ado-work-item 尚未创建" }
        'other-target' { Todo "skill 链接：$SkillsDir\ado-work-item 已存在但指向别处，安装时会重建" }
        'conflict' { Todo "skill 链接：$SkillsDir\ado-work-item 是真实目录（不是链接），安装会报错停下" }
    }

    $curOrg = Get-LocalSetting 'organization'
    $curProj = Get-LocalSetting 'project'
    if ($curOrg -or $curProj) { Done "本机默认值：SKILL.local.md（组织 $curOrg / 项目 $curProj）" }
    else { Todo '本机默认值：SKILL.local.md 还没生成' }

    Write-Host ''
    Write-Host '带 -Check 只做检查，没有改动任何文件。' -ForegroundColor DarkGray
    return
}

# ---------- 安装模式 ----------
if (-not $Organization) {
    throw '缺少 -Organization（Azure DevOps 组织名）。先问用户要，再重跑；没有它就是猜，猜错会写进配置。'
}
if ([string]::IsNullOrWhiteSpace($Organization)) { throw '组织名不能为空。' }

Step "仓库位置：$repoRoot"

# 1. MCP 包
if (Test-Path -LiteralPath $entry) {
    Done "MCP 包已就绪：$entry"
}
elseif ($SkipMcpInstall) {
    throw "找不到 $entry，但指定了 -SkipMcpInstall。"
}
else {
    Step "下载 @azure-devops/mcp 到 $McpRoot（首次需要联网，约 20 秒）"
    npm install --prefix $McpRoot '@azure-devops/mcp' --omit=dev --no-audit --no-fund | Out-Null
    if (-not (Test-Path -LiteralPath $entry)) { throw "安装后仍找不到 $entry。" }
    Done 'MCP 包安装完成'
}

# 2. 客户端配置
$cfgDir = Split-Path -Parent $ConfigPath
if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
$hadConfig = Test-Path -LiteralPath $ConfigPath
$txt = if ($hadConfig) { Get-Content -Raw -LiteralPath $ConfigPath } else { '' }
$beforeOrg = Get-ConfigOrg

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

# 注意：变量名不能叫 $check，会和 [switch]$Check 撞成同一个变量（PowerShell 大小写不敏感）
$verify = Get-Content -Raw -LiteralPath $ConfigPath
if ($verify -notmatch '(?m)^\[mcp_servers\.azure-devops\]') { throw "写入后校验失败：$ConfigPath" }
if ($beforeOrg -eq $Organization) { Done "客户端配置已是组织 $Organization，已刷新" }
else { Done "写入客户端配置：$ConfigPath（组织 $Organization）" }
if (-not $hadConfig) { Write-Host "  [提示] 新建了配置文件 $ConfigPath" -ForegroundColor DarkGray }

# 3. 本机默认值（不入库）
$newOrg = $Organization
$newProj = if ($Project) { $Project } else { Get-LocalSetting 'project' }
$body = "# 本机默认值，安装脚本生成，不入库（见 .gitignore）`norganization: $newOrg`n"
if ($newProj) { $body += "project: $newProj`n" }
[IO.File]::WriteAllText($localFile, $body, (New-Object Text.UTF8Encoding($false)))
Done "本机默认值：$localFile（组织 $newOrg$(if ($newProj) { " / 项目 $newProj" })）"

# 4. 挂 skill
if ($SkipSkillLink -or -not $SkillsDir) {
    Skip '未指定 -SkillsDir 或指定了 -SkipSkillLink，不挂 skill'
}
else {
    $state = Get-SkillLinkState
    if ($state -eq 'conflict') { throw "$SkillsDir\ado-work-item 已存在且不是链接，未改动。" }
    if (-not (Test-Path -LiteralPath $SkillsDir)) { New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null }
    $link = Join-Path $SkillsDir 'ado-work-item'
    if (Test-Path -LiteralPath $link) {
        # 只删链接本身，绝不递归删目标
        [IO.Directory]::Delete($link, $false)
    }
    if ($isWindowsHost) { New-Item -ItemType Junction -Path $link -Target $repoRoot | Out-Null }
    else { New-Item -ItemType SymbolicLink -Path $link -Target $repoRoot | Out-Null }
    Done "已挂载 skill：$link -> $repoRoot"
}

Write-Host ''
if (Test-HasPat) {
    Write-Host 'PAT 已存在，直接重启客户端即可。' -ForegroundColor Green
}
else {
    Write-Host '还差一步（密钥只能本人给）：' -ForegroundColor Yellow
    Write-Host '  1. 在 Azure DevOps 里复制 PAT'
    Write-Host "  pwsh -File `"$PSScriptRoot\set-ado-pat.ps1`" -ConfigPath `"$ConfigPath`""
    Write-Host '  脚本从剪贴板取 PAT、联网校验，成功会打 [成功]；然后重启客户端。'
}
