#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 打印带颜色的信息
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 回滚函数
rollback() {
    local error_msg="$1"
    log_error "安装失败: $error_msg"
    log_warn "开始回滚..."
    
    # 停止并删除所有Docker容器和网络
    if command -v docker >/dev/null; then
        log_info "清理Docker资源..."
        docker-compose -f /etc/traefik/docker-compose.yml down 2>/dev/null || true
        docker network rm traefik_proxy 2>/dev/null || true
    fi
    
    # 删除Traefik相关文件
    log_info "删除Traefik配置..."
    rm -rf /etc/traefik
    
    # 如果Docker是由脚本安装的，则卸载Docker
    if [ -f "/etc/docker/daemon.json" ]; then
        log_info "卸载Docker..."
        if [ "$PKG_MANAGER" = "apt-get" ]; then
            apt-get remove --purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true
        elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
            $PKG_MANAGER remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
            $PKG_MANAGER autoremove -y 2>/dev/null || true
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
        PKG_MANAGER="apt-get"
    elif command -v yum >/dev/null; then
        PKG_MANAGER="yum"
    elif command -v dnf >/dev/null; then
        PKG_MANAGER="dnf"
    else
        log_error "不支持的包管理器"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    log_info "安装必要依赖..."
    
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        apt-get update || handle_error "更新包管理器失败"
        apt-get install -y curl wget git || handle_error "安装基础依赖失败"
    elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
        $PKG_MANAGER update -y || handle_error "更新包管理器失败"
        $PKG_MANAGER install -y curl wget git || handle_error "安装基础依赖失败"
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

# 安装Docker Compose
install_docker_compose() {
    log_info "检查Docker Compose..."
    if ! command -v docker-compose >/dev/null; then
        log_info "安装Docker Compose..."
        COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4) || handle_error "获取Docker Compose版本失败"
        curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || handle_error "下载Docker Compose失败"
        chmod +x /usr/local/bin/docker-compose || handle_error "设置Docker Compose权限失败"
    else
        log_info "Docker Compose已安装"
    fi
}

# 创建必要的目录
create_directories() {
    log_info "创建必要的目录..."
    mkdir -p /etc/traefik
    mkdir -p /etc/traefik/dynamic
    mkdir -p /etc/traefik/acme
}

# 生成密码
generate_password() {
    log_info "生成Dashboard密码..."
    if ! command -v htpasswd >/dev/null; then
        if [ "$PKG_MANAGER" = "apt-get" ]; then
            apt-get install -y apache2-utils || handle_error "安装htpasswd失败"
        else
            $PKG_MANAGER install -y httpd-tools || handle_error "安装htpasswd失败"
        fi
    fi
    
    # 生成随机密码
    DASHBOARD_PASSWORD=$(openssl rand -base64 12) || handle_error "生成密码失败"
    DASHBOARD_USER="admin"
    
    # 创建密码文件
    htpasswd -bc /etc/traefik/dashboard_users.htpasswd $DASHBOARD_USER $DASHBOARD_PASSWORD || handle_error "创建密码文件失败"
    
    echo "Dashboard 登录信息："
    echo "用户名: $DASHBOARD_USER"
    echo "密码: $DASHBOARD_PASSWORD"
}

# 配置email
configure_email() {
    log_info "配置 Let's Encrypt 邮箱..."
    read -p "请输入用于 Let's Encrypt 证书通知的邮箱地址: " email
    
    if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        log_error "无效的邮箱地址"
        configure_email
        return
    fi
    
    echo "TRAEFIK_ACME_EMAIL=$email" > /etc/traefik/.env || handle_error "配置邮箱失败"
    log_info "邮箱配置完成: $email"
}

# 配置域名
configure_domain() {
    log_info "配置 Traefik Dashboard 域名..."
    read -p "请输入 Traefik Dashboard 的域名 (例如: traefik.yourdomain.com): " domain
    
    if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        log_error "无效的域名格式"
        configure_domain
        return
    fi
    
    echo "TRAEFIK_DOMAIN=$domain" >> /etc/traefik/.env || handle_error "配置域名失败"
    log_info "域名配置完成: $domain"
}

# 下载配置文件
download_configs() {
    log_info "下载配置文件..."
    
    # 下载基础配置
    curl -L https://raw.githubusercontent.com/yourusername/traefik-deploy/main/configs/traefik.yml -o /etc/traefik/traefik.yml || handle_error "下载traefik.yml失败"
    curl -L https://raw.githubusercontent.com/yourusername/traefik-deploy/main/configs/docker-compose.yml -o /etc/traefik/docker-compose.yml || handle_error "下载docker-compose.yml失败"
    
    # 下载动态配置
    curl -L https://raw.githubusercontent.com/yourusername/traefik-deploy/main/configs/dynamic/middleware.yml -o /etc/traefik/dynamic/middleware.yml || handle_error "下载middleware.yml失败"
}

# 启动Traefik
start_traefik() {
    log_info "启动Traefik..."
    cd /etc/traefik
    docker-compose up -d || handle_error "启动Traefik失败"
}

# 主函数
main() {
    log_info "开始安装 Traefik..."
    
    # 设置 trap 来捕获错误
    trap 'handle_error "未知错误"' ERR
    
    # 执行安装步骤
    check_system_requirements
    install_dependencies
    install_docker
    install_docker_compose
    create_directories
    generate_password
    configure_email
    configure_domain
    download_configs
    start_traefik
    
    # 禁用 trap
    trap - ERR
    
    log_info "Traefik 安装完成!"
    log_info "请确保将以下域名指向此服务器: $domain"
    log_info "Dashboard 将在配置DNS并等待证书颁发后可通过 https://$domain 访问"
}

# 执行主函数
main
