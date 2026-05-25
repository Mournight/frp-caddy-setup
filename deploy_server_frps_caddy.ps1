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
foreach ($key in @('SSH_USER', 'SSH_PORT', 'FRPS_BIND_PORT')) {
    if (-not $cfg[$key]) { throw ".env 中缺少必填项: $key" }
}

if (-not $cfg['SSH_HOST'] -and -not $cfg['DOMAIN']) {
    throw ".env 中至少需要提供 SSH_HOST 或 DOMAIN 其中之一。"
}

$ServerHost    = if ($cfg['SSH_HOST']) { $cfg['SSH_HOST'] } else { $cfg['DOMAIN'] }
$SshUser       = $cfg['SSH_USER']
$SshPort       = [int]$cfg['SSH_PORT']
$FrpVersion    = if ($cfg['FRP_VERSION']) { $cfg['FRP_VERSION'] } else { 'latest' }
$FrpsBindPort  = [int]$cfg['FRPS_BIND_PORT']
$EnableBbrv1   = if ($cfg['ENABLE_BBRV1']) { $cfg['ENABLE_BBRV1'] } else { 'true' }

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

$target = "$SshUser@$ServerHost"

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

  # 剥除 CRLF，写入临时文件后通过 bash -s pipe执行
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
ENABLE_BBR="${EnableBbrv1}"

# 自动检测系统版本（仅用于日志输出，不再强制改写软件源，保护 VPS 自带的最佳源）
ID=`$(. /etc/os-release && echo "`$ID")
CODENAME=`$(. /etc/os-release && echo "`$VERSION_CODENAME")
VER=`$(. /etc/os-release && echo "`$VERSION_ID")
echo "检测到系统版本: `$ID `$VER (`$CODENAME)"

# 仅更新系统当前配置的高速源，保留 VPS 原生最快链路
apt-get update
# 安装 Debian 和 Ubuntu 通用的核心依赖包
# 移除了 Debian 专有的 debian-keyring 和 debian-archive-keyring 包以避免在 Ubuntu 系统上报错无法定位软件包
apt-get install -y wget curl tar ufw gnupg apt-transport-https

FRPS_INSTALLED='false'
if [ -x /opt/frp/frps ] && [ -f /etc/systemd/system/frps.service ]; then
  echo '检测到 FRPS 已存在，跳过 FRPS 安装。'
else
  FRP_VERSION='${FrpVersion}'
  if [ -z "`$FRP_VERSION" ] || [ "`$FRP_VERSION" = "latest" ]; then
    echo "正在从 GitHub 获取 FRP 最新版本号..."
    # 优先使用无需 API 凭证的 Location HEAD 重定向机制，避免 GitHub API 的 403 限流
    FRP_VERSION=`$(curl -sI https://github.com/fatedier/frp/releases/latest | grep -Ei '^location:' | awk -F'/tag/v' '{print `$2}' | tr -d '\r\n' || echo "")
    
    # 备用方案：如果重定向抓取失败，再通过官方 API 端口尝试
    if [ -z "`$FRP_VERSION" ]; then
      FRP_VERSION=`$(curl -fsSL https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n1 || echo "")
    fi
    
    # 终极兜底：如果前两者皆因网络原因失效，使用硬编码的已知稳定版本，防止部署被强行挂断
    if [ -z "`$FRP_VERSION" ]; then
      echo "⚠️ 警告：无法实时获取 GitHub 最新版本号（可能被 GitHub 403 限流），已采用硬编码稳定版本 0.61.0 进行兜底安装。"
      FRP_VERSION="0.61.0"
    fi
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

# 自动开启 BBRv1 拥塞控制算法
if [ "`$ENABLE_BBR" = "true" ]; then
  echo "正在配置并开启 BBRv1 拥塞控制算法..."
  if modprobe tcp_bbr 2>/dev/null || lsmod | grep -q bbr; then
    # 确保文件存在，防止极度精简版系统缺失该文件
    touch /etc/sysctl.conf
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p || true
    echo "BBRv1 启用指令已执行，当前算法为: `$(sysctl -n net.ipv4.tcp_congestion_control || echo '未知')"
  else
    echo "⚠️ 警告: 当前系统内核未加载或不支持 BBR 模块，跳过开启。"
  fi
fi

ufw --force enable

# ========================= 部署状态检测与报告 =========================
echo ""
echo "=================================================="
echo "          FRP + Caddy 基础部署状态报告"
echo "=================================================="

# 1. 检测 FRP (FRPS) 状态
FRP_STATUS="❌ 未安装"
FRP_VER="无"
if [ -x /opt/frp/frps ]; then
  FRP_VER=`$(/opt/frp/frps --version 2>/dev/null || echo "未知")
  if systemctl is-enabled frps >/dev/null 2>&1; then
    FRP_STATUS="🟢 已安装并启用开机自启 (v`$FRP_VER)"
  else
    FRP_STATUS="🟡 已安装但未启用服务 (v`$FRP_VER)"
  fi
fi
echo "1. FRP 服务端 (FRPS): `$FRP_STATUS"

# 2. 检测 Caddy 状态
CADDY_STATUS="❌ 未安装"
CADDY_VER="无"
CF_PLUGIN="❌ 未安装"
if command -v caddy >/dev/null 2>&1; then
  CADDY_VER=`$(caddy version 2>/dev/null | cut -d' ' -f1 || echo "未知")
  if systemctl is-enabled caddy >/dev/null 2>&1; then
    CADDY_STATUS="🟢 已安装并启用开机自启 (`$CADDY_VER)"
  else
    CADDY_STATUS="🟡 已安装但未启用服务 (`$CADDY_VER)"
  fi
  
  if caddy list-modules 2>/dev/null | grep -q 'dns.providers.cloudflare'; then
    CF_PLUGIN="🟢 已成功安装"
  else
    CF_PLUGIN="❌ 未安装 (Cloudflare DNS 插件缺失)"
  fi
fi
echo "2. Caddy 反代服务  : `$CADDY_STATUS"
echo "   └─ Cloudflare DNS 插件: `$CF_PLUGIN"

# 3. 检测 BBR v1 状态
BBR_CONFIG="❌ 未开启 (ENABLE_BBRV1=false)"
BBR_ACTIVE="❌ 未生效"
if [ "`$ENABLE_BBR" = "true" ]; then
  BBR_CONFIG="🟢 已在 .env 中开启"
  CURRENT_CONG=`$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
  if [ "`$CURRENT_CONG" = "bbr" ]; then
    BBR_ACTIVE="🟢 已成功激活并生效"
  else
    BBR_ACTIVE="❌ 配置未生效 (当前算法: `$CURRENT_CONG)"
  fi
fi
echo "3. BBR v1 网络加速 :"
echo "   ├─ 配置文件配置: `$BBR_CONFIG"
echo "   └─ 运行状态    : `$BBR_ACTIVE"

# 4. 检测防火墙 (UFW) 状态
UFW_STATUS="❌ 未启用"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  UFW_STATUS="🟢 已启用并处于活动状态"
fi
echo "4. 防火墙保护 (UFW) : `$UFW_STATUS"
echo "=================================================="
echo "提示：基础组件部署成功！"
echo "下一步：请在本地运行 .\update_server_configs.ps1 上传配置文件并正式启动服务。"
echo "=================================================="
echo ""
"@

$tmpScript = Join-Path $env:TEMP "deploy_frps_caddy_remote.sh"
# 剥除 BOM（\uFEFF）及 Windows 换行符，确保 bash 能正确解析
$remoteScript = $remoteScript -replace [char]0xFEFF, "" -replace "`r`n", "`n" -replace "`r", ""
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($tmpScript, $remoteScript, $utf8NoBom)

Ensure-SshKeyAuth

Write-Host "开始基础部署到 $ServerHost ..." -ForegroundColor Cyan
(Get-Content $tmpScript -Raw) -replace [char]0xFEFF, "" -replace "`r`n", "`n" | & $ssh @sshOptions -p $SshPort -i $SshPrivateKeyPath -o BatchMode=yes "$SshUser@$ServerHost" "bash -s"
if ($LASTEXITCODE -ne 0) {
    throw "部署脚本执行失败，请检查上方服务器报错输出。"
}
Write-Host "基础部署执行完毕。" -ForegroundColor Green
