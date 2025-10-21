#!/usr/bin/env bash
# caddy-reverse-proxy.sh
# 自动安装&配置Caddy反代（支持SSL、DNS验证、IPv6、WS、自动续期免输入）

set -e

export DEBIAN_FRONTEND=noninteractive

install_caddy_from_apt() {
    echo "🌐 尝试通过APT仓库安装Caddy..."
    set +e
    local status=0
    local log_file="/tmp/caddy-apt-install.log"

    : >"$log_file"

    local tmp_key
    local tmp_list
    tmp_key=$(mktemp)
    tmp_list=$(mktemp)

    if [[ $status -eq 0 ]]; then
        mkdir -p /usr/share/keyrings /etc/apt/sources.list.d >>"$log_file" 2>&1 || status=$?
    fi

    if [[ $status -eq 0 ]]; then
        apt-get update >>"$log_file" 2>&1 || status=$?
    fi

    if [[ $status -eq 0 ]]; then
        apt-get install -y --no-install-recommends debian-keyring debian-archive-keyring apt-transport-https curl gnupg >>"$log_file" 2>&1 || status=$?
    fi

    if [[ $status -eq 0 ]]; then
        curl -fsSL --retry 3 --retry-delay 2 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o "$tmp_key" >>"$log_file" 2>&1 || status=$?
    fi

    if [[ $status -eq 0 ]]; then
        gpg --dearmor --yes --output /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$tmp_key" >>"$log_file" 2>&1 || status=$?
    fi

    if [[ $status -eq 0 ]]; then
        curl -fsSL --retry 3 --retry-delay 2 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o "$tmp_list" >>"$log_file" 2>&1 || status=$?
    fi

    if [[ $status -eq 0 ]]; then
        install -m 644 "$tmp_list" /etc/apt/sources.list.d/caddy-stable.list >>"$log_file" 2>&1 || status=$?
    fi

    if [[ $status -eq 0 ]]; then
        chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list >>"$log_file" 2>&1 || status=$?
    fi

    if [[ $status -eq 0 ]]; then
        apt-get update >>"$log_file" 2>&1 || status=$?
    fi

    if [[ $status -eq 0 ]]; then
        apt-get install -y --no-install-recommends caddy >>"$log_file" 2>&1 || status=$?
    fi

    rm -f "$tmp_key" "$tmp_list"

    set -e
    return $status
}

install_caddy_from_github() {
    echo "🌐 APT 仓库不可用，尝试从 GitHub 下载 Caddy 二进制..."
    set +e
    local workdir="/tmp/caddy-download"
    local status=0
    local arch="$(uname -m)"
    local caddy_arch=""

    case "$arch" in
        x86_64|amd64)
            caddy_arch="amd64"
            ;;
        aarch64|arm64)
            caddy_arch="arm64"
            ;;
        armv7l|armv7)
            caddy_arch="armv7"
            ;;
        armv6l|armv6)
            caddy_arch="armv6"
            ;;
        *)
            echo "❌ 当前架构($arch)暂不支持自动安装"
            set -e
            return 1
            ;;
    esac

    rm -rf "$workdir"
    mkdir -p "$workdir"

    if [[ $status -eq 0 ]]; then
        curl -sSfL "https://github.com/caddyserver/caddy/releases/latest/download/caddy-linux-${caddy_arch}.tar.gz" -o "$workdir/caddy.tar.gz" || status=$?
    fi
    if [[ $status -eq 0 ]]; then
        tar -xzf "$workdir/caddy.tar.gz" -C "$workdir" || status=$?
    fi
    if [[ $status -eq 0 ]]; then
        install -m 755 "$workdir/caddy" /usr/local/bin/caddy || status=$?
    fi
    if [[ $status -eq 0 ]]; then
        setcap 'cap_net_bind_service=+ep' /usr/local/bin/caddy 2>/dev/null || true
    fi

    rm -rf "$workdir"
    set -e
    return $status
}

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
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl unzip gnupg libcap2-bin

    install_success=false

    if install_caddy_from_apt && command -v caddy &>/dev/null; then
        echo "✅ 已通过APT仓库安装Caddy"
        install_success=true
    else
        echo "⚠️ APT 仓库安装失败，详细日志位于 /tmp/caddy-apt-install.log"
        if install_caddy_from_github && command -v caddy &>/dev/null; then
            echo "✅ 已通过GitHub二进制安装Caddy"
            install_success=true
        else
            echo "⚠️ GitHub 二进制安装失败或未检测到Caddy"
        fi
    fi

    if [[ $install_success != true ]]; then
        echo "❌ Caddy 安装失败，请手动检查环境后重试"
        exit 1
    fi

    # 确保caddy在正确位置
fi

caddy_bin=$(command -v caddy)
if [[ -z "$caddy_bin" ]]; then
    echo "❌ 未找到Caddy可执行文件，请检查安装"
    exit 1
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
ExecStart=$caddy_bin run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=$caddy_bin reload --config /etc/caddy/Caddyfile --adapter caddyfile
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
