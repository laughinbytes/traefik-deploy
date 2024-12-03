#!/bin/bash

# 颜色定义
TRAEFIK_RED='\033[0;31m'
TRAEFIK_GREEN='\033[0;32m'
TRAEFIK_YELLOW='\033[1;33m'
TRAEFIK_NC='\033[0m'

# 打印带颜色的信息
log_info() {
    echo -e "${TRAEFIK_GREEN}[INFO]${TRAEFIK_NC} $1"
}

log_warn() {
    echo -e "${TRAEFIK_YELLOW}[WARN]${TRAEFIK_NC} $1"
}

log_error() {
    echo -e "${TRAEFIK_RED}[ERROR]${TRAEFIK_NC} $1"
}

# 回滚函数
rollback() {
    local error_msg="$1"
    log_error "安装失败: $error_msg"
    log_warn "开始回滚..."
    
    # 停止并删除所有Docker容器和网络
    if command -v docker >/dev/null; then
        log_info "清理Docker资源..."
        docker compose -f /etc/traefik/docker-compose.yml down 2>/dev/null || true
        docker network rm traefik_proxy 2>/dev/null || true
        
        # 清理所有相关容器
        docker ps -a | grep "traefik" | awk '{print $1}' | xargs -r docker rm -f 2>/dev/null || true
    fi
    
    # 删除证书和配置
    log_info "清理证书和配置..."
    rm -rf /etc/traefik
    
    # 如果Docker是由脚本安装的，则卸载Docker
    if [ -f "/etc/docker/daemon.json" ]; then
        log_info "卸载Docker..."
        if [ "$TRAEFIK_PKG_MANAGER" = "apt-get" ]; then
            apt-get remove --purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true
        elif [ "$TRAEFIK_PKG_MANAGER" = "yum" ] || [ "$TRAEFIK_PKG_MANAGER" = "dnf" ]; then
            $TRAEFIK_PKG_MANAGER remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
            $TRAEFIK_PKG_MANAGER autoremove -y 2>/dev/null || true
        fi
        
        # 清理Docker相关文件
        rm -rf /var/lib/docker
        rm -rf /var/lib/containerd
        rm -rf /etc/docker
    fi
    
    log_warn "系统已回滚到初始状态"
    exit 1
}

# 错误处理函数
handle_error() {
    local exit_code=$?
    local error_msg="$1"
    if [ $exit_code -ne 0 ]; then
        rollback "$error_msg"
    fi
}

# 检查系统要求
check_system_requirements() {
    log_info "检查系统要求..."
    
    # 检查是否为root用户
    if [ "$EUID" -ne 0 ]; then 
        log_error "请使用root权限运行此脚本"
        exit 1
    fi

    # 检查系统包管理器
    if command -v apt-get >/dev/null; then
        TRAEFIK_PKG_MANAGER="apt-get"
    elif command -v yum >/dev/null; then
        TRAEFIK_PKG_MANAGER="yum"
    elif command -v dnf >/dev/null; then
        TRAEFIK_PKG_MANAGER="dnf"
    else
        log_error "不支持的包管理器"
        exit 1
    fi
}

# 检查系统环境
check_environment() {
    log_info "检查系统环境..."
    
    # 检查必要的系统工具
    local required_tools="curl wget dig docker"
    for tool in $required_tools; do
        if ! command -v "$tool" >/dev/null; then
            log_error "缺少必要工具: $tool"
            return 1
        fi
    done
    
    # 检查系统资源
    log_info "检查系统资源..."
    
    # 检查内存
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$total_mem" -lt 1024 ]; then
        log_warn "系统内存小于1GB，可能影响性能"
    fi
    
    # 检查磁盘空间
    local free_space=$(df -m /var/lib/docker | awk 'NR==2 {print $4}')
    if [ "$free_space" -lt 1024 ]; then
        log_warn "Docker目录剩余空间小于1GB"
    fi
    
    # 检查端口占用
    log_info "检查端口占用..."
    local ports="80 443"
    for port in $ports; do
        if ss -tln | grep -q ":$port "; then
            log_error "端口 $port 已被占用"
            ss -tlnp | grep ":$port"
            return 1
        fi
    done
    
    # 检查防火墙状态
    if command -v ufw >/dev/null; then
        log_info "检查UFW防火墙状态..."
        if ufw status | grep -q "Status: active"; then
            if ! ufw status | grep -qE "80.*(ALLOW|允许)"; then
                log_warn "UFW防火墙可能阻止80端口"
            fi
            if ! ufw status | grep -qE "443.*(ALLOW|允许)"; then
                log_warn "UFW防火墙可能阻止443端口"
            fi
        fi
    fi
    
    # 检查SELinux状态
    if command -v getenforce >/dev/null; then
        log_info "检查SELinux状态..."
        if [ "$(getenforce)" = "Enforcing" ]; then
            log_warn "SELinux处于强制模式，可能需要配置策略"
        fi
    fi
    
    # 检查系统时间同步
    log_info "检查系统时间同步..."
    if ! command -v ntpstat >/dev/null && ! command -v timedatectl >/dev/null; then
        log_warn "未安装时间同步服务"
    elif command -v timedatectl >/dev/null; then
        if ! timedatectl status | grep -q "synchronized: yes"; then
            log_warn "系统时间未同步，可能影响证书验证"
        fi
    fi
    
    log_info "环境检查完成"
    return 0
}

# 安装依赖
install_dependencies() {
    log_info "安装必要依赖..."
    
    if [ "$TRAEFIK_PKG_MANAGER" = "apt-get" ]; then
        apt-get update || handle_error "更新包管理器失败"
        apt-get install -y curl wget git dnsutils || handle_error "安装基础依赖失败"
    elif [ "$TRAEFIK_PKG_MANAGER" = "yum" ] || [ "$TRAEFIK_PKG_MANAGER" = "dnf" ]; then
        $TRAEFIK_PKG_MANAGER update -y || handle_error "更新包管理器失败"
        $TRAEFIK_PKG_MANAGER install -y curl wget git bind-utils || handle_error "安装基础依赖失败"
    fi
}

# 安装Docker
install_docker() {
    log_info "检查Docker..."
    if ! command -v docker >/dev/null; then
        log_info "安装Docker..."
        curl -fsSL https://get.docker.com | sh || handle_error "安装Docker失败"
        systemctl enable docker || handle_error "启用Docker服务失败"
        systemctl start docker || handle_error "启动Docker服务失败"
    else
        log_info "Docker已安装"
    fi
}

# 安装 Docker Compose
install_docker_compose() {
    log_info "检查 Docker Compose..."
    
    # 首先检查 docker compose 命令是否可用
    if docker compose version >/dev/null 2>&1; then
        log_info "Docker Compose (插件版本) 已可用"
        return 0
    fi
    
    # 获取 Docker 版本
    DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
    if [ -z "$DOCKER_VERSION" ]; then
        handle_error "无法获取 Docker 版本"
    fi
    
    # 如果 Docker 版本 >= 23.0，说明应该自带 compose 插件，可能是安装不完整
    if [ "$(printf '%s\n' "23.0" "$DOCKER_VERSION" | sort -V | head -n1)" = "23.0" ]; then
        log_warn "Docker $DOCKER_VERSION 应该包含 Compose 插件，尝试修复安装..."
        if [ "$TRAEFIK_PKG_MANAGER" = "apt-get" ]; then
            apt-get install -y docker-ce-cli || handle_error "安装 Docker CLI 失败"
        elif [ "$TRAEFIK_PKG_MANAGER" = "yum" ] || [ "$TRAEFIK_PKG_MANAGER" = "dnf" ]; then
            $TRAEFIK_PKG_MANAGER install -y docker-ce-cli || handle_error "安装 Docker CLI 失败"
        fi
    else
        # 对于旧版本 Docker，安装 compose 插件
        log_info "Docker 版本 < 23.0，安装 Compose 插件..."
        if [ "$TRAEFIK_PKG_MANAGER" = "apt-get" ]; then
            apt-get install -y docker-compose-plugin || handle_error "安装 Docker Compose 插件失败"
        elif [ "$TRAEFIK_PKG_MANAGER" = "yum" ] || [ "$TRAEFIK_PKG_MANAGER" = "dnf" ]; then
            $TRAEFIK_PKG_MANAGER install -y docker-compose-plugin || handle_error "安装 Docker Compose 插件失败"
        fi
    fi
    
    # 最终验证
    if ! docker compose version >/dev/null 2>&1; then
        handle_error "Docker Compose 安装验证失败"
    fi
    
    log_info "Docker Compose 可用"
    return 0
}

# 创建必要的目录
create_directories() {
    log_info "创建必要的目录..."
    
    # 创建 Traefik 配置目录
    mkdir -p /etc/traefik/dynamic
    mkdir -p /etc/traefik/acme
    
    # 设置适当的权限
    chmod 600 /etc/traefik/acme
    
    log_info "目录创建完成"
}

# 生成密码
generate_password() {
    log_info "生成Dashboard密码..."
    if ! command -v htpasswd >/dev/null; then
        if [ "$TRAEFIK_PKG_MANAGER" = "apt-get" ]; then
            apt-get install -y apache2-utils || handle_error "安装htpasswd失败"
        else
            $TRAEFIK_PKG_MANAGER install -y httpd-tools || handle_error "安装htpasswd失败"
        fi
    fi
    
    # 生成随机用户名和密码
    TRAEFIK_DASHBOARD_USER=$(openssl rand -hex 6) || handle_error "生成用户名失败"
    TRAEFIK_DASHBOARD_PASSWORD=$(openssl rand -base64 12) || handle_error "生成密码失败"
    
    # 创建密码文件
    htpasswd -bc /etc/traefik/dashboard_users.htpasswd "$TRAEFIK_DASHBOARD_USER" "$TRAEFIK_DASHBOARD_PASSWORD" || handle_error "创建密码文件失败"
    
    # 写入到环境文件
    {
        echo "TRAEFIK_DASHBOARD_USER=$TRAEFIK_DASHBOARD_USER"
        echo "TRAEFIK_DASHBOARD_PASSWORD=$TRAEFIK_DASHBOARD_PASSWORD"
    } >> /etc/traefik/.env
    
    return 0
}

# 下载配置文件
download_configs() {
    log_info "下载配置文件..."
    
    # 下载 traefik.yml
    cat > /etc/traefik/traefik.yml << 'EOL'
api:
  dashboard: true
  debug: true

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https

  websecure:
    address: ":443"
    http:
      middlewares:
        - secureHeaders@file
      tls:
        certResolver: letsencrypt

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik_proxy
  file:
    filename: /etc/traefik/dynamic.yml

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${TRAEFIK_ACME_EMAIL}
      storage: /etc/traefik/acme/acme.json
      httpChallenge:
        entryPoint: web
EOL
    
    # 下载 docker-compose.yml
    cat > /etc/traefik/docker-compose.yml << 'EOL'
version: '3'

services:
  traefik:
    image: traefik:v2.10
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - traefik_proxy
    ports:
      - 80:80
      - 443:443
    environment:
      - TRAEFIK_DOMAIN=${TRAEFIK_DOMAIN}
      - TRAEFIK_ACME_EMAIL=${TRAEFIK_ACME_EMAIL}
      - TRAEFIK_BASIC_AUTH=${TRAEFIK_BASIC_AUTH}
    volumes:
      - /etc/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - /etc/traefik/dynamic.yml:/etc/traefik/dynamic.yml:ro
      - /etc/traefik/acme:/etc/traefik/acme
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard.rule=Host(`${TRAEFIK_DOMAIN}`) && (PathPrefix(`/api`) || PathPrefix(`/dashboard`))"
      - "traefik.http.routers.dashboard.service=api@internal"
      - "traefik.http.routers.dashboard.middlewares=auth"
      - "traefik.http.middlewares.auth.basicauth.users=${TRAEFIK_BASIC_AUTH}"

networks:
  traefik_proxy:
    external: true
EOL
    
    # 下载 dynamic.yml
    cat > /etc/traefik/dynamic.yml << 'EOL'
http:
  middlewares:
    secureHeaders:
      headers:
        sslRedirect: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 31536000
EOL
    
    return 0
}

# 启动 Traefik
start_traefik() {
    log_info "启动 Traefik 服务..."
    
    # 生成基本认证信息
    if ! generate_basic_auth; then
        log_error "生成基本认证信息失败"
        return 1
    fi
    
    # 检查必要的环境变量
    TRAEFIK_REQUIRED_VARS=(
        "TRAEFIK_DOMAIN"
        "TRAEFIK_ACME_EMAIL"
        "TRAEFIK_BASIC_AUTH"
        "TRAEFIK_DASHBOARD_USER"
        "TRAEFIK_DASHBOARD_PASSWORD"
    )
    
    for var in "${TRAEFIK_REQUIRED_VARS[@]}"; do
        if [ -z "${!var}" ]; then
            log_error "必要的环境变量 $var 未设置"
            return 1
        fi
    done
    
    # 创建网络
    if ! docker network ls | grep -q "traefik_proxy"; then
        docker network create traefik_proxy || handle_error "创建网络失败"
    fi
    
    # 启动服务
    if ! docker compose -f /etc/traefik/docker-compose.yml up -d; then
        log_error "启动 Traefik 失败"
        return 1
    fi
    
    log_info "Traefik 服务已启动"
    return 0
}

# 验证 Traefik 服务健康状态
verify_traefik_health() {
    local max_attempts=30
    local attempt=1
    local wait_time=10

    log_info "正在验证 Traefik 服务状态..."
    
    while [ $attempt -le $max_attempts ]; do
        if curl -sf --max-time 5 "http://localhost:8080/api/overview" > /dev/null 2>&1; then
            log_info "Traefik 服务运行正常"
            return 0
        fi
        
        log_warn "等待 Traefik 服务启动... (${attempt}/${max_attempts})"
        sleep $wait_time
        attempt=$((attempt + 1))
    done

    return 1
}

# 清理安装
cleanup_installation() {
    log_info "开始清理安装..."
    
    # 停止并删除 Docker 容器
    if [ -f "/etc/traefik/docker-compose.yml" ]; then
        cd /etc/traefik && docker compose down
    fi
    
    # 删除配置文件和目录
    rm -rf /etc/traefik
    
    log_info "清理完成"
}

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --email)
                if [ -n "$2" ]; then
                    TRAEFIK_ACME_EMAIL="$2"
                    shift 2
                else
                    log_error "缺少email参数值"
                    show_usage
                    exit 1
                fi
                ;;
            --domain)
                if [ -n "$2" ]; then
                    TRAEFIK_DOMAIN="$2"
                    shift 2
                else
                    log_error "缺少domain参数值"
                    show_usage
                    exit 1
                fi
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # 验证必要参数
    if [ -z "$TRAEFIK_ACME_EMAIL" ] || [ -z "$TRAEFIK_DOMAIN" ]; then
        log_error "缺少必要参数"
        show_usage
        exit 1
    fi
}

# 显示使用说明
show_usage() {
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  --email EMAIL    用于 Let's Encrypt 证书通知的邮箱地址"
    echo "  --domain DOMAIN  Traefik 服务的域名"
    echo "  --help          显示此帮助信息"
}

# 生成基本认证信息
generate_basic_auth() {
    log_info "生成基本认证信息..."
    if [ -z "$TRAEFIK_DASHBOARD_USER" ] || [ -z "$TRAEFIK_DASHBOARD_PASSWORD" ]; then
        log_error "缺少 Dashboard 认证信息"
        return 1
    fi
    
    TRAEFIK_BASIC_AUTH=$(htpasswd -nb "$TRAEFIK_DASHBOARD_USER" "$TRAEFIK_DASHBOARD_PASSWORD")
    if [ -z "$TRAEFIK_BASIC_AUTH" ]; then
        log_error "生成基本认证信息失败"
        return 1
    fi
    
    # 写入到环境文件
    echo "TRAEFIK_BASIC_AUTH=$TRAEFIK_BASIC_AUTH" >> /etc/traefik/.env
    log_info "基本认证信息已生成"
    return 0
}

# 主函数
main() {
    # 解析命令行参数
    parse_arguments "$@"
    
    # 设置环境变量
    export TRAEFIK_DOMAIN="${DOMAIN}"
    export TRAEFIK_ACME_EMAIL="${EMAIL}"
    
    # 写入环境变量到配置文件
    echo "TRAEFIK_DOMAIN=${DOMAIN}" > /etc/traefik/.env
    echo "TRAEFIK_ACME_EMAIL=${EMAIL}" >> /etc/traefik/.env
    
    log_info "开始安装 Traefik..."
    
    # 检查环境
    check_environment
    
    # 检查系统要求
    check_system_requirements
    
    # 安装必要依赖
    install_dependencies
    
    # 检查 Docker
    install_docker
    
    # 检查 Docker Compose
    install_docker_compose
    
    # 创建必要的目录
    create_directories
    
    # 生成 Dashboard 密码
    generate_password
    
    # 生成基本认证信息
    log_info "生成基本认证信息..."
    generate_basic_auth
    
    # 下载配置文件
    download_configs
    
    # 启动 Traefik
    start_traefik
    
    # 验证服务状态
    if ! verify_traefik_health; then
        log_error "Traefik 服务验证失败，开始回滚..."
        cleanup_installation
        log_error "Traefik 安装失败"
        exit 1
    fi
    
    log_info "Traefik 安装成功！"
    log_info "Dashboard 访问信息："
    log_info "URL: https://${TRAEFIK_DOMAIN}/dashboard/"
    log_info "用户名: ${TRAEFIK_DASHBOARD_USER}"
    log_info "密码: ${TRAEFIK_DASHBOARD_PASSWORD}"
}

# 执行主函数，传递所有命令行参数
main "$@"
