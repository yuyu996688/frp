#!/usr/bin/env bash
# frp Docker 交互式安装/管理脚本（服务端 frps / 客户端 frpc）
# 按当前系统架构自动选择 latest-arm64 / latest-amd64 拉取并运行，无需环境变量与本地构建。
# 用法: ./install.sh

set -e

# 按当前系统自动选择 tag（不使用版本号）
detect_frp_tag() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64)   echo "latest-amd64" ;;
    aarch64|arm64) echo "latest-arm64" ;;
    *) echo "latest-amd64" ;; # 未知时默认 amd64
  esac
}

FRP_IMAGE_TAG="$(detect_frp_tag)"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-yuyu8868}"
FRPS_IMAGE="$IMAGE_NAMESPACE/frps:${FRP_IMAGE_TAG}"
FRPC_IMAGE="$IMAGE_NAMESPACE/frpc:${FRP_IMAGE_TAG}"
FRPS_CONTAINER_NAME="${FRPS_CONTAINER_NAME:-frps}"
FRPC_CONTAINER_NAME="${FRPC_CONTAINER_NAME:-frpc}"
STATE_FILE=".frp-docker-state"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "错误: 未找到命令 '$1'，请先安装 Docker。" >&2
    exit 1
  fi
}

check_docker() {
  need_cmd docker
}

# 获取脚本所在目录
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# 拉取最新镜像
ensure_image() {
  local image="$1"
  echo "拉取镜像: $image"
  docker pull "$image"
}

# 读取输入，支持默认值
read_default() {
  local prompt="$1"
  local default="$2"
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " val
    echo "${val:-$default}"
  else
    read -r -p "${prompt}: " val
    echo "$val"
  fi
}

# 读取必填
read_required() {
  local prompt="$1"
  local default="$2"
  local val
  while true; do
    val="$(read_default "$prompt" "$default")"
    if [[ -n "$val" ]]; then
      echo "$val"
      return
    fi
    echo "不能为空，请重新输入。" >&2
  done
}

gen_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    echo "changeme-$(date +%s)"
  fi
}

# ---------- 交互式生成 frps 配置 ----------
interactive_frps_config() {
  local dir="$1"
  mkdir -p "$dir"
  local bind_port auth_token web_port web_user web_password

  echo ""
  echo "========== frps 服务端配置 =========="
  bind_port="$(read_default "绑定端口（客户端连接）" "7000")"
  auth_token="$(read_default "认证令牌 auth.token（与客户端一致，留空则随机生成）" "")"
  if [[ -z "$auth_token" ]]; then
    auth_token="$(gen_token)"
    echo "  已生成 token: $auth_token（请妥善保存，客户端需填写相同值）"
  fi
  web_port="$(read_default "Web 控制台端口" "7500")"
  web_user="$(read_default "Web 控制台用户名" "admin")"
  web_password="$(read_default "Web 控制台密码" "admin")"

  cat > "$dir/frps.docker.toml" << EOF
# frps Docker 配置（交互式生成）
bindAddr = "0.0.0.0"
bindPort = $bind_port
auth.token = "$auth_token"
enablePrometheus = true

webServer.addr = "0.0.0.0"
webServer.port = $web_port
webServer.user = "$web_user"
webServer.password = "$web_password"
EOF
  echo "已写入: $dir/frps.docker.toml"
  # 记录端口供 docker run 使用
  echo "bind_port=$bind_port" > "$dir/$STATE_FILE"
  echo "web_port=$web_port" >> "$dir/$STATE_FILE"
}

# ---------- 交互式生成 frpc 配置 ----------
interactive_frpc_config() {
  local dir="$1"
  mkdir -p "$dir"
  local server_addr server_port auth_token web_port web_user web_password

  echo ""
  echo "========== frpc 客户端配置 =========="
  server_addr="$(read_required "frps 服务端地址（IP 或域名）" "")"
  server_port="$(read_default "frps 服务端端口" "7000")"
  auth_token="$(read_required "认证令牌 auth.token（与 frps 一致）" "")"
  web_port="$(read_default "Web 控制台端口" "7400")"
  web_user="$(read_default "Web 控制台用户名" "admin")"
  web_password="$(read_default "Web 控制台密码" "admin")"

  cat > "$dir/frpc.docker.toml" << EOF
# frpc Docker 配置（交互式生成）
serverAddr = "$server_addr"
serverPort = $server_port
auth.token = "$auth_token"

webServer.addr = "0.0.0.0"
webServer.port = $web_port
webServer.user = "$web_user"
webServer.password = "$web_password"

# 示例代理（取消注释并按需修改）
# [[proxies]]
# name = "ssh"
# type = "tcp"
# localIP = "127.0.0.1"
# localPort = 22
# remotePort = 6000
EOF
  echo "已写入: $dir/frpc.docker.toml"
  echo "web_port=$web_port" > "$dir/$STATE_FILE"
}

# ---------- 公共：启动 frps 容器（host 网络，配置已存在）----------
run_frps_container() {
  local dir="$1"
  local web_port=7500
  [[ -f "$dir/$STATE_FILE" ]] && source "$dir/$STATE_FILE" 2>/dev/null || true

  docker run -d \
    --name "$FRPS_CONTAINER_NAME" \
    --restart always \
    --network host \
    -v "$dir/frps.docker.toml:/etc/frp/frps.toml" \
    -e TZ=Asia/Shanghai \
    "$FRPS_IMAGE" -c /etc/frp/frps.toml
  echo "  控制台: http://<本机IP>:${web_port}"
  echo "  配置: $dir/frps.docker.toml"
}

# ---------- 公共：启动 frpc 容器----------
run_frpc_container() {
  local dir="$1"
  local web_port=7400
  [[ -f "$dir/$STATE_FILE" ]] && source "$dir/$STATE_FILE" 2>/dev/null || true

  docker run -d \
    --name "$FRPC_CONTAINER_NAME" \
    --restart always \
    -p "${web_port}:${web_port}" \
    -v "$dir/frpc.docker.toml:/etc/frp/frpc.toml" \
    -e TZ=Asia/Shanghai \
    "$FRPC_IMAGE" -c /etc/frp/frpc.toml
  echo "  控制台: http://<本机IP>:${web_port}"
  echo "  配置: $dir/frpc.docker.toml"
}

# ---------- 安装 ----------
do_install() {
  local mode="$1"
  local dir="$2"
  dir="$(cd "$dir" && pwd)"

  if [[ "$mode" == "server" ]]; then
    interactive_frps_config "$dir"
    echo ""
    ensure_image "$FRPS_IMAGE"
    docker stop "$FRPS_CONTAINER_NAME" 2>/dev/null || true
    docker rm "$FRPS_CONTAINER_NAME" 2>/dev/null || true
    run_frps_container "$dir"
    echo ""
    echo "frps 已安装并启动。"
  else
    interactive_frpc_config "$dir"
    echo ""
    ensure_image "$FRPC_IMAGE"
    docker stop "$FRPC_CONTAINER_NAME" 2>/dev/null || true
    docker rm "$FRPC_CONTAINER_NAME" 2>/dev/null || true
    run_frpc_container "$dir"
    echo ""
    echo "frpc 已安装并启动。"
  fi
}

# ---------- 卸载 ----------
do_uninstall() {
  local mode="$1"
  local dir="$2"
  local cname
  if [[ "$mode" == "server" ]]; then
    cname="$FRPS_CONTAINER_NAME"
  else
    cname="$FRPC_CONTAINER_NAME"
  fi

  docker stop "$cname" 2>/dev/null || true
  docker rm "$cname" 2>/dev/null || true
  echo "已停止并删除容器: $cname"

  local remove_cfg
  read -r -p "是否删除配置文件？(y/N): " remove_cfg
  if [[ "${remove_cfg,,}" == "y" || "${remove_cfg,,}" == "yes" ]]; then
    if [[ "$mode" == "server" ]]; then
      rm -f "$dir/frps.docker.toml" "$dir/$STATE_FILE" 2>/dev/null || true
      echo "已删除 $dir/frps.docker.toml"
    else
      rm -f "$dir/frpc.docker.toml" "$dir/$STATE_FILE" 2>/dev/null || true
      echo "已删除 $dir/frpc.docker.toml"
    fi
  fi
}

# ---------- 启动 ----------
do_start() {
  local mode="$1"
  local cname
  if [[ "$mode" == "server" ]]; then
    cname="$FRPS_CONTAINER_NAME"
  else
    cname="$FRPC_CONTAINER_NAME"
  fi
  docker start "$cname"
  echo "已启动: $cname"
}

# ---------- 停止 ----------
do_stop() {
  local mode="$1"
  local cname
  if [[ "$mode" == "server" ]]; then
    cname="$FRPS_CONTAINER_NAME"
  else
    cname="$FRPC_CONTAINER_NAME"
  fi
  docker stop "$cname"
  echo "已停止: $cname"
}

# ---------- 重启 ----------
do_restart() {
  local mode="$1"
  local cname
  if [[ "$mode" == "server" ]]; then
    cname="$FRPS_CONTAINER_NAME"
  else
    cname="$FRPC_CONTAINER_NAME"
  fi
  docker restart "$cname"
  echo "已重启: $cname"
}

# ---------- 更新（拉取最新镜像并用现有配置重建容器）---------
do_update() {
  local mode="$1"
  local dir="$2"
  dir="$(cd "$dir" && pwd)"

  if [[ "$mode" == "server" ]]; then
    if [[ ! -f "$dir/frps.docker.toml" ]]; then
      echo "错误: 未找到配置 $dir/frps.docker.toml，请先执行安装。" >&2
      exit 1
    fi
    ensure_image "$FRPS_IMAGE"
    docker stop "$FRPS_CONTAINER_NAME" 2>/dev/null || true
    docker rm "$FRPS_CONTAINER_NAME" 2>/dev/null || true
    run_frps_container "$dir"
    echo ""
    echo "frps 已更新并启动。"
  else
    if [[ ! -f "$dir/frpc.docker.toml" ]]; then
      echo "错误: 未找到配置 $dir/frpc.docker.toml，请先执行安装。" >&2
      exit 1
    fi
    ensure_image "$FRPC_IMAGE"
    docker stop "$FRPC_CONTAINER_NAME" 2>/dev/null || true
    docker rm "$FRPC_CONTAINER_NAME" 2>/dev/null || true
    run_frpc_container "$dir"
    echo ""
    echo "frpc 已更新并启动。"
  fi
}

# ---------- 解析已有安装目录的端口（用于启动/停止/重启时无需 state）----------
# 服务端从 frps.docker.toml 读 bindPort、webServer.port；客户端读 webServer.port
# 当前 启动/停止/重启 不依赖端口映射，容器已存在即可，所以这里不解析也可以。

# ---------- 主菜单 ----------
main_menu() {
  check_docker

  echo ""
  echo "=========================================="
  echo "       frp Docker 交互式安装/管理"
  echo "=========================================="
  echo ""
  echo "请选择角色："
  echo "  1) 服务端 (frps)"
  echo "  2) 客户端 (frpc)"
  echo "  0) 退出"
  echo ""
  local role
  role="$(read_default "请选择 [1]" "1")"
  local mode=""
  case "$role" in
    1) mode="server" ;;
    2) mode="client" ;;
    0) echo "再见。"; exit 0 ;;
    *) echo "无效选择。"; exit 1 ;;
  esac

  local default_dir="${SCRIPT_DIR:-.}"
  if [[ -z "$SCRIPT_DIR" ]]; then
    default_dir="./frp-docker"
  fi
  local dir
  dir="$(read_default "安装/工作目录" "$default_dir")"
  dir="$(eval "echo $dir")"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" || { echo "无法创建目录: $dir"; exit 1; }
  fi
  dir="$(cd "$dir" && pwd)"

  echo ""
  echo "请选择操作："
  echo "  1) 安装（会交互生成配置并启动容器）"
  echo "  2) 卸载（停止并删除容器，可选删除配置）"
  echo "  3) 启动"
  echo "  4) 停止"
  echo "  5) 重启"
  echo "  6) 更新（拉取最新镜像并用现有配置重建容器）"
  echo "  0) 返回/退出"
  echo ""
  local action
  action="$(read_default "请选择 [1]" "1")"

  case "$action" in
    1) do_install "$mode" "$dir" ;;
    2) do_uninstall "$mode" "$dir" ;;
    3) do_start "$mode" "$dir" ;;
    4) do_stop "$mode" "$dir" ;;
    5) do_restart "$mode" "$dir" ;;
    6) do_update "$mode" "$dir" ;;
    0) echo "再见。"; exit 0 ;;
    *) echo "无效选择。"; exit 1 ;;
  esac
}

main_menu "$@"
