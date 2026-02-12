#!/usr/bin/env bash
# ===================================
# A股自选股智能分析系统 - 一键部署脚本
# ===================================
set -euo pipefail

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 路径定义 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"

# --- Docker Compose 命令检测 ---
detect_compose() {
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif docker-compose version &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        echo -e "${RED}[ERROR] 未找到 Docker Compose，请先安装${NC}"
        echo "  安装指南: https://docs.docker.com/compose/install/"
        exit 1
    fi
}

# --- 辅助函数 ---
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

compose() {
    $COMPOSE_CMD -f "$COMPOSE_FILE" "$@"
}

# --- 环境检查 ---
check_env() {
    # Docker 守护进程
    if ! docker info &>/dev/null; then
        error "Docker 未运行，请先启动 Docker"
        exit 1
    fi

    # Docker Compose
    detect_compose

    # .env 文件
    if [ ! -f "$ENV_FILE" ]; then
        if [ -f "$ENV_EXAMPLE" ]; then
            warn ".env 文件不存在，已从 .env.example 复制"
            cp "$ENV_EXAMPLE" "$ENV_FILE"
            warn "请编辑 $ENV_FILE 填入真实配置（API Key 等）"
        else
            warn ".env 文件不存在，服务将使用默认配置或环境变量"
        fi
    fi
}

# --- 读取端口 ---
get_port() {
    local port=8000
    if [ -f "$ENV_FILE" ]; then
        local p
        p=$(grep -E '^API_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d ' "'\''')
        [ -n "$p" ] && port="$p"
    fi
    echo "$port"
}

# --- 命令实现 ---

cmd_build() {
    info "构建 Docker 镜像..."
    compose build "$@"
    success "镜像构建完成"
}

cmd_up() {
    check_env
    local services=("$@")

    info "构建镜像..."
    compose build

    if [ ${#services[@]} -eq 0 ]; then
        info "启动全部服务 (analyzer + server)..."
        compose up -d
    else
        info "启动服务: ${services[*]}..."
        compose up -d "${services[@]}"
    fi

    success "服务已启动"

    # 健康检查（仅当 server 在运行时）
    if compose ps --format '{{.Service}}' 2>/dev/null | grep -q server || \
       compose ps 2>/dev/null | grep -q stock-server; then
        local port
        port=$(get_port)
        info "等待 server 就绪..."
        local retries=0
        while [ $retries -lt 15 ]; do
            if curl -sf "http://localhost:${port}/api/health" &>/dev/null || \
               curl -sf "http://localhost:${port}/health" &>/dev/null; then
                success "Server 健康检查通过"
                break
            fi
            retries=$((retries + 1))
            sleep 2
        done
        if [ $retries -ge 15 ]; then
            warn "健康检查超时，服务可能仍在启动中，请用 ./deploy.sh logs server 查看"
        fi
    fi

    echo ""
    cmd_status
}

cmd_stop() {
    check_env
    info "停止所有服务..."
    compose down
    success "服务已停止"
}

cmd_restart() {
    check_env
    info "重启服务..."
    compose down
    cmd_up "$@"
}

cmd_logs() {
    detect_compose
    compose logs -f --tail=100 "$@"
}

cmd_status() {
    detect_compose
    local port
    port=$(get_port)

    echo -e "${CYAN}========== 服务状态 ==========${NC}"
    compose ps
    echo ""

    # 检查 server 是否可达
    if curl -sf "http://localhost:${port}/api/health" &>/dev/null || \
       curl -sf "http://localhost:${port}/health" &>/dev/null; then
        success "WebUI 访问地址: http://localhost:${port}"
    fi
}

cmd_update() {
    check_env
    info "拉取最新代码..."
    git -C "$SCRIPT_DIR" pull

    info "重新构建并启动..."
    compose down
    cmd_up "$@"
}

cmd_help() {
    echo -e "${CYAN}A股自选股智能分析系统 - 部署脚本${NC}"
    echo ""
    echo "用法: ./deploy.sh [命令] [参数]"
    echo ""
    echo "命令:"
    echo "  (无参数)       构建 + 启动全部服务 (analyzer + server)"
    echo "  server         仅启动 FastAPI 服务"
    echo "  analyzer       仅启动定时任务"
    echo "  stop           停止所有服务"
    echo "  restart        重启服务"
    echo "  logs [服务名]  查看日志 (Ctrl+C 退出)"
    echo "  status         查看运行状态"
    echo "  update         git pull + 重新构建 + 重启"
    echo "  build          仅构建镜像"
    echo "  help           显示此帮助"
    echo ""
    echo "示例:"
    echo "  ./deploy.sh              # 部署全部"
    echo "  ./deploy.sh server       # 仅启动 WebUI"
    echo "  ./deploy.sh logs server  # 查看 server 日志"
    echo "  ./deploy.sh update       # 更新代码并重启"
}

# --- 主入口 ---
main() {
    local cmd="${1:-}"
    shift 2>/dev/null || true

    case "$cmd" in
        ""|up)
            cmd_up "$@"
            ;;
        server|analyzer)
            cmd_up "$cmd" "$@"
            ;;
        stop|down)
            cmd_stop
            ;;
        restart)
            cmd_restart "$@"
            ;;
        logs|log)
            cmd_logs "$@"
            ;;
        status|ps)
            cmd_status
            ;;
        update|upgrade)
            cmd_update "$@"
            ;;
        build)
            check_env
            cmd_build "$@"
            ;;
        help|-h|--help)
            cmd_help
            ;;
        *)
            error "未知命令: $cmd"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
