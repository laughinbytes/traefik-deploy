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
        if [ "$PKG_MANAGER" = "apt-get" ]; then
            apt-get install -y docker-ce-cli || handle_error "安装 Docker CLI 失败"
        elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
            $PKG_MANAGER install -y docker-ce-cli || handle_error "安装 Docker CLI 失败"
        fi
    else
        # 对于旧版本 Docker，安装 compose 插件
        log_info "Docker 版本 < 23.0，安装 Compose 插件..."
        if [ "$PKG_MANAGER" = "apt-get" ]; then
            apt-get install -y docker-compose-plugin || handle_error "安装 Docker Compose 插件失败"
        elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
            $PKG_MANAGER install -y docker-compose-plugin || handle_error "安装 Docker Compose 插件失败"
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
    htpasswd -bc /etc/traefik/dashboard_users.htpasswd "$DASHBOARD_USER" "$DASHBOARD_PASSWORD" || handle_error "创建密码文件失败"
    
    # 导出变量供主函数使用
    export TRAEFIK_DASHBOARD_USER="$DASHBOARD_USER"
    export TRAEFIK_DASHBOARD_PASSWORD="$DASHBOARD_PASSWORD"
    
    return 0
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
    log_info "配置邮箱..."
    
    # 验证邮箱格式
    if [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        log_error "无效的邮箱格式: $EMAIL"
        exit 1
    fi
    
    # 导出环境变量
    export TRAEFIK_ACME_EMAIL="$EMAIL"
    # 写入到环境文件
    echo "TRAEFIK_ACME_EMAIL=$EMAIL" > /etc/traefik/.env
    log_info "邮箱配置成功: $EMAIL"
}

# 配置域名
configure_domain() {
    log_info "配置域名..."
    
    # 验证域名格式
    if [[ ! "$TRAEFIK_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        log_error "无效的域名格式: $TRAEFIK_DOMAIN"
        exit 1
    fi
    
    # 检查域名解析
    log_info "正在检查域名解析..."
    if [ "$(check_domain_resolution "$TRAEFIK_DOMAIN")" != "true" ]; then
        log_error "域名解析失败，请确保域名 $TRAEFIK_DOMAIN 已正确解析到服务器IP"
        exit 1
    fi
    
    # 导出环境变量
    export TRAEFIK_DOMAIN
    # 写入到环境文件
    echo "TRAEFIK_DOMAIN=$TRAEFIK_DOMAIN" >> /etc/traefik/.env
    log_info "域名配置成功: $TRAEFIK_DOMAIN"
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

# 检查 Traefik 是否正常运行
verify_traefik_health() {
    local max_attempts=30
    local attempt=1
    local wait_seconds=10
    
    log_info "验证 Traefik 服务状态..."
    
    # 首先检查容器状态
    while [ $attempt -le $max_attempts ]; do
        if ! docker ps | grep -q "traefik"; then
            if [ $attempt -eq $max_attempts ]; then
                log_error "Traefik 容器未运行"
                return 1
            fi
            log_info "等待 Traefik 容器启动... ($attempt/$max_attempts)"
            sleep $wait_seconds
            attempt=$((attempt + 1))
            continue
        fi
        
        # 检查容器是否健康
        if [ "$(docker inspect --format='{{.State.Status}}' traefik)" != "running" ]; then
            log_error "Traefik 容器状态异常"
            return 1
        fi
        
        break
    done
    
    # 重置计数器
    attempt=1
    
    # 然后验证 HTTPS 访问
    log_info "验证 HTTPS 访问..."
    while [ $attempt -le $max_attempts ]; do
        if curl -sIk --max-time 10 "https://${TRAEFIK_DOMAIN}" | grep -q "401 Unauthorized"; then
            log_info "HTTPS 访问正常"
            
            # 验证证书
            if ! curl -sI --max-time 10 "https://${TRAEFIK_DOMAIN}" | grep -q "Let's Encrypt"; then
                log_error "SSL 证书配置异常"
                return 1
            fi
            
            return 0
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            log_error "无法通过 HTTPS 访问 Traefik"
            return 1
        fi
        
        log_info "等待 HTTPS 服务就绪... ($attempt/$max_attempts)"
        sleep $wait_seconds
        attempt=$((attempt + 1))
    done
    
    return 1
}

# 启动Traefik
start_traefik() {
    log_info "启动 Traefik..."
    
    # 创建 Docker 网络（如果不存在）
    if ! docker network ls | grep -q "traefik_proxy"; then
        docker network create traefik_proxy || handle_error "创建 Docker 网络失败"
    fi
    
    # 启动 Traefik
    cd /etc/traefik || handle_error "无法进入 Traefik 配置目录"
    docker compose down -v 2>/dev/null || true
    docker compose up -d || handle_error "启动 Traefik 失败"
    
    # 验证服务健康状态
    if ! verify_traefik_health; then
        handle_error "Traefik 服务验证失败"
    fi
    
    log_info "Traefik 启动成功"
    return 0
}

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --email)
                if [ -z "$2" ]; then
                    log_error "--email 参数需要一个值"
                    show_usage
                    exit 1
                fi
                EMAIL="$2"
                shift 2
                ;;
            --domain)
                if [ -z "$2" ]; then
                    log_error "--domain 参数需要一个值"
                    show_usage
                    exit 1
                fi
                TRAEFIK_DOMAIN="$2"
                shift 2
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
    if [ -z "$EMAIL" ] || [ -z "$TRAEFIK_DOMAIN" ]; then
        log_error "必须提供 --email 和 --domain 参数"
        show_usage
        exit 1
    fi
}

# 显示使用说明
show_usage() {
    echo "使用方法:"
    echo "curl -fsSL https://raw.githubusercontent.com/laughinbytes/traefik-deploy/main/install.sh | sudo bash -s -- --email user@example.com --domain traefik.example.com"
    echo
    echo "参数说明:"
    echo "  --email EMAIL    用于 Let's Encrypt 证书通知的邮箱地址"
    echo "  --domain DOMAIN  Traefik Dashboard 的域名"
    echo "  --help          显示此帮助信息"
}

# 主函数
main() {
    log_info "开始安装 Traefik..."
    
    # 解析命令行参数
    parse_arguments "$@"
    
    # 设置 trap 来捕获错误和中断信号
    trap 'rollback "安装过程被中断"' INT TERM
    trap 'rollback "安装过程发生错误"' ERR
    
    # 检查系统要求
    check_system_requirements
    
    # 安装依赖
    install_dependencies
    
    # 安装 Docker
    install_docker
    
    # 安装 Docker Compose
    install_docker_compose
    
    # 创建必要的目录
    create_directories
    
    # 配置邮箱
    configure_email
    
    # 配置域名
    configure_domain
    
    # 生成密码
    generate_password
    
    # 下载配置文件
    download_configs
    
    # 启动 Traefik
    start_traefik
    
    # 移除错误处理 trap
    trap - ERR INT TERM
    
    log_info "Traefik 安装完成!"
    
    # 打印安装信息
    echo "==================================================="
    echo "安装成功! 以下是重要信息："
    echo
    echo "Traefik Dashboard:"
    echo "- 地址：https://$TRAEFIK_DOMAIN"
    echo "- 用户名：$TRAEFIK_DASHBOARD_USER"
    echo "- 密码：$TRAEFIK_DASHBOARD_PASSWORD"
    echo
    echo "配置文件位置："
    echo "- 主配置：/etc/traefik/traefik.yml"
    echo "- Docker配置：/etc/traefik/docker-compose.yml"
    echo "- 动态配置：/etc/traefik/dynamic/"
    echo
    echo "常用命令："
    echo "- 查看日志：docker compose -f /etc/traefik/docker-compose.yml logs -f"
    echo "- 重启服务：docker compose -f /etc/traefik/docker-compose.yml restart"
    echo "- 停止服务：docker compose -f /etc/traefik/docker-compose.yml down"
    echo "- 启动服务：docker compose -f /etc/traefik/docker-compose.yml up -d"
    echo "==================================================="
}

# 执行主函数，传递所有命令行参数
main "$@"
