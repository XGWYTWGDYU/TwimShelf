# TwimShelf Linux 服务器（Docker）

虽然没谁的Nas有一块Nvidia GPU，但还是做了这个项目

## 目录和端口

| 容器内 | 内容 |
| --- | --- |
| `/app` | 程序本体，随镜像更新 |
| `/data` | 全部数据：`library`（资料库和媒体）、`cache`（缩略图、视频封面、字体）、`models`、`exports`（备份和导出）、`uploads`（导入时上传的文件）、`app`（密钥、登录密码、设置） |
| `2778` | 高雅端口 |

如果你用过docker，应该知道端口和数据目录都可以自由映射，例如 `-p 8080:2778 -v /srv/twimshelf:/data`。

## 安装


```bash
docker run -d --name twimshelf --restart unless-stopped \
  -p 2778:2778 -v /srv/twimshelf:/data \
  -e PUID=$(id -u) -e PGID=$(id -g) \
  ghcr.io/xgwytwgdyu/twimshelf:latest
```

或者用 [`compose.yaml`](compose.yaml)（默认使用 host 网络，局域网同步需要它）：

```bash
docker compose -f docker/compose.yaml up -d
```

在浏览器访问 `http://<服务器地址>:2778`。

也可以从源码构建，版本号取自 `config.yaml`，镜像打包后放在构建目录的 `apps` 里：

```bash
./build.sh docker
```

## 登录

第一次启动会生成一个随机密码，打印在容器日志里，同时保存在 `/data/app/initial-password.txt`：

```bash
docker logs twimshelf
```

改成自己的密码（需要至少 8 位）：

```bash
docker exec -it twimshelf twimshelf passwd
```

- `twimshelf passwd --random` 生成新的随机密码。
- 修改密码后所有已有会话需要重新登录，`initial-password.txt` 也会被删除。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PUID`、`PGID` | `1000` | 以这个用户运行，并把 `/data` 交给它。也可以用 compose 的 `user:` |
| `TL_PASSWORD` | 无 | 设置后就用它作为登录密码，每次启动都以它为准 |
| `TL_ALLOW_PUBLIC` | `false` | 默认只接受局域网访问（包括 Tailscale 的 100.64.0.0/10）；设为 `true` 接受公网。警告，这很危险 |
| `TL_DEVICE_NAME` | `TwimShelf Linux Server` | 局域网同步和浏览器扩展里显示的名字 |
| `TL_PORT` | `2778` | 容器内的端口 |
| `TL_DATA`、`TL_WEB` | `/data`、`/app/web` |  |

## 功能

和electron app完全相同。


## 浏览器扩展

在网页「设置 → 浏览器扩展 → 绑定浏览器」里复制绑定文本，粘贴到扩展里即可，详见 [extension/README.md](../extension/README.md)。

## 局域网同步

同步靠 mDNS 发现设备，组播只有在 host 网络（`network_mode: host` 或 `--network host`）下才能到达容器。用 `-p` 映射端口时网页版一切正常，只是发现不了局域网里的其他设备。

同步端口由核心自动选择。如果开了防火墙，请放行容器的 TCP 连接和 UDP 5353（mDNS）。

## 多人同时访问

可以在多个浏览器、多台设备上同时打开。核心对数据库的操作是串行的，不会损坏数据。

## 公网访问

默认拒绝来自公网地址的请求，也会检查反向代理传来的 `X-Forwarded-For` 等请求头。需要从公网访问时：

1. 设置 `TL_ALLOW_PUBLIC=true`。
2. 放在 HTTPS 反向代理之后，例如 Caddy、Nginx 或 Cloudflare Tunnel。
3. 用 `twimshelf passwd` 换成自己的强密码。

警告：不能保证程序不会成为网络攻击的入口

## 更新

镜像是程序，容器是运行中的程序，`/data` 是数据。用新镜像重建容器，映射相同的`/data` 即可。资料库格式的升级在启动时自动完成。

```bash
docker compose -f docker/compose.yaml pull
```

```bash
docker compose -f docker/compose.yaml up -d
```

用 `docker run` 安装的：先 `docker pull ghcr.io/xgwytwgdyu/twimshelf:latest`，再 `docker rm -f twimshelf`，最后用原来的 `-p`、`-v`、`-e` 参数重新 `docker run`。

## GPU

考虑到功耗原因，本地模型只在 GPU 上运行，不会fallback到CPU，你需要映射一个可用的来自NV，AMD和Intel的GPU

**AMD 和 Intel**：映射 `/dev/dri`。镜像里是 Mesa 的 Vulkan 驱动，支持近几年的显卡和核显。

```bash
docker run -d --name twimshelf --device /dev/dri -p 2778:2778 -v /path/to/data:/data ghcr.io/xgwytwgdyu/twimshelf:latest
```

compose 里取消 `devices:` 那两行的注释。容器以 `PUID` 的身份运行时，会自动加入 `/dev/dri` 设备所属的用户组（render、video），不用另外设置权限。

**NVIDIA**：确保你安装了 NVIDIA 驱动 [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)，再加上 `--gpus all`。镜像自带 CUDA 运行库，这也是它为什么这么大。面向 RTX 20 系及以后的显卡。

```bash
docker run -d --name twimshelf --gpus all -p 2778:2778 -v /path/to/data:/data ghcr.io/xgwytwgdyu/twimshelf:latest
```

compose 里取消 `deploy:` 那一段的注释。

**多个 GPU**（或者一块 NVIDIA 显卡，它同时以 CUDA 和 Vulkan 两个设备出现）：程序使用真实任务在不同GPU上进行测试，选择最快的GPU。GPU 有增减时，下一次标记会重新比较。日志相关记录： `local ai: CUDA0 (…) 412 ms` 


对于没有GPU的设备，使用外部模型是更好选择
