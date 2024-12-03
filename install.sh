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
    
    # 验证配置文件
    log_info "验证配置文件..."
    
    # 验证 traefik.yml
    if [ ! -s "/etc/traefik/traefik.yml" ]; then
        log_error "traefik.yml 文件为空"
        return 1
    fi
    
    if ! grep -q "certificatesResolvers" /etc/traefik/traefik.yml; then
        log_error "traefik.yml 缺少证书解析器配置"
        return 1
    fi
    
    if ! grep -q "acme:" /etc/traefik/traefik.yml; then
        log_error "traefik.yml 缺少 ACME 配置"
        return 1
    fi
    
    # 验证 docker-compose.yml
    if [ ! -s "/etc/traefik/docker-compose.yml" ]; then
        log_error "docker-compose.yml 文件为空"
        return 1
    fi
    
    if ! grep -q "traefik:v" /etc/traefik/docker-compose.yml; then
        log_error "docker-compose.yml 缺少 Traefik 镜像配置"
        return 1
    fi
    
    # 验证配置文件语法
    if command -v yamllint >/dev/null; then
        log_info "验证YAML语法..."
        if ! yamllint -d relaxed /etc/traefik/traefik.yml; then
            log_warn "traefik.yml 可能存在语法问题"
        fi
        if ! yamllint -d relaxed /etc/traefik/docker-compose.yml; then
            log_warn "docker-compose.yml 可能存在语法问题"
        fi
    fi
    
    log_info "配置文件验证完成"
}

# 验证 Traefik 健康状态
verify_traefik_health() {
    log_info "验证 Traefik 服务状态..."
    
    # 检查容器状态
    if ! docker ps | grep -q "traefik.*Up"; then
        log_error "Traefik 容器未运行"
        log_info "输出容器日志以便调试..."
        docker logs traefik
        return 1
    fi
    
    # 检查端口监听状态
    log_info "检查端口监听状态..."
    if ! ss -tln | grep -q ":80 "; then
        log_warn "80端口未监听"
    fi
    if ! ss -tln | grep -q ":443 "; then
        log_warn "443端口未监听"
    fi
    
    # 验证 HTTPS 访问
    log_info "验证 HTTPS 访问..."
    local max_attempts=30
    local attempt=1
    local success=false
    
    while [ $attempt -le $max_attempts ]; do
        log_info "等待 HTTPS 服务就绪... ($attempt/$max_attempts)"
        
        # 检查证书文件
        if [ -f "/etc/traefik/acme/acme.json" ]; then
            log_info "检查证书状态..."
            if grep -q "\"status\": \"valid\"" /etc/traefik/acme/acme.json; then
                log_info "证书已成功获取"
            else
                log_warn "证书尚未验证成功"
                # 输出证书文件内容（排除敏感信息）
                cat /etc/traefik/acme/acme.json | grep -v "key" | grep -v "cert"
            fi
        else
            log_warn "证书文件尚未生成"
        fi
        
        # 使用curl检查HTTPS可用性，输出详细信息
        local curl_output
        curl_output=$(curl -skvL "https://${DOMAIN}" 2>&1)
        if echo "$curl_output" | grep -q "HTTP/2 200\|HTTP/1.1 200\|HTTP/2 404\|HTTP/1.1 404"; then
            success=true
            log_info "HTTPS连接成功"
            break
        else
            log_warn "HTTPS连接失败，详细信息："
            echo "$curl_output" | grep "SSL\|TLS\|certificate\|error"
        fi
        
        attempt=$((attempt + 1))
        sleep 10
    done
    
    if [ "$success" = false ]; then
        log_error "无法通过 HTTPS 访问 Traefik"
        log_info "诊断信息："
        log_info "1. 检查 Traefik 日志..."
        docker logs traefik
        log_info "2. 检查 Traefik 配置..."
        cat /etc/traefik/traefik.yml
        log_info "3. 检查 DNS 解析..."
        dig +short "${DOMAIN}"
        return 1
    fi
    
    log_info "Traefik 健康检查通过"
    return 0
}

# 清理安装
cleanup_installation() {
    log_info "执行清理..."
    
    # 停止并移除容器
    if [ -f "/etc/traefik/docker-compose.yml" ]; then
        cd /etc/traefik && docker compose down -v || true
    fi
    
    # 移除网络
    docker network rm traefik_proxy 2>/dev/null || true
    
    # 移除配置目录
    rm -rf /etc/traefik
    
    log_info "清理完成"
}

# 初始化 Traefik 配置
setup_traefik_config() {
    log_info "初始化 Traefik 配置..."
    
    # 创建必要的目录
    mkdir -p /etc/traefik/dynamic || handle_error "创建配置目录失败"
    mkdir -p /etc/traefik/acme || handle_error "创建证书目录失败"
    
    # 创建并设置 acme.json 权限
    touch /etc/traefik/acme/acme.json || handle_error "创建 acme.json 失败"
    chmod 600 /etc/traefik/acme/acme.json || handle_error "设置 acme.json 权限失败"
    
    # 下载配置文件
    download_configs
}

# 启动 Traefik
start_traefik() {
    log_info "启动 Traefik..."
    
    # 生成基本认证信息
    if ! generate_basic_auth; then
        log_error "生成基本认证信息失败"
        return 1
    fi
    
    # 设置必要的环境变量
    export TRAEFIK_DOMAIN="$DOMAIN"
    export TRAEFIK_ACME_EMAIL="$EMAIL"  # 添加 ACME 邮箱变量
    
    # 创建 Docker 网络（如果不存在）
    if ! docker network ls | grep -q "traefik_proxy"; then
        docker network create traefik_proxy || return 1
    fi
    
    cd /etc/traefik || return 1
    docker compose up -d || return 1
    
    # 等待一段时间让容器启动
    sleep 5
    
    # 验证服务状态
    if ! verify_traefik_health; then
        log_error "Traefik 服务验证失败，开始回滚..."
        cleanup_installation
        return 1
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

# 生成基本认证信息
generate_basic_auth() {
    # 检查是否已经生成了用户名和密码
    if [ -z "$TRAEFIK_DASHBOARD_USER" ] || [ -z "$TRAEFIK_DASHBOARD_PASSWORD" ]; then
        log_error "Dashboard 认证信息未生成"
        return 1
    fi
    
    # 使用 htpasswd 生成认证字符串
    TRAEFIK_BASIC_AUTH=$(htpasswd -nb "$TRAEFIK_DASHBOARD_USER" "$TRAEFIK_DASHBOARD_PASSWORD")
    export TRAEFIK_BASIC_AUTH
    
    if [ -z "$TRAEFIK_BASIC_AUTH" ]; then
        log_error "生成基本认证信息失败"
        return 1
    fi
}

# 主函数
main() {
    log_info "开始安装 Traefik..."
    
    # 解析命令行参数
    parse_arguments "$@"
    
    # 检查系统环境
    if ! check_environment; then
        log_error "环境检查失败"
        exit 1
    fi
    
    # 检查系统要求
    check_system_requirements
    
    # 安装依赖
    install_dependencies
    
    # 安装 Docker
    install_docker
    
    # 安装 Docker Compose
    install_docker_compose
    
    # 初始化 Traefik 配置
    setup_traefik_config
    
    # 配置邮箱
    configure_email
    
    # 配置域名
    configure_domain
    
    # 生成密码
    generate_password
    
    # 启动 Traefik
    if ! start_traefik; then
        log_error "Traefik 安装失败"
        exit 1
    fi
    
    # 移除错误处理 trap
    trap - ERR INT TERM
    
    log_info "Traefik 安装完成!"
    
    # 打印安装信息
    cat << EOF
===================================================
安装成功! 以下是重要信息：

Traefik Dashboard:
- 地址：https://${TRAEFIK_DOMAIN}
- 用户名：${TRAEFIK_DASHBOARD_USER}
- 密码：${TRAEFIK_DASHBOARD_PASSWORD}

配置文件位置：
- 主配置：/etc/traefik/traefik.yml
- Docker配置：/etc/traefik/docker-compose.yml
- 动态配置：/etc/traefik/dynamic/

常用命令：
- 查看日志：docker compose -f /etc/traefik/docker-compose.yml logs -f
- 重启服务：docker compose -f /etc/traefik/docker-compose.yml restart
- 停止服务：docker compose -f /etc/traefik/docker-compose.yml down
- 启动服务：docker compose -f /etc/traefik/docker-compose.yml up -d
===================================================
EOF
}

# 执行主函数，传递所有命令行参数
main "$@"
