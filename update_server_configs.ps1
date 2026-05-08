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
foreach ($key in @('SSH_USER', 'SSH_PORT', 'FRPS_BIND_PORT', 'FRPS_AUTH_TOKEN')) {
    if (-not $cfg[$key]) { throw ".env 中缺少必填项: $key" }
}
if (-not $cfg['SSH_HOST'] -and -not $cfg['DOMAIN']) {
    throw ".env 中至少需要提供 SSH_HOST 或 DOMAIN 其中之一。"
}

$ServerHost       = if ($cfg['SSH_HOST']) { $cfg['SSH_HOST'] } else { $cfg['DOMAIN'] }
$SshUser          = $cfg['SSH_USER']
$SshPort          = [int]$cfg['SSH_PORT']
$FrpsBindPort     = [int]$cfg['FRPS_BIND_PORT']
$AcceptNewHostKey = $true
$SshPrivateKeyPath = Join-Path $env:USERPROFILE ".ssh\id_ed25519"

# ========================= 本地配置文件 =========================
$LocalFrpsConfig  = Join-Path $PSScriptRoot "frps.toml"
$LocalCaddyConfig = Join-Path $PSScriptRoot "Caddyfile"
$LocalBackupDir   = Join-Path $PSScriptRoot ".backups"

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

function Assert-LastExitCode([string]$Action) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Action 失败，退出码: $LASTEXITCODE"
    }
}

function Show-RemoteServiceLogs([string]$Reason) {
    try {
        Write-Host "更新失败：$Reason" -ForegroundColor Yellow
        Write-Host "正在回显远端 frps / caddy 日志..." -ForegroundColor Yellow

        $logScript = @"
set +e
echo '=== frps status ==='
systemctl status frps --no-pager -l || true
echo '=== frps journal (last 80) ==='
journalctl -u frps -n 80 --no-pager || true
echo '=== caddy status ==='
systemctl status caddy --no-pager -l || true
echo '=== caddy journal (last 120) ==='
journalctl -u caddy -n 120 --no-pager || true
"@

        $logScript = $logScript -replace [char]0xFEFF, "" -replace "`r`n", "`n" -replace "`r", ""
        ($logScript -replace [char]0xFEFF, "" -replace "`r`n", "`n") | & $ssh @sshOptions -p $SshPort -i $SshPrivateKeyPath -o BatchMode=yes "$SshUser@$ServerHost" "bash -s"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "拉取远端服务日志失败，退出码: $LASTEXITCODE"
        }
    }
    catch {
        Write-Warning "拉取远端服务日志失败：$($_.Exception.Message)"
    }
}

$ssh = Get-OpenSshTool "ssh.exe"
$scp = Get-OpenSshTool "scp.exe"

$sshOptions = @()
if ($AcceptNewHostKey) {
  $sshOptions += @("-o", "StrictHostKeyChecking=accept-new")
}

# ========================= 生成配置文件 =========================
Write-Host "正在准备配置文件..." -ForegroundColor Cyan

$frpsContent = Expand-Template -Content (Get-Content $LocalFrpsConfig -Raw -Encoding UTF8) -Vars @{
    'FRPS_BIND_PORT' = $cfg['FRPS_BIND_PORT']
    'FRPS_AUTH_TOKEN' = $cfg['FRPS_AUTH_TOKEN']
}

$caddyContent = Get-Content $LocalCaddyConfig -Raw -Encoding UTF8
if ($caddyContent -match '\{\{.+?\}\}') {
    throw "检测到 Caddyfile 中仍包含旧版模板占位符。`n请复制 Caddyfile.example 为 Caddyfile，并把其中的域名、Cloudflare Token 与反代端口改成你的真实值后再执行。"
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$tmpFrps  = Join-Path $env:TEMP "frps.toml.upload"
$tmpCaddy = Join-Path $env:TEMP "Caddyfile.upload"

# 写入时去除 BOM 和 CRLF
$frpsClean  = ($frpsContent  -replace [char]0xFEFF, "" -replace "`r`n", "`n" -replace "`r", "")
$caddyClean = ($caddyContent -replace [char]0xFEFF, "" -replace "`r`n", "`n" -replace "`r", "")
[IO.File]::WriteAllText($tmpFrps,  $frpsClean,  $utf8NoBom)
[IO.File]::WriteAllText($tmpCaddy, $caddyClean, $utf8NoBom)

try {
    Write-Host "上传配置文件到远端..." -ForegroundColor Cyan
    & $scp @sshOptions -i $SshPrivateKeyPath -o BatchMode=yes -P $SshPort $tmpFrps  "${SshUser}@${ServerHost}:/tmp/frps.toml.new"
    Assert-LastExitCode "上传 frps.toml"
    & $scp @sshOptions -i $SshPrivateKeyPath -o BatchMode=yes -P $SshPort $tmpCaddy "${SshUser}@${ServerHost}:/tmp/Caddyfile.new"
    Assert-LastExitCode "上传 Caddyfile"

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

if ! systemctl is-active --quiet frps; then
  echo 'frps 启动失败，最近日志：'
  journalctl -u frps -n 80 --no-pager || true
  exit 1
fi

if ! systemctl is-active --quiet caddy; then
  echo 'caddy 启动失败，最近日志：'
  journalctl -u caddy -n 120 --no-pager || true
  exit 1
fi

 BACKUP_FILE="/tmp/server-state-backup-`$TS.tar.gz"
 BACKUP_ITEMS=()
 for path in /etc/caddy /etc/frp /var/lib/caddy/.local/share/caddy /var/lib/caddy/.config/caddy; do
   if [ -e "`$path" ]; then
     BACKUP_ITEMS+=("`${path#/}")
   fi
 done
 
 if [ "`${#BACKUP_ITEMS[@]}" -eq 0 ]; then
     echo '未找到可备份的 Caddy / FRP 数据目录。'
     exit 1
 fi

tar -C / -czf "`$BACKUP_FILE" "`${BACKUP_ITEMS[@]}" 

echo 'frps:'
systemctl is-active frps
echo 'caddy:'
systemctl is-active caddy

echo 'listen ports:'
ss -ltnp | grep -E ':${FrpsBindPort}|:80 |:443 ' || true
echo "BACKUP_PATH=`$BACKUP_FILE"
"@

    $tmpScript = Join-Path $env:TEMP "apply_server_configs.sh"
    $remoteScript = $remoteScript -replace [char]0xFEFF, "" -replace "`r`n", "`n" -replace "`r", ""
    [IO.File]::WriteAllText($tmpScript, $remoteScript, $utf8NoBom)

    Write-Host "应用远端配置并重启服务..." -ForegroundColor Cyan
    $remoteOutput = (Get-Content $tmpScript -Raw) -replace [char]0xFEFF, "" -replace "`r`n", "`n" | & $ssh @sshOptions -p $SshPort -i $SshPrivateKeyPath -o BatchMode=yes "$SshUser@$ServerHost" "bash -s"
    if ($remoteOutput) {
        $remoteOutput | ForEach-Object { Write-Host $_ }
    }
    Assert-LastExitCode "应用远端配置并重启服务"

    $backupLine = $remoteOutput | Where-Object { $_ -like 'BACKUP_PATH=*' } | Select-Object -Last 1
    if (-not $backupLine) {
        throw "远端更新未返回备份文件路径，视为失败。"
    }

    $remoteBackupPath = $backupLine.Substring("BACKUP_PATH=".Length)
    $localBackupPath = Join-Path $LocalBackupDir (Split-Path -Path $remoteBackupPath -Leaf)

    Write-Host "下载远端备份到本地..." -ForegroundColor Cyan
    & $scp @sshOptions -i $SshPrivateKeyPath -o BatchMode=yes -P $SshPort "${SshUser}@${ServerHost}:${remoteBackupPath}" $localBackupPath
    Assert-LastExitCode "下载远端备份"

    & $ssh @sshOptions -p $SshPort -i $SshPrivateKeyPath -o BatchMode=yes "$SshUser@$ServerHost" "rm -f '$remoteBackupPath'"
    Assert-LastExitCode "清理远端临时备份"

    Write-Host "更新完成。备份已保存到 $localBackupPath" -ForegroundColor Green
}
catch {
    Show-RemoteServiceLogs -Reason $_.Exception.Message
    throw
}
