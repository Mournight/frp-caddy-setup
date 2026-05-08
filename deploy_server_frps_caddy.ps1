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
foreach ($key in @('DOMAIN', 'SSH_USER', 'SSH_PORT', 'FRPS_BIND_PORT')) {
    if (-not $cfg[$key]) { throw ".env 中缺少必填项: $key" }
}

$ServerIp      = $cfg['DOMAIN']
$SshUser       = $cfg['SSH_USER']
$SshPort       = [int]$cfg['SSH_PORT']
$FrpVersion    = if ($cfg['FRP_VERSION']) { $cfg['FRP_VERSION'] } else { 'latest' }
$FrpsBindPort  = [int]$cfg['FRPS_BIND_PORT']

# SSH 私钥路径（已有密钥则直接使用，不会覆盖）
$SshPrivateKeyPath = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
# 是否自动接收新主机指纹（首次连接建议 true）
$AcceptNewHostKey = $true

# ========================= SSH 工具 =========================
function Get-OpenSshTool([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "未找到 $Name。请先启用 Windows OpenSSH Client。"
}

$ssh = Get-OpenSshTool "ssh.exe"
$sshKeygen = Get-OpenSshTool "ssh-keygen.exe"

$sshOptions = @()
if ($AcceptNewHostKey) {
  $sshOptions += @("-o", "StrictHostKeyChecking=accept-new")
}

$target = "$SshUser@$ServerIp"

function Test-KeyLogin {
  & $ssh @sshOptions -p $SshPort -i $SshPrivateKeyPath -o BatchMode=yes $target "echo key-auth-ok" | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Ensure-SshKeyAuth {
  if (-not (Test-Path $SshPrivateKeyPath)) {
    $keyDir = Split-Path -Parent $SshPrivateKeyPath
    if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
    & $sshKeygen -t ed25519 -f $SshPrivateKeyPath -N "" -C "frp-deploy@$env:COMPUTERNAME" | Out-Null
  }

  if (Test-KeyLogin) {
    Write-Host "SSH 密钥已可用，后续将使用免密连接。" -ForegroundColor Green
    return
  }

  Write-Host "正在配置服务器 authorized_keys（将提示你输入一次 SSH 密码）..." -ForegroundColor Yellow
  $pubKeyPath = "$SshPrivateKeyPath.pub"
  if (-not (Test-Path $pubKeyPath)) {
    throw "未找到公钥文件: $pubKeyPath"
  }

  $pubKeyContent = (Get-Content $pubKeyPath -Raw).Trim()
  $passwordAuthOptions = @(
    "-o", "PubkeyAuthentication=no",
    "-o", "PreferredAuthentications=password,keyboard-interactive"
  )
  # 写入公钥，同时确保 sshd_config 中 PubkeyAuthentication 为 yes 并重启 sshd
  $remoteAddKeyCmd = @"
umask 077
mkdir -p ~/.ssh
touch ~/.ssh/authorized_keys
grep -qxF "$pubKeyContent" ~/.ssh/authorized_keys || printf '%s\n' "$pubKeyContent" >> ~/.ssh/authorized_keys
sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys
# 启用密钥登录
if grep -qE '^[[:space:]]*#*[[:space:]]*PubkeyAuthentication' /etc/ssh/sshd_config; then
  sed -i 's/^[[:space:]]*#*[[:space:]]*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
else
  echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
fi
systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
"@

  # 剥除 CRLF，写入临时文件后通过 bash -s pipe 执行
  $tmpAddKeyScript = Join-Path $env:TEMP "add_authorized_key.sh"
  $addKeyCmdClean = $remoteAddKeyCmd -replace [char]0xFEFF, "" -replace "`r`n", "`n" -replace "`r", ""
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [IO.File]::WriteAllText($tmpAddKeyScript, $addKeyCmdClean, $utf8NoBom)

  (Get-Content $tmpAddKeyScript -Raw) | & $ssh @sshOptions @passwordAuthOptions -p $SshPort $target "bash -s"
  if ($LASTEXITCODE -ne 0) {
    throw "写入服务器 authorized_keys 失败。"
  }

  # sshd 重启需要片刻，等待后再验证
  Start-Sleep -Seconds 3

  if (-not (Test-KeyLogin)) {
    throw "SSH 密钥登录验证失败，请检查服务器 SSH 配置。"
  }

  Write-Host "SSH 密钥配置完成，后续连接无需密码。" -ForegroundColor Green
}

$remoteScript = @"
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

CODENAME=`$(. /etc/os-release && echo "`$VERSION_CODENAME")
if [ -z "`$CODENAME" ]; then
  echo '无法检测系统版本代号，中止部署。'
  exit 1
fi

VER=`$(. /etc/os-release && echo "`$VERSION_ID")
NFW=''
if [ "`$VER" -ge 12 ] 2>/dev/null; then
  NFW=' non-free-firmware'
fi

echo "检测到系统版本: Debian `$VER (`$CODENAME)"

{
  echo "deb http://deb.debian.org/debian `$CODENAME main contrib non-free`$NFW"
  echo "deb http://deb.debian.org/debian `$CODENAME-updates main contrib non-free`$NFW"
  echo "deb http://security.debian.org/debian-security `$CODENAME-security main contrib non-free`$NFW"
} > /etc/apt/sources.list

apt-get clean
rm -rf /var/lib/apt/lists/*
apt-get update
apt-get install -y wget curl tar ufw gnupg debian-keyring debian-archive-keyring apt-transport-https

FRPS_INSTALLED='false'
if [ -x /opt/frp/frps ] && [ -f /etc/systemd/system/frps.service ]; then
  echo '检测到 FRPS 已存在，跳过 FRPS 安装。'
else
  FRP_VERSION='${FrpVersion}'
  if [ -z "`$FRP_VERSION" ] || [ "`$FRP_VERSION" = "latest" ]; then
    FRP_VERSION=`$(curl -fsSL https://api.github.com/repos/fatedier/frp/releases/latest | sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n1)
  fi

  if [ -z "`$FRP_VERSION" ]; then
    echo '无法获取 FRP 最新版本号，请检查网络后重试。'
    exit 1
  fi

  ARCHIVE="frp_`${FRP_VERSION}_linux_amd64.tar.gz"
  URL="https://github.com/fatedier/frp/releases/download/v`${FRP_VERSION}/`$ARCHIVE"
  cd /tmp
  wget -O "`$ARCHIVE" "`$URL"
  tar -xzf "`$ARCHIVE"
  install -d /opt/frp /etc/frp
  install -m 755 "/tmp/frp_`${FRP_VERSION}_linux_amd64/frps" /opt/frp/frps

  cat >/etc/systemd/system/frps.service <<'EOF'
[Unit]
Description=FRP Server
After=network.target

[Service]
Type=simple
ExecStart=/opt/frp/frps -c /etc/frp/frps.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  FRPS_INSTALLED='true'
fi

CADDY_INSTALLED='false'
if command -v caddy >/dev/null 2>&1; then
  echo '检测到 Caddy 已存在，跳过 Caddy 安装。'
else
  install -m 0755 -d /etc/apt/keyrings
  rm -f /etc/apt/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --batch --yes -o /etc/apt/keyrings/caddy-stable-archive-keyring.gpg
  chmod a+r /etc/apt/keyrings/caddy-stable-archive-keyring.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main' >/etc/apt/sources.list.d/caddy-stable.list

  apt-get update
  apt-get install -y caddy
  CADDY_INSTALLED='true'
fi

if caddy list-modules | grep -q 'dns.providers.cloudflare'; then
  echo '检测到 Caddy 已安装 Cloudflare DNS 插件。'
else
  echo '正在安装 Caddy Cloudflare DNS 插件...'
  caddy add-package github.com/caddy-dns/cloudflare || echo '安装 Caddy 插件失败，请检查网络或手动编译。'
  systemctl restart caddy || true
fi

systemctl enable frps >/dev/null 2>&1 || true
systemctl enable caddy >/dev/null 2>&1 || true

ufw allow ${SshPort}/tcp
ufw allow ${FrpsBindPort}/tcp
ufw allow 80/tcp
ufw allow 443/tcp
"@

$remoteScript += @"
ufw --force enable

echo '=== BASE DEPLOY DONE ==='
echo 'FRP binary:'
/opt/frp/frps --version || true
echo 'caddy:'
caddy version || true
echo 'frps service enabled:'
systemctl is-enabled frps || true
echo 'caddy service enabled:'
systemctl is-enabled caddy || true
echo "FRPS installed this run: `$FRPS_INSTALLED"
echo "Caddy installed this run: `$CADDY_INSTALLED"
echo '下一步：运行 update_server_configs.ps1 上传 frps.toml 和 Caddyfile 并启动/重载服务。'
"@

$tmpScript = Join-Path $env:TEMP "deploy_frps_caddy_remote.sh"
# 剥除 BOM（\uFEFF）及 Windows 换行符，确保 bash 能正确解析
$remoteScript = $remoteScript -replace [char]0xFEFF, "" -replace "`r`n", "`n" -replace "`r", ""
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($tmpScript, $remoteScript, $utf8NoBom)

Ensure-SshKeyAuth

Write-Host "开始基础部署到 $ServerIp ..." -ForegroundColor Cyan
(Get-Content $tmpScript -Raw) -replace [char]0xFEFF, "" -replace "`r`n", "`n" | & $ssh @sshOptions -p $SshPort -i $SshPrivateKeyPath -o BatchMode=yes "$SshUser@$ServerIp" "bash -s"
Write-Host "基础部署完成。" -ForegroundColor Green
