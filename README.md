# Traefik 自动部署工具

这是一个用于自动部署和配置 Traefik 的一键安装工具。它提供了完整的 HTTPS 支持、安全配置和 Dashboard 访问功能。

## 特性

- 一键远程安装
- 自动配置 HTTP 到 HTTPS 重定向
- 自动申请和更新 SSL 证书 (Let's Encrypt)
- 安全的 Dashboard 访问（随机生成用户名和密码）
- 动态配置文件管理
- 完整的安全配置
- 自动配置 Docker 网络
- 支持所有主流 Linux 发行版

## 快速开始

使用以下命令一键安装：

```bash
curl -fsSL https://raw.githubusercontent.com/laughinbytes/traefik-deploy/main/install.sh | sudo bash
```

安装过程中需要输入：
- 用于 Let's Encrypt 证书通知的邮箱地址
- Traefik Dashboard 的域名

## 系统要求

- Linux 操作系统
- Root 权限
- 互联网连接
- 80 和 443 端口可访问
- 域名已正确解析到服务器 IP

## 配置说明

### 目录结构

```
/etc/traefik/
├── traefik.yml           # 主配置文件
├── docker-compose.yml    # Docker Compose 配置
├── dynamic/             # 动态配置目录
│   └── middleware.yml   # 中间件配置
└── acme/               # SSL 证书存储
```

### 主要配置文件

1. `traefik.yml`: Traefik 的主要配置文件
2. `docker-compose.yml`: 定义 Traefik 容器的配置
3. `dynamic/middleware.yml`: 包含安全中间件配置

## 安全特性

- 自动 HTTPS 重定向
- 安全的 HTTP 头配置
- 速率限制
- Dashboard 访问认证（随机用户名密码）

## 自定义配置

安装完成后，你可以修改以下配置：

1. 编辑 `/etc/traefik/traefik.yml` 更改基础配置
2. 在 `/etc/traefik/dynamic/` 添加或修改动态配置
3. 修改 `docker-compose.yml` 调整容器配置

## 维护

### 更新 Traefik

```bash
cd /etc/traefik
docker-compose pull
docker-compose up -d
```

### 查看日志

```bash
docker-compose logs -f traefik
```

## 故障排除

1. 检查 Traefik 状态：
```bash
docker-compose ps
```

2. 检查日志：
```bash
docker-compose logs -f
```

3. 验证配置：
```bash
docker-compose config
```

## 贡献

欢迎提交 Pull Requests 和 Issues！

## 许可证

MIT License
