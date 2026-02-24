# 镜像构建与安装（多平台 latest tag）

镜像使用 **latest** 系列 tag，按架构区分：`latest-amd64`、`latest-arm64`（无版本号）。  
构建时自动判断当前系统为 arm 或 amd64：**当前平台** 会 load 到本机并 push；**其它平台** 仅 push。

## 构建（多平台 + 当前 load+push）

在项目根目录或 `docker` 目录下执行，需已登录 registry（`docker login`）：

```shell
./docker/build.sh
```

- 会构建并推送 `yuyu8868/frps:latest-amd64`、`yuyu8868/frps:latest-arm64`，以及同 tag 的 `frpc`。
- 当前系统对应平台会执行 **load + push**，另一平台只 **push**。
- 自定义镜像前缀可设置：`IMAGE_NAMESPACE=你的仓库 ./docker/build.sh`

## 安装（自动按架构选 tag）

`docker/install.sh` 会根据当前系统自动选择 tag，仅拉取对应镜像，无需环境变量与本地打包：

- **x86_64** → 使用 `yuyu8868/frps:latest-amd64`、`yuyu8868/frpc:latest-amd64`
- **arm64 / aarch64** → 使用 `yuyu8868/frps:latest-arm64`、`yuyu8868/frpc:latest-arm64`

```shell
./docker/install.sh
```

## docker-compose

`docker-compose.yml` 通过环境变量选择镜像 tag，默认 `latest-amd64`。在 ARM 机器上请先：

```shell
export FRP_IMAGE_TAG=latest-arm64
docker compose -f docker/docker-compose.yml up -d
```
