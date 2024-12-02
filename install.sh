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
        apt-get install -y curl wget git dnsutils || handle_error "安装基础依赖失败"
    elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
        $PKG_MANAGER update -y || handle_error "更新包管理器失败"
        $PKG_MANAGER install -y curl wget git bind-utils || handle_error "安装基础依赖失败"
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
    
    # 生成随机用户名和密码
    DASHBOARD_USER=$(openssl rand -hex 6) || handle_error "生成用户名失败"
    DASHBOARD_PASSWORD=$(openssl rand -base64 12) || handle_error "生成密码失败"
    
    # 创建密码文件
    htpasswd -bc /etc/traefik/dashboard_users.htpasswd $DASHBOARD_USER $DASHBOARD_PASSWORD || handle_error "创建密码文件失败"
    
    echo "Dashboard 登录信息："
    echo "用户名: $DASHBOARD_USER"
    echo "密码: $DASHBOARD_PASSWORD"
}

# 检查域名解析
check_domain_resolution() {
    local domain=$1
    local resolved=false
    
    # 尝试使用 host 命令
    if command -v host >/dev/null 2>&1; then
        if host "$domain" >/dev/null 2>&1; then
            resolved=true
        fi
    # 如果 host 命令不可用，尝试使用 nslookup
    elif command -v nslookup >/dev/null 2>&1; then
        if nslookup "$domain" >/dev/null 2>&1; then
            resolved=true
        fi
    # 如果都不可用，尝试使用 dig
    elif command -v dig >/dev/null 2>&1; then
        if dig "$domain" >/dev/null 2>&1; then
            resolved=true
        fi
    fi
    
    echo "$resolved"
}

# 配置email
configure_email() {
    local max_attempts=3
    local attempt=1
    local email=""
    
    while [ $attempt -le $max_attempts ]; do
        log_info "配置 Let's Encrypt 邮箱... (尝试 $attempt/$max_attempts)"
        echo "邮箱地址将用于接收 Let's Encrypt 的证书过期通知和重要提醒"
        read -p "请输入邮箱地址 (例如: your.name@example.com): " email
        
        # 检查是否输入为空
        if [ -z "$email" ]; then
            log_error "邮箱地址不能为空"
            attempt=$((attempt + 1))
            continue
        fi
        
        # 验证邮箱格式
        if [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            # 尝试写入配置文件
            if echo "TRAEFIK_ACME_EMAIL=$email" > /etc/traefik/.env; then
                log_info "邮箱配置成功: $email"
                return 0
            else
                log_error "无法写入配置文件"
                rollback "邮箱配置失败"
                return 1
            fi
        else
            log_error "无效的邮箱格式，请使用正确的邮箱地址格式"
            attempt=$((attempt + 1))
        fi
    done
    
    log_error "已达到最大重试次数 ($max_attempts 次)"
    rollback "邮箱配置失败"
    return 1
}

# 配置域名
configure_domain() {
    local max_attempts=3
    local attempt=1
    local domain=""
    
    while [ $attempt -le $max_attempts ]; do
        log_info "配置域名... (尝试 $attempt/$max_attempts)"
        echo "请输入您的域名，确保该域名已经正确解析到本服务器IP"
        read -p "请输入域名 (例如: example.com 或 sub.example.com): " domain
        
        # 检查是否输入为空
        if [ -z "$domain" ]; then
            log_error "域名不能为空"
            attempt=$((attempt + 1))
            continue
        fi
        
        # 验证域名格式
        if [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            # 检查域名解析
            log_info "正在检查域名解析..."
            if [ "$(check_domain_resolution "$domain")" = "true" ]; then
                # 尝试写入配置文件
                if echo "TRAEFIK_DOMAIN=$domain" >> /etc/traefik/.env; then
                    log_info "域名配置成功: $domain"
                    return 0
                else
                    log_error "无法写入配置文件"
                    rollback "域名配置失败"
                    return 1
                fi
            else
                log_error "域名解析失败，请确保域名已正确解析到服务器IP"
                attempt=$((attempt + 1))
                continue
            fi
        else
            log_error "无效的域名格式，请使用正确的域名格式"
            attempt=$((attempt + 1))
        fi
    done
    
    log_error "已达到最大重试次数 ($max_attempts 次)"
    rollback "域名配置失败"
    return 1
}

# 下载配置文件
download_configs() {
    log_info "下载配置文件..."
    
    # 下载基础配置
    curl -L https://raw.githubusercontent.com/laughinbytes/traefik-deploy/main/configs/traefik.yml -o /etc/traefik/traefik.yml || handle_error "下载traefik.yml失败"
    curl -L https://raw.githubusercontent.com/laughinbytes/traefik-deploy/main/configs/docker-compose.yml -o /etc/traefik/docker-compose.yml || handle_error "下载docker-compose.yml失败"
    
    # 下载动态配置
    curl -L https://raw.githubusercontent.com/laughinbytes/traefik-deploy/main/configs/dynamic/middleware.yml -o /etc/traefik/dynamic/middleware.yml || handle_error "下载middleware.yml失败"
}

# 启动Traefik
start_traefik() {
    log_info "启动Traefik..."
    cd /etc/traefik
    # 创建 Docker 网络（如果不存在）
    docker network inspect traefik_proxy >/dev/null 2>&1 || docker network create traefik_proxy
    docker-compose up -d || handle_error "启动Traefik失败"
}

# 主函数
main() {
    log_info "开始安装 Traefik..."
    
    # 设置 trap 来捕获错误
    trap 'handle_error "未知错误"' ERR
    
    # 首先执行基础安装步骤
    check_system_requirements
    install_dependencies
    install_docker
    install_docker_compose
    create_directories
    
    # 然后获取配置信息
    configure_email || handle_error "邮箱配置失败"
    configure_domain || handle_error "域名配置失败"
    
    # 最后执行配置和启动
    generate_password
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
