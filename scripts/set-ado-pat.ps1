<#
写入 Azure DevOps PAT，写完立刻联网校验，直接告诉你成不成。

默认从**剪贴板**读，所以不用往终端里粘（粘安全提示符容易丢字符）：
    1. 在浏览器里点 PAT 的复制按钮
    2. pwsh -File scripts\set-ado-pat.ps1

其它用法：
    -TokenFile <路径>   从文件读（读完自动删掉该文件）
    -Token <字符串>     直接传（会进命令历史，慎用）
    -Prompt             老的终端输入方式（终端支持才用）
    -NoVerify           跳过联网校验
    -Force              已有 PAT 时不问，直接覆盖

脚本会打印 token 长度和首尾各 4 位（形如 abcd…wxyz）让你确认读到的就是它，
不会打印完整 token。
#>
[CmdletBinding()]
param(
    [string]$Token,
    [string]$TokenFile,
    [string]$ConfigPath = "$env:USERPROFILE\.codex\config.toml",
    [switch]$Prompt,
    [switch]$NoVerify,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "  $m" }
function Ok($m) { Write-Host "  [成功] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  [失败] $m" -ForegroundColor Red }
function Warn2($m) { Write-Host "  [注意] $m" -ForegroundColor Yellow }

function Get-OrgFromConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    $m = [regex]::Match((Get-Content -Raw -LiteralPath $ConfigPath),
        '(?ms)^\[mcp_servers\.azure-devops\].*?args\s*=\s*\[[^\]]*?["'']([^"'']+)["'']\s*,\s*["'']--domains["'']')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Normalize-Token([string]$raw) {
    if ($null -eq $raw) { return '' }
    $t = $raw.Trim()
    $t = $t.Trim('"', "'")
    foreach ($prefix in 'Bearer ', 'Basic ', 'PAT=') {
        if ($t.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $t = $t.Substring($prefix.Length).Trim() }
    }
    if ($t.StartsWith(':')) { $t = $t.Substring(1) }
    # 去掉内部换行（多行粘贴常见）
    return ($t -replace '\s+', '')
}

# ---------- 1. 取 token ----------
Write-Host '读取 PAT' -ForegroundColor Cyan
$source = ''
if ($Token) {
    $source = '命令行参数'
}
elseif ($TokenFile) {
    if (-not (Test-Path -LiteralPath $TokenFile)) { throw "找不到 token 文件：$TokenFile" }
    $Token = Get-Content -Raw -LiteralPath $TokenFile
    Remove-Item -LiteralPath $TokenFile -Force
    $source = "文件 $TokenFile（已删除）"
}
elseif ($Prompt) {
    $secure = Read-Host -AsSecureString '粘贴 PAT（输入不回显）'
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    Remove-Variable secure -ErrorAction SilentlyContinue
    $source = '终端输入'
}
else {
    try { $Token = Get-Clipboard -Raw -ErrorAction Stop }
    catch { throw "读剪贴板失败：$($_.Exception.Message)。改用 -Prompt 或 -TokenFile。" }
    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw '剪贴板是空的。先在浏览器里点 PAT 的复制按钮，再重跑这个脚本。'
    }
    $source = '剪贴板'
}

$Token = Normalize-Token $Token
if ([string]::IsNullOrWhiteSpace($Token)) { throw 'PAT 为空，未做任何修改。' }
if ($Token.Length -lt 20) {
    throw "读到的内容只有 $($Token.Length) 个字符，不像 PAT（Azure DevOps 的通常是 52 或 84 位）。重新复制一次再试。"
}

$preview = $Token.Substring(0, 4) + '…' + $Token.Substring($Token.Length - 4)
Ok "读到 PAT（来源：$source）：长度 $($Token.Length)，$preview"
if ($Token.Length -ne 52 -and $Token.Length -ne 84) {
    Warn2 "Azure DevOps 的 PAT 通常是 52 或 84 位，当前 $($Token.Length) 位。核对上面的首尾字符，确认剪贴板里是 PAT 本身而不是别的东西。"
}

$already = $false
if (Test-Path -LiteralPath $ConfigPath) {
    $already = [bool](Select-String -LiteralPath $ConfigPath -Pattern '^PERSONAL_ACCESS_TOKEN\s*=' -Quiet)
}
if ($already -and -not $Force) { Info '（配置里已有一份 PAT，本次会覆盖）' }

# ---------- 2. 写配置 ----------
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "找不到 $ConfigPath。先跑 install.ps1 把 MCP 配好，再来写 PAT。"
}
$txt = Get-Content -Raw -LiteralPath $ConfigPath
if ($txt -notmatch '(?m)^\[mcp_servers\.azure-devops\]') {
    throw '配置里没有 [mcp_servers.azure-devops] 段。先跑 install.ps1（它需要 -Organization），再来写 PAT。'
}

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$Token"))
$txt = [regex]::Replace($txt, '(?ms)^\[mcp_servers\.azure-devops\.env\].*?(?=^\[|\z)', '')
$txt = $txt.TrimEnd() + "`n`n[mcp_servers.azure-devops.env]`nPERSONAL_ACCESS_TOKEN = `"$b64`"`n"
[IO.File]::WriteAllText($ConfigPath, $txt, (New-Object Text.UTF8Encoding($false)))
Ok "已写入 $ConfigPath"

$script:authHeader = 'Basic ' + $b64
$Token = $null

# ---------- 3. 联网校验 ----------
$org = Get-OrgFromConfig
if ($NoVerify) {
    Info '按 -NoVerify 跳过联网校验。'
}
elseif (-not $org) {
    Warn2 '配置里没解析出组织名，跳过校验。'
}
else {
    $uri = "https://dev.azure.com/$org/_apis/projects?api-version=7.1&`$top=1"
    Info "校验中：GET $uri"
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers @{ Authorization = $script:authHeader } -TimeoutSec 30
        if ($resp.StatusCode -eq 200 -and $resp.Content.TrimStart().StartsWith('{')) {
            Ok "PAT 有效，能读 $org 的项目列表。"
        }
        elseif ($resp.StatusCode -eq 203) {
            Bad "返回 203（登录页），说明这次请求没被认成已认证。PAT 可能不对，或组织名不是 $org。"
        }
        else {
            Bad "返回 $($resp.StatusCode)，内容不是预期 JSON。"
        }
    }
    catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        switch ($code) {
            401 { Bad '401 未授权：PAT 无效、已过期，或复制时少了字符。去 ADO 重新生成一个再试。' }
            403 { Bad '403 无权限：PAT 有效，但这个账号/这个 token 的 scope 不够（至少要 Work Items 读取）。' }
            404 { Bad "404 找不到：组织名 '$org' 可能不对。" }
            default { Bad "请求失败：$($_.Exception.Message)" }
        }
    }
}

# ---------- 4. 收尾 ----------
Write-Host ''
Write-Host '下一步：重启 AI 客户端，然后让它「读工作项 <编号>」验证。' -ForegroundColor Yellow
