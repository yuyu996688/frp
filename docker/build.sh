#!/usr/bin/env bash
# 多平台构建并推送：使用 latest-amd64 / latest-arm64，当前平台 load+push，其它仅 push。
# 在项目根目录或 docker 目录执行均可。需先登录 registry（docker login）。

set -e

IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-yuyu8868}"
REPO_ROOT=""
if [[ -f "dockerfiles/Dockerfile-for-frps" ]]; then
  REPO_ROOT="$(pwd)"
elif [[ -f "../dockerfiles/Dockerfile-for-frps" ]]; then
  REPO_ROOT="$(cd .. && pwd)"
else
  echo "错误: 请在项目根目录或 docker 目录下执行。" >&2
  exit 1
fi

# 根据当前系统判断架构与平台
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)   CURRENT_PLATFORM="linux/amd64"; CURRENT_TAG="latest-amd64" ;;
  aarch64|arm64) CURRENT_PLATFORM="linux/arm64"; CURRENT_TAG="latest-arm64" ;;
  *) echo "错误: 未支持的架构 $ARCH"; exit 1 ;;
esac

echo "当前系统: $ARCH -> 平台 $CURRENT_PLATFORM, tag $CURRENT_TAG"
echo "镜像前缀: $IMAGE_NAMESPACE/frps、$IMAGE_NAMESPACE/frpc"
echo ""

build_one() {
  local role="$1"   # frps 或 frpc
  local dockerfile="dockerfiles/Dockerfile-for-frps"
  local image_name="$IMAGE_NAMESPACE/frps"
  if [[ "$role" == "frpc" ]]; then
    dockerfile="dockerfiles/Dockerfile-for-frpc"
    image_name="$IMAGE_NAMESPACE/frpc"
  fi

  # 非当前平台：仅 push
  if [[ "$CURRENT_PLATFORM" != "linux/amd64" ]]; then
    echo "[$role] 构建并推送 linux/amd64 -> $image_name:latest-amd64"
    (cd "$REPO_ROOT" && docker buildx build --platform linux/amd64 \
      -f "$dockerfile" -t "$image_name:latest-amd64" --push .)
  fi
  if [[ "$CURRENT_PLATFORM" != "linux/arm64" ]]; then
    echo "[$role] 构建并推送 linux/arm64 -> $image_name:latest-arm64"
    (cd "$REPO_ROOT" && docker buildx build --platform linux/arm64 \
      -f "$dockerfile" -t "$image_name:latest-arm64" --push .)
  fi

  # 当前平台：load + push
  echo "[$role] 构建并 load+push $CURRENT_PLATFORM -> $image_name:$CURRENT_TAG"
  (cd "$REPO_ROOT" && docker buildx build --platform "$CURRENT_PLATFORM" \
    -f "$dockerfile" -t "$image_name:$CURRENT_TAG" --load .)
  docker push "$image_name:$CURRENT_TAG"
}

build_one frps
build_one frpc
echo ""
echo "完成。安装时脚本会根据系统架构自动使用 $IMAGE_NAMESPACE/frps:$CURRENT_TAG 或对应架构 tag。"