<#
把 Azure DevOps PAT 写进 AI 客户端的 MCP 配置。

用法：
    pwsh -File scripts\setup-ado-pat.ps1
提示时粘贴 PAT（必须是个人账号的），回车即可，输入不回显。
重复执行会覆盖旧值，不会重复追加。写完重启客户端生效。

非交互（自动化用，token 会进命令历史，慎用）：
    pwsh -File scripts\setup-ado-pat.ps1 -Token '<PAT>'

默认写 Codex 的 ~/.codex/config.toml；其它客户端用 -ConfigPath 指定。
#>
[CmdletBinding()]
param(
    [string]$Token,
    [string]$ConfigPath = "$env:USERPROFILE\.codex\config.toml"
)

if (-not $Token) {
    $secure = Read-Host -AsSecureString '粘贴 PAT（个人账号，输入不回显）'
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
if ([string]::IsNullOrWhiteSpace($Token)) { throw 'PAT 为空，未做任何修改。' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "找不到配置文件：$ConfigPath" }

$txt = Get-Content -Raw -LiteralPath $ConfigPath
if ($txt -notmatch '(?m)^\[mcp_servers\.azure-devops\]') {
    throw '配置里没有 [mcp_servers.azure-devops] 段，先把 MCP 服务配好（见 README）。'
}

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$Token"))
$txt = [regex]::Replace($txt, '(?ms)^\[mcp_servers\.azure-devops\.env\].*?(?=^\[|\z)', '')
$txt = $txt.TrimEnd() + "`n`n[mcp_servers.azure-devops.env]`nPERSONAL_ACCESS_TOKEN = `"$b64`"`n"
[IO.File]::WriteAllText($ConfigPath, $txt, (New-Object Text.UTF8Encoding($false)))

$Token = $null
Remove-Variable secure -ErrorAction SilentlyContinue
Write-Host "已写入 $ConfigPath（base64 长度 $($b64.Length)）。重启客户端后生效。" -ForegroundColor Green
