#!/usr/bin/env bash
# caddy-reverse-proxy.sh
# 自动安装&配置Caddy反代（支持SSL、DNS验证、IPv6、WS、自动续期免输入）

set -e

ENV_FILE="/etc/caddy/dns.env"
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
read -rp "是否使用 DNS 验证申请证书？[y/N]: " use_dns
use_dns=${use_dns:-N}

dns_provider=""
declare -A env_vars

if [[ "$use_dns" =~ ^[Yy]$ ]]; then
  echo "请选择 DNS 服务商:"
  echo "1) Cloudflare"
  echo "2) Dnspod (国内站)"
  echo "3) Dnspod (国际站)"
  echo "4) Aliyun (国内)"
  echo "5) Aliyun (国际)"
  read -rp "输入编号: " dns_choice

  case $dns_choice in
    1)
      dns_provider="cloudflare"
      read -rp "Cloudflare API Token: " CF_API_TOKEN
      env_vars["CF_API_TOKEN"]=$CF_API_TOKEN
      ;;
    2)
      dns_provider="dnspod"
      read -rp "Dnspod 国内站 API ID: " DP_ID
      read -rp "Dnspod 国内站 API Key: " DP_KEY
      env_vars["DP_ID"]=$DP_ID
      env_vars["DP_KEY"]=$DP_KEY
      ;;
    3)
      dns_provider="dnspod"
      read -rp "Dnspod 国际站 API Token: " DP_TOKEN
      env_vars["DP_TOKEN"]=$DP_TOKEN
      ;;
    4|5)
      dns_provider="alidns"
      read -rp "Aliyun AccessKey ID: " ALICLOUD_ACCESS_KEY
      read -rp "Aliyun AccessKey Secret: " ALICLOUD_SECRET_KEY
      env_vars["ALICLOUD_ACCESS_KEY"]=$ALICLOUD_ACCESS_KEY
      env_vars["ALICLOUD_SECRET_KEY"]=$ALICLOUD_SECRET_KEY
      ;;
    *)
      echo "❌ 无效选项"
      exit 1
      ;;
  esac
fi

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

# ===== 保存环境变量到dns.env =====
echo "# Caddy DNS Provider API Keys" >"$ENV_FILE"
for key in "${!env_vars[@]}"; do
  echo "$key=${env_vars[$key]}" >>"$ENV_FILE"
done
chmod 600 "$ENV_FILE"

# ===== 配置systemd服务加载环境变量 =====
cat >"$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Caddy web server
After=network.target

[Service]
User=root
EnvironmentFile=$ENV_FILE
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF

# ===== 全局配置 =====
if [[ -n "$ssl_email" ]]; then
    global_cfg="{ email $ssl_email }"
else
    global_cfg="{}"
fi

# ===== 生成Caddyfile =====
if [[ -n "$dns_provider" ]]; then
cat >/etc/caddy/Caddyfile <<EOF
$global_cfg

https://$domain:$listen_port {
    bind $listen_address
    encode gzip
    tls {
        dns $dns_provider
    }
    @websockets {
        header Connection *Upgrade*
        header Upgrade websocket
    }
    reverse_proxy $backend_host:$backend_port {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
http://$domain:80 {
    redir https://$domain:$listen_port{uri} permanent
}
EOF
else
cat >/etc/caddy/Caddyfile <<EOF
$global_cfg

https://$domain:$listen_port {
    bind $listen_address
    encode gzip
    @websockets {
        header Connection *Upgrade*
        header Upgrade websocket
    }
    reverse_proxy $backend_host:$backend_port {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
http://$domain:80 {
    redir https://$domain:$listen_port{uri} permanent
}
EOF
fi

# ===== 重启Caddy =====
systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy

echo "✅ Caddy反代已部署完成"
echo "🔑 证书续期将自动使用 $ENV_FILE 中的DNS API Key，无需再次输入"
echo "访问地址：https://$domain:$listen_port"
