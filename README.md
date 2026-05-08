# FRP + Caddy 一键部署工具

在全新的 Linux 服务器上一键部署 **FRP 内网穿透服务端** + **Caddy HTTPS 反向代理**，从 Windows 本地通过 SSH 远程完成全部操作。

## ✨ 功能

- **FRPS** 自动安装（自动拉取 GitHub 最新版本）
- **Caddy** 自动安装 + Cloudflare DNS 插件（支持泛域名 HTTPS 证书自动签发与续签）
- **UFW 防火墙** 自动配置，仅开放必要端口
- **SSH 密钥** 自动生成并写入服务器（首次需输入一次密码，之后免密）
- **APT 源** 自动检测 Debian 版本（兼容 Debian 11 / 12）
- 所有敏感信息通过 `.env` 文件管理，不会泄露到代码中

## 📋 前置条件

| 条件 | 说明 |
|------|------|
| **本地系统** | Windows 10 / 11，需启用 OpenSSH Client |
| **远程服务器** | Debian 11 或 Debian 12（root 权限） |
| **域名** | 一个域名，DNS 托管在 Cloudflare |
| **Cloudflare API Token** | 用于 DNS-01 验证签发泛域名证书 |

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
SSH_USER=root
SSH_PORT=22
FRPS_BIND_PORT=7000
FRPS_AUTH_TOKEN=你的FRP认证密码
DOMAIN=你的域名.com
CF_DNS_TOKEN=你的Cloudflare_API_Token
```

### 2. 编辑 Caddyfile

打开 `Caddyfile`，添加你需要的子域名反向代理规则：

```
*.{{DOMAIN}}, {{DOMAIN}} {
    tls {
        dns cloudflare {{CF_DNS_TOKEN}}
    }

    # 取消注释并修改为你的子域名和端口
    @myapp host myapp.{{DOMAIN}}
    handle @myapp {
        reverse_proxy 127.0.0.1:你的本地端口
    }

    handle {
        respond "Not Found" 404
    }
}
```

> `{{DOMAIN}}` 和 `{{CF_DNS_TOKEN}}` 是占位符，部署时会自动替换为 `.env` 中的值，**不要手动替换**。

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
- 将 `frps.toml` 和 `Caddyfile` 中的占位符替换为实际值
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
| `Caddyfile` | Caddy 反向代理配置模板 |

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
- 首次部署时如果你的服务器在境外，确保本地网络可以访问（可能需要代理）
- FRP 客户端的 `auth.token` 必须与 `.env` 中的 `FRPS_AUTH_TOKEN` 保持一致
