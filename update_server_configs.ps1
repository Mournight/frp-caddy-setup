# 强制管道输出使用无 BOM 的 UTF-8，避免 bash 解析报错
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$ErrorActionPreference = "Stop"

# ========================= 读取 .env 配置 =========================
function Import-DotEnv {
    $envFile = Join-Path $PSScriptRoot ".env"
    if (-not (Test-Path $envFile)) {
        throw "未找到 .env 配置文件。`n请复制 .env.example 为 .env 并填写你的服务器信息。"
    }
    $config = @{}
    foreach ($line in (Get-Content $envFile -Encoding UTF8)) {
        $trimmed = $line.Trim()
        if ($trimmed -and -not $trimmed.StartsWith('#')) {
            $eqIdx = $trimmed.IndexOf('=')
            if ($eqIdx -gt 0) {
                $key = $trimmed.Substring(0, $eqIdx).Trim()
                $val = $trimmed.Substring($eqIdx + 1).Trim()
                $config[$key] = $val
            }
        }
    }
    return $config
}

$cfg = Import-DotEnv

# 必填项校验
foreach ($key in @('DOMAIN', 'SSH_USER', 'SSH_PORT', 'FRPS_BIND_PORT', 'FRPS_AUTH_TOKEN', 'CF_DNS_TOKEN')) {
    if (-not $cfg[$key]) { throw ".env 中缺少必填项: $key" }
}

$ServerIp         = $cfg['DOMAIN']
$SshUser          = $cfg['SSH_USER']
$SshPort          = [int]$cfg['SSH_PORT']
$FrpsBindPort     = [int]$cfg['FRPS_BIND_PORT']
$AcceptNewHostKey = $true
$SshPrivateKeyPath = Join-Path $env:USERPROFILE ".ssh\id_ed25519"

# ========================= 本地配置文件 =========================
$LocalFrpsConfig  = Join-Path $PSScriptRoot "frps.toml"
$LocalCaddyConfig = Join-Path $PSScriptRoot "Caddyfile"

# 远端路径（一般不用改）
$RemoteFrpsConfig  = "/etc/frp/frps.toml"
$RemoteCaddyConfig = "/etc/caddy/Caddyfile"

# ========================= 占位符替换 =========================
function Expand-Template {
    param([string]$Content, [hashtable]$Vars)
    foreach ($kv in $Vars.GetEnumerator()) {
        $Content = $Content -replace [regex]::Escape("{{$($kv.Key)}}"), $kv.Value
    }
    # 检查是否还有未替换的占位符
    if ($Content -match '\{\{(.+?)\}\}') {
        throw "模板中存在未替换的占位符: {{$($Matches[1])}}，请检查 .env 配置。"
    }
    return $Content
}

# ========================= SSH 工具 =========================
function Get-OpenSshTool([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "未找到 $Name。请先启用 Windows OpenSSH Client。"
}

if (-not (Test-Path $LocalFrpsConfig))  { throw "未找到本地文件: $LocalFrpsConfig" }
if (-not (Test-Path $LocalCaddyConfig)) { throw "未找到本地文件: $LocalCaddyConfig" }
if (-not (Test-Path $SshPrivateKeyPath)) { throw "未找到 SSH 私钥: $SshPrivateKeyPath。请先运行 deploy_server_frps_caddy.ps1 完成密钥初始化。" }

$ssh = Get-OpenSshTool "ssh.exe"
$scp = Get-OpenSshTool "scp.exe"

$sshOptions = @()
if ($AcceptNewHostKey) {
  $sshOptions += @("-o", "StrictHostKeyChecking=accept-new")
}

# ========================= 生成配置文件 =========================
Write-Host "正在从模板生成配置文件..." -ForegroundColor Cyan

$frpsContent = Expand-Template -Content (Get-Content $LocalFrpsConfig -Raw -Encoding UTF8) -Vars @{
    'FRPS_BIND_PORT' = $cfg['FRPS_BIND_PORT']
    'FRPS_AUTH_TOKEN' = $cfg['FRPS_AUTH_TOKEN']
}

$caddyContent = Expand-Template -Content (Get-Content $LocalCaddyConfig -Raw -Encoding UTF8) -Vars @{
    'DOMAIN'       = $cfg['DOMAIN']
    'CF_DNS_TOKEN' = $cfg['CF_DNS_TOKEN']
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$tmpFrps  = Join-Path $env:TEMP "frps.toml.upload"
$tmpCaddy = Join-Path $env:TEMP "Caddyfile.upload"

# 写入时去除 BOM 和 CRLF
$frpsClean  = ($frpsContent  -replace [char]0xFEFF, "" -replace "`r`n", "`n" -replace "`r", "")
$caddyClean = ($caddyContent -replace [char]0xFEFF, "" -replace "`r`n", "`n" -replace "`r", "")
[IO.File]::WriteAllText($tmpFrps,  $frpsClean,  $utf8NoBom)
[IO.File]::WriteAllText($tmpCaddy, $caddyClean, $utf8NoBom)

# ========================= 上传并应用 =========================
Write-Host "上传配置文件到远端..." -ForegroundColor Cyan
& $scp @sshOptions -i $SshPrivateKeyPath -o BatchMode=yes -P $SshPort $tmpFrps  "${SshUser}@${ServerIp}:/tmp/frps.toml.new"
& $scp @sshOptions -i $SshPrivateKeyPath -o BatchMode=yes -P $SshPort $tmpCaddy "${SshUser}@${ServerIp}:/tmp/Caddyfile.new"

$remoteScript = @"
set -euo pipefail

if [ ! -f /tmp/frps.toml.new ]; then
  echo 'missing /tmp/frps.toml.new'
  exit 1
fi
if [ ! -f /tmp/Caddyfile.new ]; then
  echo 'missing /tmp/Caddyfile.new'
  exit 1
fi

caddy validate --config /tmp/Caddyfile.new

TS=`$(date +%Y%m%d%H%M%S)
[ -f ${RemoteFrpsConfig} ] && cp -a ${RemoteFrpsConfig} ${RemoteFrpsConfig}.bak.`$TS || true
[ -f ${RemoteCaddyConfig} ] && cp -a ${RemoteCaddyConfig} ${RemoteCaddyConfig}.bak.`$TS || true

install -m 600 /tmp/frps.toml.new ${RemoteFrpsConfig}
install -m 644 /tmp/Caddyfile.new ${RemoteCaddyConfig}

systemctl daemon-reload
systemctl enable --now frps
systemctl enable --now caddy
systemctl restart frps
systemctl restart caddy

echo 'frps:'
systemctl is-active frps
echo 'caddy:'
systemctl is-active caddy

echo 'listen ports:'
ss -ltnp | grep -E ':${FrpsBindPort}|:80 |:443 ' || true
"@

$tmpScript = Join-Path $env:TEMP "apply_server_configs.sh"
$remoteScript = $remoteScript -replace [char]0xFEFF, "" -replace "`r`n", "`n" -replace "`r", ""
[IO.File]::WriteAllText($tmpScript, $remoteScript, $utf8NoBom)

Write-Host "应用远端配置并重启服务..." -ForegroundColor Cyan
(Get-Content $tmpScript -Raw) -replace [char]0xFEFF, "" -replace "`r`n", "`n" | & $ssh @sshOptions -p $SshPort -i $SshPrivateKeyPath -o BatchMode=yes "$SshUser@$ServerIp" "bash -s"
Write-Host "更新完成。" -ForegroundColor Green
