#!/bin/bash

# 修复 getcwd/chdir 报错：确保工作目录有效
(cd /root 2>/dev/null || cd / 2>/dev/null || true) >/dev/null 2>&1
cd /root 2>/dev/null || cd / 2>/dev/null || true

# ================== 全局配置 v2.0 (FRPS Web Panel Installer - 独立目录版) ==================
WEB_MANAGER_URL="http://frp.atusu.cn/frps_web-v1.3.py"

# 面板独立目录（与 FRPS 服务端完全分离）
PANEL_DIR="/opt/frps_web"
WEB_MANAGER_FILE="${PANEL_DIR}/frps_web.py"
PANEL_CONFIG_FILE="${PANEL_DIR}/.panel_config.json"
PANEL_LOG_FILE="${PANEL_DIR}/panel_ops.log"
WEB_SERVICE_NAME="frps-web"

# FRPS 服务端目录（仅用于提示，面板不依赖此目录存在）
FRPS_DIR="/opt/frps"

DEFAULT_WEB_PORT="8080"
DEFAULT_WEB_USER="admin"
DEFAULT_WEB_PWD="admin888"

CURRENT_WEB_PORT="$DEFAULT_WEB_PORT"
CURRENT_WEB_PWD="$DEFAULT_WEB_PWD"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ================== 下载封装 (curl/wget 兼容) ==================
wget_download() {
    local url="$1"
    local output="$2"
    if command -v curl &>/dev/null; then
        curl -fSL --connect-timeout 15 --max-time 300 -o "$output" "$url" 2>/dev/null
        return $?
    fi
    wget -q -T 15 -t 3 -O "$output" "$url" 2>/dev/null
    local ret=$?
    if [ $ret -ne 0 ]; then
        wget -q -T 15 -t 3 --no-check-certificate -O "$output" "$url" 2>/dev/null
        ret=$?
    fi
    return $ret
}

# ================== 环境校验 ==================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

check_tty() {
    if [ ! -e /dev/tty ]; then
        log_error "未检测到终端设备 (/dev/tty)，无法进行交互式配置。"
        exit 1
    fi
}

detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64)   ARCH="x86_64 (amd64)" ;;
        aarch64|arm64)  ARCH="ARM64 (aarch64)" ;;
        armv7l|armv7*)  ARCH="ARMv7 (32位)" ;;
        armv6l)         ARCH="ARMv6 (32位)" ;;
        i386|i686)      ARCH="x86 (32位)" ;;
        *)              ARCH="$machine (未识别，Python程序通用)" ;;
    esac
    log_info "检测到系统架构: ${CYAN}${ARCH}${NC} (Python 面板与架构无关，全部支持)"
}

# ================== 系统信息检测 ==================
detect_system_info() {
    echo ""
    echo -e "${CYAN}=========================================="
    echo -e "       系统环境检测"
    echo -e "==========================================${NC}"

    local os_name="Unknown"
    if [ -f /etc/os-release ]; then
        os_name=$(. /etc/os-release && echo "$PRETTY_NAME")
    elif [ -f /etc/redhat-release ]; then
        os_name=$(cat /etc/redhat-release)
    fi
    echo -e "  🖥️  ${CYAN}操作系统:${NC}    $os_name"
    echo -e "  🏗️  ${CYAN}系统架构:${NC}    $(uname -m) -> ${ARCH}"
    echo -e "  🐧 ${CYAN}内核版本:${NC}    $(uname -r)"

    if command -v systemctl &>/dev/null; then
        echo -e "  ⚙️  ${CYAN}服务管理:${NC}    systemd (支持守护进程)"
        HAS_SYSTEMD=1
    else
        echo -e "  ⚙️  ${CYAN}服务管理:${NC}    ${YELLOW}未检测到 systemd，将使用 nohup 后台运行${NC}"
        HAS_SYSTEMD=0
    fi
    echo ""
}

# ================== 安装依赖 ==================
install_dependencies() {
    log_info "正在检查并安装必要的依赖 (curl/wget)..."
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y wget curl >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y wget curl >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y wget curl >/dev/null 2>&1
        elif command -v apk &>/dev/null; then
            apk add --no-cache wget curl >/dev/null 2>&1
        fi
    fi
    log_info "依赖检查完成"
}

# ================== Python3 环境检测 (要求 >= 3.6) ==================
check_python3() {
    log_info "正在检测 Python3 环境 (面板要求 >= 3.6)..."
    if ! command -v python3 &>/dev/null; then
        log_warn "未检测到 python3，正在尝试自动安装..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y python3 >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y python3 >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y python3 >/dev/null 2>&1
        elif command -v apk &>/dev/null; then
            apk add --no-cache python3 >/dev/null 2>&1
        fi
    fi

    if ! command -v python3 &>/dev/null; then
        log_error "自动安装 Python3 失败，请手动安装后重试"
        return 1
    fi

    local py_ver
    py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
    if [ -z "$py_ver" ]; then
        py_ver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
    fi
    if [ -z "$py_ver" ]; then
        log_error "无法获取 Python3 版本"
        return 1
    fi

    local major minor
    major=$(echo "$py_ver" | cut -d. -f1)
    minor=$(echo "$py_ver" | cut -d. -f2)

    if [ "$major" -lt 3 ] || ([ "$major" -eq 3 ] && [ "$minor" -lt 6 ]); then
        log_error "Python 版本过低 ($py_ver)，面板需要 3.6 及以上版本"
        log_error "请手动升级 Python3 后重试 (如 CentOS7 可安装 python36/python38)"
        return 1
    fi

    log_info "✅ 检测到 Python 版本: ${GREEN}${py_ver}${NC} (满足要求)"
    return 0
}

# ================== 安装状态检测 ==================
check_web_installed() {
    if [ -f "${WEB_MANAGER_FILE}" ]; then
        return 0
    fi
    return 1
}

check_web_running() {
    if [ "$HAS_SYSTEMD" = "1" ]; then
        systemctl is-active --quiet "${WEB_SERVICE_NAME}" 2>/dev/null
    else
        pgrep -f "python3 ${WEB_MANAGER_FILE}" >/dev/null 2>&1
    fi
}

# 从已安装的程序中读取当前端口
read_current_port() {
    local port
    port=$(grep -E '^\s*port = [0-9]+' "${WEB_MANAGER_FILE}" 2>/dev/null | head -1 | grep -oE '[0-9]+')
    if [ -n "$port" ]; then
        CURRENT_WEB_PORT="$port"
    else
        CURRENT_WEB_PORT="$DEFAULT_WEB_PORT"
    fi
}

# ================== 获取本机 IP ==================
get_local_ip() {
    local ip
    ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "${ip:-127.0.0.1}"
}

# ================== 写入面板密码配置 ==================
# 密码文件存储在 PANEL_DIR 下，与面板程序同目录
write_panel_password() {
    local pwd_plain="$1"
    mkdir -p "${PANEL_DIR}"

    export PANEL_NEW_PWD="$pwd_plain"
    export PANEL_CONFIG_PATH="$PANEL_CONFIG_FILE"

    python3 -c "
import json, hashlib, os
config_file = os.environ.get('PANEL_CONFIG_PATH')
pwd = os.environ.get('PANEL_NEW_PWD', '')
new_hash = hashlib.sha256(pwd.encode()).hexdigest()
config = {'username': 'admin', 'password_hash': new_hash}
if os.path.exists(config_file):
    try:
        with open(config_file, 'r') as f:
            old = json.load(f)
            config['username'] = old.get('username', 'admin')
    except: pass
with open(config_file, 'w') as f:
    json.dump(config, f)
os.chmod(config_file, 0o600)
" 2>/dev/null
    local ret=$?
    unset PANEL_NEW_PWD
    unset PANEL_CONFIG_PATH
    return $ret
}

# ================== 修改程序监听端口 ==================
patch_panel_port() {
    local new_port="$1"
    if grep -qE '^\s*port = [0-9]+' "${WEB_MANAGER_FILE}"; then
        sed -i "s/^\(\s*\)port = [0-9]\+/\1port = ${new_port}/" "${WEB_MANAGER_FILE}"
        return 0
    fi
    return 1
}

# ================== 配置守护程序 ==================
setup_daemon() {
    if [ "$HAS_SYSTEMD" = "1" ]; then
        log_info "正在创建 systemd 守护服务..."
        cat > "/etc/systemd/system/${WEB_SERVICE_NAME}.service" << EOF
[Unit]
Description=FRPS Web Manager Panel Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=/usr/bin/env python3 ${WEB_MANAGER_FILE}
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "${WEB_SERVICE_NAME}" >/dev/null 2>&1
        systemctl restart "${WEB_SERVICE_NAME}"
    else
        log_warn "无 systemd 环境，使用 nohup 后台启动..."
        pkill -f "python3 ${WEB_MANAGER_FILE}" 2>/dev/null || true
        sleep 1
        cd "${PANEL_DIR}" && nohup python3 "${WEB_MANAGER_FILE}" > "${PANEL_DIR}/panel.out" 2>&1 &
        cd /root 2>/dev/null || cd / 2>/dev/null || true
    fi

    sleep 2
    if check_web_running; then
        log_info "✅ 面板守护服务启动成功！"
        return 0
    else
        log_error "❌ 面板服务启动失败"
        [ "$HAS_SYSTEMD" = "1" ] && log_error "请查看日志: journalctl -u ${WEB_SERVICE_NAME} -n 20 --no-pager"
        return 1
    fi
}

# ================== 重启/重载面板 ==================
reload_panel() {
    if [ "$HAS_SYSTEMD" = "1" ]; then
        systemctl restart "${WEB_SERVICE_NAME}" 2>/dev/null
    else
        pkill -f "python3 ${WEB_MANAGER_FILE}" 2>/dev/null || true
        sleep 1
        cd "${PANEL_DIR}" && nohup python3 "${WEB_MANAGER_FILE}" > "${PANEL_DIR}/panel.out" 2>&1 &
        cd /root 2>/dev/null || cd / 2>/dev/null || true
    fi
    sleep 2
    check_web_running
}

# ================== 下载并安装面板程序 ==================
install_panel_files() {
    log_info "正在创建面板目录: ${PANEL_DIR}"
    mkdir -p "${PANEL_DIR}"

    log_info "正在下载面板程序..."
    local tmp_file="/tmp/frps_web_$$.py"
    if ! wget_download "$WEB_MANAGER_URL" "$tmp_file"; then
        rm -f "$tmp_file"
        log_error "❌ 面板程序下载失败，请检查网络连接"
        return 1
    fi
    if [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file"
        log_error "❌ 下载文件为空"
        return 1
    fi
    if ! head -5 "$tmp_file" | grep -qE 'python|import|#'; then
        rm -f "$tmp_file"
        log_error "❌ 下载的文件不是有效的 Python 程序"
        return 1
    fi

    cp -f "$tmp_file" "$WEB_MANAGER_FILE"
    rm -f "$tmp_file"
    chmod +x "$WEB_MANAGER_FILE"
    log_info "✅ 面板程序下载完成: ${WEB_MANAGER_FILE}"
    return 0
}

# ================== 交互式配置端口 ==================
input_port() {
    echo ""
    echo -e "${CYAN}=========================================="
    echo -e "       配置面板访问端口"
    echo -e "==========================================${NC}"
    while true; do
        echo -n "请输入面板访问端口 (默认 ${DEFAULT_WEB_PORT}): "
        read -r input_p < /dev/tty
        if [ -z "$input_p" ]; then
            CURRENT_WEB_PORT="$DEFAULT_WEB_PORT"
            log_info "使用默认端口: ${GREEN}${CURRENT_WEB_PORT}${NC}"
            return
        fi
        if [[ "$input_p" =~ ^[0-9]+$ ]] && [ "$input_p" -ge 1 ] && [ "$input_p" -le 65535 ]; then
            CURRENT_WEB_PORT="$input_p"
            log_info "已设置端口: ${GREEN}${CURRENT_WEB_PORT}${NC}"
            return
        fi
        log_warn "端口无效，请输入 1-65535 之间的数字"
    done
}

# ================== 交互式配置密码 ==================
input_password() {
    echo ""
    echo -e "${CYAN}=========================================="
    echo -e "       配置面板管理员密码"
    echo -e "==========================================${NC}"
    echo -e "  提示: 直接回车将使用默认密码 ${GREEN}${DEFAULT_WEB_PWD}${NC}"
    echo ""
    while true; do
        echo -n "请输入新密码 (至少6位): "
        read -r new_pwd < /dev/tty
        if [ -z "$new_pwd" ]; then
            CURRENT_WEB_PWD="$DEFAULT_WEB_PWD"
            log_info "使用默认密码: ${GREEN}${CURRENT_WEB_PWD}${NC}"
            return
        fi
        if [ ${#new_pwd} -lt 6 ]; then
            log_warn "密码长度不能少于6位，请重新输入"
            continue
        fi
        echo -n "请再次确认新密码: "
        read -r confirm_pwd < /dev/tty
        if [ "$new_pwd" != "$confirm_pwd" ]; then
            log_warn "两次输入的密码不一致，请重新输入"
            continue
        fi
        CURRENT_WEB_PWD="$new_pwd"
        return
    done
}

# ================== 显示安装信息 ==================
show_install_info() {
    read_current_port
    local local_ip
    local_ip=$(get_local_ip)
    local run_status="${RED}已停止${NC}"
    check_web_running && run_status="${GREEN}运行中${NC}"

    echo ""
    echo -e "${CYAN}=========================================="
    echo -e "       🖥️  FRPS Web 面板安装信息"
    echo -e "==========================================${NC}"
    echo -e "  🌐 访问地址:      ${GREEN}http://${local_ip}:${CURRENT_WEB_PORT}${NC}"
    echo -e "  👤 登录账号:      ${GREEN}${DEFAULT_WEB_USER}${NC}"
    echo -e "  🔑 登录密码:      ${GREEN}${CURRENT_WEB_PWD}${NC}"
    echo -e "  📡 运行状态:      ${run_status}"
    echo ""
    echo -e "  📁 面板程序位置:  ${WEB_MANAGER_FILE}"
    echo -e "  📁 密码配置文件:  ${PANEL_CONFIG_FILE}"
    echo -e "  📁 操作日志文件:  ${PANEL_LOG_FILE}"
    echo -e "  📁 面板独立目录:  ${PANEL_DIR}"
    echo -e "  💡 ${YELLOW}面板与 FRPS 服务端完全独立，卸载 FRPS 不影响面板${NC}"
    if [ "$HAS_SYSTEMD" = "1" ]; then
        echo -e "  ⚙️  守护服务名:    ${WEB_SERVICE_NAME}.service"
        echo ""
        echo -e "  ${YELLOW}常用服务命令:${NC}"
        echo -e "    启动: systemctl start ${WEB_SERVICE_NAME}"
        echo -e "    停止: systemctl stop ${WEB_SERVICE_NAME}"
        echo -e "    重启: systemctl restart ${WEB_SERVICE_NAME}"
        echo -e "    日志: journalctl -u ${WEB_SERVICE_NAME} -f"
    fi
    echo -e "${CYAN}==========================================${NC}"
    echo ""
}

# ================== 卸载 ==================
uninstall_panel() {
    echo ""
    echo -e "${RED}=========================================="
    echo -e "       ⚠️  卸载 FRPS Web 管理面板"
    echo -e "==========================================${NC}"
    echo -e "  ${YELLOW}注意: 仅卸载 Web 面板 (${PANEL_DIR})${NC}"
    echo -e "  ${YELLOW}不会删除 FRPS 服务端 (${FRPS_DIR})${NC}"
    while true; do
        echo -n "确认要卸载吗？(输入 yes 继续): "
        read -r confirm < /dev/tty
        if [ "$confirm" = "yes" ]; then break; fi
        if [ "$confirm" = "no" ] || [ -z "$confirm" ]; then
            log_info "已取消卸载操作"
            return
        fi
        log_warn "请输入 yes 或 no"
    done

    log_info "开始卸载..."
    if [ "$HAS_SYSTEMD" = "1" ]; then
        systemctl stop "${WEB_SERVICE_NAME}" 2>/dev/null || true
        systemctl disable "${WEB_SERVICE_NAME}" 2>/dev/null || true
        rm -f "/etc/systemd/system/${WEB_SERVICE_NAME}.service"
        systemctl daemon-reload 2>/dev/null || true
    fi
    pkill -f "python3 ${WEB_MANAGER_FILE}" 2>/dev/null || true
    # 仅删除面板目录，绝不触碰 FRPS 目录
    rm -rf "${PANEL_DIR}"
    log_info "✅ FRPS Web 管理面板已完全卸载！"
}

# ================== 修改密码(菜单) ==================
menu_change_password() {
    input_password
    log_info "正在写入新密码..."
    if write_panel_password "$CURRENT_WEB_PWD"; then
        reload_panel >/dev/null 2>&1
        log_info "✅ 密码修改成功！面板已重载，请使用新密码重新登录"
        show_install_info
    else
        log_error "❌ 密码写入失败，请检查 Python3 环境"
    fi
}

# ================== 修改端口(菜单) ==================
menu_change_port() {
    input_port
    log_info "正在修改面板监听端口..."
    if patch_panel_port "$CURRENT_WEB_PORT"; then
        if reload_panel; then
            log_info "✅ 端口修改成功，新端口: ${GREEN}${CURRENT_WEB_PORT}${NC}"
            log_warn "请确保防火墙/安全组已放行端口 ${CURRENT_WEB_PORT}"
            show_install_info
        else
            log_error "❌ 面板重启失败，请检查端口是否被占用"
        fi
    else
        log_error "❌ 端口修改失败，未找到程序内端口配置行"
    fi
}

# ================== 管理菜单 ==================
show_management_menu() {
    while true; do
        read_current_port
        local run_status="${RED}已停止${NC}"
        check_web_running && run_status="${GREEN}运行中${NC}"

        echo ""
        echo -e "${YELLOW}=========================================="
        echo -e "   🔍 检测到 FRPS Web 面板已安装"
        echo -e "==========================================${NC}"
        echo -e "  📡 面板状态:   ${run_status}"
        echo -e "  🌐 访问端口:   ${CYAN}${CURRENT_WEB_PORT}${NC}"
        echo -e "  📁 面板目录:   ${PANEL_DIR}"
        echo ""
        echo -e "${CYAN}请选择操作:${NC}"
        echo -e "  1) 🔄 重装面板 (保留密码和端口配置)"
        echo -e "  2) 🗑️  清除配置重装 (恢复默认端口/密码)"
        echo -e "  3) 🔐 修改面板密码"
        echo -e "  4) 🔌 修改访问端口"
        echo -e "  5) ♻️  重载面板服务"
        echo -e "  6) 📄 查看安装信息"
        echo -e "  7) ❌ 卸载清理面板"
        echo -e "  0) 🚪 退出"
        echo ""
        echo -n "请输入选项 [0-7]: "
        read -r menu_choice < /dev/tty

        case "$menu_choice" in
            1)
                log_info "开始保留配置重装..."
                read_current_port
                local keep_port="$CURRENT_WEB_PORT"
                if install_panel_files; then
                    patch_panel_port "$keep_port"
                    # 保留原有密码配置文件，不重新生成
                    setup_daemon
                    CURRENT_WEB_PWD="(保留原密码，如已遗忘请选择菜单[2]重置)"
                    show_install_info
                else
                    log_error "❌ 重装失败"
                fi
                exit 0
                ;;
            2)
                log_warn "⚠️ 这将恢复默认端口 ${DEFAULT_WEB_PORT} 并重新设置密码！"
                echo -n "确认继续？(yes/no): "
                read -r confirm_reset < /dev/tty
                if [ "$confirm_reset" != "yes" ]; then
                    log_info "已取消"
                    continue
                fi
                # 仅删除面板目录下的密码文件，不影响 FRPS
                rm -f "${PANEL_CONFIG_FILE}"
                if [ "$HAS_SYSTEMD" = "1" ]; then
                    systemctl stop "${WEB_SERVICE_NAME}" 2>/dev/null || true
                fi
                pkill -f "python3 ${WEB_MANAGER_FILE}" 2>/dev/null || true
                do_full_install
                exit 0
                ;;
            3)
                menu_change_password
                exit 0
                ;;
            4)
                menu_change_port
                exit 0
                ;;
            5)
                log_info "正在重载面板服务..."
                if reload_panel; then
                    log_info "✅ 面板服务已重载"
                else
                    log_error "❌ 重载失败"
                fi
                exit 0
                ;;
            6)
                CURRENT_WEB_PWD="(密码已加密存储，如遗忘请使用菜单[3]重置)"
                show_install_info
                exit 0
                ;;
            7)
                uninstall_panel
                exit 0
                ;;
            0)
                exit 0
                ;;
            *)
                log_warn "无效选项，请重新输入！"
                sleep 1
                ;;
        esac
    done
}

# ================== 完整安装流程 ==================
do_full_install() {
    input_port
    input_password

    if ! install_panel_files; then
        log_error "❌ 面板安装失败"
        exit 1
    fi

    log_info "正在应用端口配置: ${CURRENT_WEB_PORT}"
    patch_panel_port "$CURRENT_WEB_PORT"

    log_info "正在写入密码配置..."
    if ! write_panel_password "$CURRENT_WEB_PWD"; then
        log_error "❌ 密码配置写入失败"
        exit 1
    fi
    log_info "✅ 密码配置完成"

    setup_daemon
    show_install_info
    log_warn "如无法访问，请确保防火墙/云安全组已放行端口 ${CURRENT_WEB_PORT}"
    log_info "🎉 FRPS Web 管理面板部署完成！"
}

# ================== 主执行流程 ==================
main() {
    clear 2>/dev/null || true
    echo -e "${CYAN}=========================================="
    echo -e "   FRPS Web 管理面板 一键部署脚本 (v2.0)"
    echo -e "   独立目录版 - 与 FRPS 服务端完全解耦"
    echo -e "==========================================${NC}"

    check_root
    check_tty
    detect_arch
    detect_system_info
    install_dependencies

    if ! check_python3; then
        log_error "❌ Python3 环境不满足要求，无法安装面板"
        exit 1
    fi

    # 已安装则进入管理菜单
    if check_web_installed; then
        show_management_menu
        exit 0
    fi

    # 全新安装
    do_full_install
    exit 0
}

main "$@"