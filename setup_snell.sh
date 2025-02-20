#!/bin/bash

# Snell v4.1.1 一键安装脚本
# 作者: [你的名字]
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

# 更新系统并安装依赖
echo "正在更新系统并安装依赖..."
apt update && apt install -y unzip wget || {
    echo "依赖安装失败，请检查网络或包管理器"
    exit 1
}

# 下载并安装 Snell
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

# 交互式配置
echo "开始配置 Snell 服务..."

# 自定义端口
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

# 自定义 PSK
read -p "请输入 PSK (直接回车随机生成复杂密钥): " PSK
if [ -z "$PSK" ]; then
    PSK=$(random_psk)
    echo "使用随机 PSK: $PSK"
fi

# 自定义 IPv6
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

# 自定义 DNS
read -p "请输入 DNS 服务器地址 (多个用逗号分隔，直接回车使用系统默认): " DNS
if [ -z "$DNS" ]; then
    DNS_LINE=""  # 空值表示使用系统默认 DNS
    echo "使用系统默认 DNS"
else
    DNS_LINE="dns = $DNS"
    echo "使用自定义 DNS: $DNS"
fi

# 创建配置文件
echo "创建 Snell 配置文件..."
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
[snell-server]
listen = ${LISTEN_ADDR}:${PORT}
psk = ${PSK}
ipv6 = ${IPV6}
${DNS_LINE}
EOF

# 创建 systemd 服务
echo "设置 Snell 为系统服务..."
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

# 启用并启动服务
systemctl daemon-reload
systemctl enable snell
systemctl start snell

# 检查服务状态
echo "检查 Snell 服务状态..."
if systemctl is-active snell >/dev/null; then
    echo "Snell 服务已成功启动！"
    echo "监听地址: ${LISTEN_ADDR}:${PORT}"
    echo "PSK: ${PSK}"
    echo "IPv6: ${IPV6}"
    if [ -n "$DNS" ]; then
        echo "DNS: ${DNS}"
    else
        echo "DNS: 系统默认"
    fi
    echo "客户端配置示例:"
    echo "MySnell = snell, YOUR_VPS_IP, ${PORT}, psk=${PSK}, version=4, tfo=true"
else
    echo "Snell 服务启动失败，请检查日志: journalctl -u snell"
    exit 1
fi

# 可选优化：启用 BBR
echo "启用 TCP BBR 优化..."
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p >/dev/null
if lsmod | grep -q tcp_bbr; then
    echo "BBR 已启用"
else
    echo "BBR 启用失败，可能需要重启系统"
fi

echo "Snell v${SNELL_VERSION} 安装完成！"
