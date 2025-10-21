#!/usr/bin/env bash
# caddy-reverse-proxy.sh
# 自动安装&配置Caddy反代（支持SSL、HTTP验证、IPv6、WS、自动续期）

set -e

SYSTEMD_SERVICE="/etc/systemd/system/caddy.service"

# ===== 用户输入 =====
read -rp "请输入反向代理目标地址 (例如 127.0.0.1): " backend_host
read -rp "请输入反向代理目标端口 [默认6366]: " backend_port
backend_port=${backend_port:-6366}

read -rp "请输入监听端口 [默认443]: " listen_port
listen_port=${listen_port:-443}

read -rp "请输入反代访问域名 (必须已解析到本机): " domain
if [[ -z "$domain" ]]; then
  echo "❌ 域名必填！"
  exit 1
fi

read -rp "请输入邮箱（可选，留空则不设置）: " ssl_email

echo "ℹ️  将使用HTTP验证申请SSL证书（通过80端口自动验证）"

# ===== 检查IPv6支持 =====
if ping6 -c1 google.com &>/dev/null; then
    listen_address="[::]"
    echo "✅ 检测到IPv6支持，将使用IPv6监听"
else
    listen_address="0.0.0.0"
    echo "⚠️ 未检测到IPv6支持，将使用IPv4监听"
fi

# ===== 安装Caddy =====
if ! command -v caddy &>/dev/null; then
    echo "🔧 安装Caddy..."
    apt update && apt install -y curl unzip gnupg debian-keyring debian-archive-keyring apt-transport-https

    echo "🌐 配置Caddy官方APT仓库..."
    mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor --yes --batch --output /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod o+r /etc/apt/sources.list.d/caddy-stable.list

    apt update
    apt install -y caddy

    if ! command -v caddy &>/dev/null; then
        echo "❌ Caddy 安装失败，请手动检查环境后重试"
        exit 1
    fi

    # 确保caddy在正确位置
    if [[ -f "/usr/bin/caddy" ]]; then
        mv /usr/bin/caddy /usr/local/bin/caddy
    fi
fi

mkdir -p /etc/caddy

# ===== 配置systemd服务 =====
cat >"$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Caddy web server
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF

# ===== 生成Caddyfile =====
# 生成全局配置块（如果有邮箱）
if [[ -n "$ssl_email" ]]; then
cat >/etc/caddy/Caddyfile <<EOF
{
    email $ssl_email
}

$domain {
    bind $listen_address
    encode gzip
    
    @websockets {
        header Connection *Upgrade*
        header Upgrade websocket
    }
    
    reverse_proxy $backend_host:$backend_port {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
    }
}
EOF
else
cat >/etc/caddy/Caddyfile <<EOF
$domain {
    bind $listen_address
    encode gzip
    
    @websockets {
        header Connection *Upgrade*
        header Upgrade websocket
    }
    
    reverse_proxy $backend_host:$backend_port {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
    }
}
EOF
fi

# ===== 重启Caddy =====
systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy

echo "✅ Caddy反代已部署完成"
echo "🔐 证书将通过HTTP-01验证自动申请和续期"
echo "🌐 访问地址：https://$domain"
echo "ℹ️  首次访问可能需要等待几秒钟完成证书申请"
