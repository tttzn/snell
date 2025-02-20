#!/bin/bash

# Snell v4.1.1 一键管理脚本
# 作者: tttzn
# 日期: 2025-02-20

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 权限运行此脚本: sudo bash $0"
    exit 1
fi

# 定义变量
SNELL_VERSION="4.1.1"
SNELL_URL="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-amd64.zip"
CONFIG_DIR="/etc/snell"
CONFIG_FILE="${CONFIG_DIR}/snell-server.conf"
SERVICE_FILE="/lib/systemd/system/snell.service"

# 生成随机端口 (1024-65535)
random_port() {
    echo $(( RANDOM % 64512 + 1024 ))
}

# 生成复杂 PSK（32位随机字符串）
random_psk() {
    tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c 32
}

# 安装 Snell 函数
install_snell() {
    echo "正在更新系统并安装依赖..."
    apt update && apt install -y unzip wget || {
        echo "依赖安装失败，请检查网络或包管理器"
        exit 1
    }
    echo "正在下载 Snell v${SNELL_VERSION}..."
    wget -O snell.zip "$SNELL_URL" || {
        echo "下载失败，请检查网络或 URL"
        exit 1
    }
    unzip -o snell.zip -d /usr/local/bin/ || {
        echo "解压失败，请检查 unzip 是否正确安装"
        exit 1
    }
    chmod +x /usr/local/bin/snell-server
    rm snell.zip

    echo "开始配置 Snell 服务..."
    read -p "请输入监听端口 (1024-65535，直接回车随机生成): " PORT
    if [ -z "$PORT" ]; then
        PORT=$(random_port)
        echo "使用随机端口: $PORT"
    else
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
            echo "端口无效，使用随机端口"
            PORT=$(random_port)
        fi
    fi

    read -p "请输入 PSK (直接回车随机生成复杂密钥): " PSK
    if [ -z "$PSK" ]; then
        PSK=$(random_psk)
        echo "使用随机 PSK: $PSK"
    fi

    while true; do
        read -p "是否启用 IPv6 (y/n，直接回车默认否): " IPV6
        case "$IPV6" in
            [Yy]*)
                IPV6="true"
                LISTEN_ADDR="::0"
                break
                ;;
            [Nn]*|"")
                IPV6="false"
                LISTEN_ADDR="0.0.0.0"
                break
                ;;
            *)
                echo "请输入 y 或 n"
                ;;
        esac
    done

    read -p "请输入 DNS 服务器地址 (多个用逗号分隔，直接回车使用系统默认): " DNS
    if [ -z "$DNS" ]; then
        DNS_LINE=""
        echo "使用系统默认 DNS"
    else
        DNS_LINE="dns = $DNS"
        echo "使用自定义 DNS: $DNS"
    fi

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
[snell-server]
listen = ${LISTEN_ADDR}:${PORT}
psk = ${PSK}
ipv6 = ${IPV6}
${DNS_LINE}
EOF

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c ${CONFIG_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell
    systemctl start snell

    if systemctl is-active snell >/dev/null; then
        echo "Snell 服务已成功启动！"
        echo "客户端配置示例:"
        echo "MySnell = snell, YOUR_VPS_IP, ${PORT}, psk=${PSK}, version=4, tfo=true"
    else
        echo "Snell 服务启动失败，请检查日志: journalctl -u snell"
    fi

    echo "启用 TCP BBR 优化..."
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null
    [ "$(lsmod | grep -c tcp_bbr)" -gt 0 ] && echo "BBR 已启用" || echo "BBR 启用失败"
}

# 卸载 Snell 函数
uninstall_snell() {
    echo "正在卸载 Snell..."
    systemctl stop snell 2>/dev/null
    systemctl disable snell 2>/dev/null
    rm -f "$SERVICE_FILE"
    rm -rf "$CONFIG_DIR"
    rm -f /usr/local/bin/snell-server
    systemctl daemon-reload
    echo "Snell 已卸载"
}

# 更新 Snell 函数
update_snell() {
    if [ ! -f /usr/local/bin/snell-server ]; then
        echo "Snell 未安装，请先选择 1 安装"
        return
    fi
    echo "正在更新 Snell 到 v${SNELL_VERSION}..."
    systemctl stop snell 2>/dev/null
    wget -O snell.zip "$SNELL_URL" || {
        echo "下载失败，请检查网络或 URL"
        exit 1
    }
    unzip -o snell.zip -d /usr/local/bin/ || {
        echo "解压失败，请检查 unzip 是否正确安装"
        exit 1
    }
    chmod +x /usr/local/bin/snell-server
    rm snell.zip
    systemctl start snell
    if systemctl is-active snell >/dev/null; then
        echo "Snell 已更新到 v${SNELL_VERSION} 并重新启动"
    else
        echo "Snell 更新后启动失败，请检查日志: journalctl -u snell"
    fi
}

# 查看配置函数
view_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "当前 Snell 配置:"
        cat "$CONFIG_FILE"
    else
        echo "未找到配置文件，Snell 可能未安装"
    fi
}

# 修改配置函数
modify_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "未找到配置文件，请先安装 Snell"
        return
    fi
    systemctl stop snell 2>/dev/null
    read -p "请输入新监听端口 (当前: $(grep 'listen' "$CONFIG_FILE" | cut -d= -f2 | cut -d: -f2)): " PORT
    read -p "请输入新 PSK (当前: $(grep 'psk' "$CONFIG_FILE" | cut -d= -f2)): " PSK
    while true; do
        read -p "是否启用 IPv6 (y/n，当前: $(grep 'ipv6' "$CONFIG_FILE" | cut -d= -f2)): " IPV6
        case "$IPV6" in
            [Yy]*)
                IPV6="true"
                LISTEN_ADDR="::0"
                break
                ;;
            [Nn]*|"")
                IPV6="false"
                LISTEN_ADDR="0.0.0.0"
                break
                ;;
            *)
                echo "请输入 y 或 n"
                ;;
        esac
    done
    read -p "请输入新 DNS (当前: $(grep 'dns' "$CONFIG_FILE" | cut -d= -f2 || echo '系统默认')): " DNS

    # 更新配置
    PORT=${PORT:-$(grep 'listen' "$CONFIG_FILE" | cut -d= -f2 | cut -d: -f2)}
    PSK=${PSK:-$(grep 'psk' "$CONFIG_FILE" | cut -d= -f2)}
    DNS_LINE=$( [ -n "$DNS" ] && echo "dns = $DNS" || grep 'dns' "$CONFIG_FILE" || echo "")

    cat > "$CONFIG_FILE" <<EOF
[snell-server]
listen = ${LISTEN_ADDR}:${PORT}
psk = ${PSK}
ipv6 = ${IPV6}
${DNS_LINE}
EOF
    systemctl start snell
    echo "配置已更新并重启服务"
}

# 主菜单
while true; do
    echo -e "\nSnell v${SNELL_VERSION} 管理脚本"
    echo "1. 安装 Snell"
    echo "2. 卸载 Snell"
    echo "3. 更新 Snell"
    echo "4. 查看配置"
    echo "5. 修改配置"
    echo "6. 退出脚本"
    read -p "请选择 (1-6): " choice

    case $choice in
        1) install_snell ;;
        2) uninstall_snell ;;
        3) update_snell ;;
        4) view_config ;;
        5) modify_config ;;
        6) echo "退出脚本"; exit 0 ;;
        *) echo "无效选择，请输入 1-6" ;;
    esac
done
