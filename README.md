# FRP + Caddy 一键部署工具

在全新的 Linux 服务器上一键部署 **FRP 内网穿透服务端** + **Caddy HTTPS 反向代理**，从 Windows 本地通过 SSH 远程完成全部操作。

## ✨ 功能

- **FRPS** 自动安装（自动拉取 GitHub 最新版本）
- **Caddy** 自动安装 + Cloudflare DNS 插件（支持泛域名 HTTPS 证书自动签发与续签）
- **UFW 防火墙** 自动配置，仅开放必要端口
- **SSH 密钥** 自动生成并写入服务器（首次需输入一次密码，之后免密）
- **APT 源** 自动检测 Debian 版本（兼容 Debian 11 / 12）
- 所有敏感信息保存在 `.env` 或本地忽略文件中，不会进入 Git 仓库

## 📋 前置条件

| 条件 | 说明 |
|------|------|
| **本地系统** | Windows 10 / 11，需启用 OpenSSH Client |
| **远程服务器** | Debian 11 或 Debian 12（root 权限） |
| **域名** | 一个域名，DNS 托管在 Cloudflare |
| **Cloudflare API Token** | 用于 DNS-01 验证签发泛域名证书 |

## ⚠️ 先做这一步：把 SSH 端口改到 2222

如果你是第一次拿到服务器，**请先去云服务商自带的网页控制台 / 串口控制台 / VNC 控制台**，用 root 登录后粘贴下面这段命令。

这样做的原因很简单：**22 端口在很多网络、代理链路、运营商出口和云厂商风控链路里会被特殊处理**。改成 `2222` 后，远程连接通常会稳定很多。

```bash
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
grep -q '^Port 2222$' /etc/ssh/sshd_config || printf '\nPort 2222\n' >> /etc/ssh/sshd_config
sshd -t && (ufw allow 2222/tcp >/dev/null 2>&1 || true) && (systemctl restart ssh || systemctl restart sshd)
ss -ltnp | grep ':2222'
```

如果最后一行能看到 `:2222`，说明修改成功。后续本项目的脚本也默认按 `2222` 来连接。

### 获取 Cloudflare API Token

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/profile/api-tokens)
2. 点击 **Create Token** → 使用 **Edit zone DNS** 模板
3. 选择你的域名所在 Zone，生成 Token 并复制

## 🚀 快速开始

### 1. 配置环境变量

```powershell
Copy-Item .env.example .env
```

编辑 `.env`，填入你的服务器信息：

```env
SSH_HOST=你的服务器公网IP
SSH_USER=root
SSH_PORT=2222
FRPS_BIND_PORT=7000
FRPS_AUTH_TOKEN=你的FRP认证密码
```

其中：
- `SSH_HOST`：用于 SSH / SCP 连接服务器，推荐填写公网 IP
- `SSH_PORT`：推荐填写 `2222`

### 2. 编辑 Caddyfile

先复制示例文件：

```powershell
Copy-Item .\Caddyfile.example .\Caddyfile
```

然后编辑本地 `Caddyfile`，把里面的域名、Cloudflare Token 和反向代理端口改成你的真实值。

`Caddyfile` 会被 `.gitignore` 忽略，**不会提交到 Git**；仓库里只保留 `Caddyfile.example` 作为示例。

```caddyfile
*.1dea.top, 1dea.top {
    tls {
        dns cloudflare your-cloudflare-api-token
    }

    # 取消注释并修改为你的子域名和端口
    @myapp host myapp.1dea.top
    handle @myapp {
        reverse_proxy 127.0.0.1:你的本地端口
    }

    handle {
        respond "Not Found" 404
    }
}
```

### 3. 运行基础部署

```powershell
.\deploy_server_frps_caddy.ps1
```

这一步会：
- 自动配置 SSH 密钥免密登录（首次需输入一次服务器密码）
- 安装 FRPS、Caddy、UFW
- 配置防火墙规则

### 4. 上传配置并启动服务

```powershell
.\update_server_configs.ps1
```

这一步会：
- 上传本地 `frps.toml` 和 `Caddyfile`
- 上传到服务器并验证 Caddy 配置
- 启动 / 重启 FRPS 和 Caddy 服务

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `.env.example` | 环境变量模板，复制为 `.env` 后填写 |
| `.env` | **你的实际配置（已被 .gitignore 忽略）** |
| `deploy_server_frps_caddy.ps1` | 基础部署脚本（安装软件 + 防火墙） |
| `update_server_configs.ps1` | 配置上传脚本（推送配置 + 重启服务） |
| `frps.toml` | FRP 服务端配置模板 |
| `Caddyfile.example` | Caddy 配置示例文件（可提交到 Git） |
| `Caddyfile` | **你的实际 Caddy 配置（已被 .gitignore 忽略）** |

## 🔧 日常维护

**修改子域名路由或 FRP 配置后**，只需重新运行：

```powershell
.\update_server_configs.ps1
```

**需要重新安装软件**（如升级 FRP 版本），删除服务器上的旧文件后重新运行：

```powershell
.\deploy_server_frps_caddy.ps1
```

## ⚠️ 注意事项

- `.env` 文件包含敏感信息，**绝对不要提交到 Git**（已在 `.gitignore` 中排除）
- `Caddyfile` 中通常会包含真实域名、Cloudflare Token 或内网端口，**也不要提交到 Git**
- 如果本地启用了 Clash Fake IP、代理 DNS 或其他特殊网络环境，**务必填写 `SSH_HOST` 为服务器真实公网 IP**
- 首次部署时如果你的服务器在境外，确保本地网络可以访问（可能需要代理）
- FRP 客户端的 `auth.token` 必须与 `.env` 中的 `FRPS_AUTH_TOKEN` 保持一致
