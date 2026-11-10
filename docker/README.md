# TwimShelf Linux 服务器（Docker）

一个容器里是 Rust 核心（与各平台 App 相同）和 Flutter 网页版，只占一个端口。放在一台常开的 Linux 机器上，就是一台随时在线的 TwimShelf：用浏览器访问，和其他设备局域网同步，接收浏览器扩展发来的下载。

## 目录和端口

| 容器内 | 内容 |
| --- | --- |
| `/app` | 程序本体（服务器、网页版），随镜像更新 |
| `/data` | 全部数据：`library`（资料库和媒体）、`cache`（缩略图、视频封面、字体）、`models`、`exports`（备份和导出）、`uploads`（导入时上传的文件）、`app`（密钥、登录密码、设置） |
| `2778` | 网页版和接口 |

端口和数据目录都可以自由映射，例如 `-p 8080:2778 -v /srv/twimshelf:/data`。

## 安装

发布的镜像同时支持 x86_64 和 arm64：

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

然后用浏览器打开 `http://<服务器地址>:2778`。

也可以从源码构建，版本号取自 `config.yaml`，镜像打包后放在构建目录的 `apps` 里：

```bash
./build.sh docker
```

## 登录

第一次启动会生成一个随机密码，打印在容器日志里，同时保存在 `/data/app/initial-password.txt`：

```bash
docker logs twimshelf
```

改成自己的密码（至少 8 位）：

```bash
docker exec -it twimshelf twimshelf passwd
```

- `twimshelf passwd --random` 生成新的随机密码，`--stdin` 从标准输入读取，适合脚本。
- 改密码后所有已登录的浏览器都要重新登录，`initial-password.txt` 会被删除。
- 网页「设置 → 退出登录」只让当前浏览器退出。
- 同一个地址连续输错 5 次后要等待，从 30 秒开始，每次加倍，最长 1 小时。
- 程序只有一个用户，没有账户系统。

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PUID`、`PGID` | `1000` | 以这个用户运行，并把 `/data` 交给它（只改还不属于它的文件）。也可以用 compose 的 `user:` |
| `TL_PASSWORD` | 无 | 设置后就用它作为登录密码，每次启动都以它为准 |
| `TL_ALLOW_PUBLIC` | `false` | 默认只接受局域网访问（包括 Tailscale 的 100.64.0.0/10）；设为 `true` 才接受公网 |
| `TL_DEVICE_NAME` | `TwimShelf Linux Server` | 局域网同步和浏览器扩展里显示的名字 |
| `TL_PORT` | `2778` | 容器内的端口 |
| `TL_DATA`、`TL_WEB` | `/data`、`/app/web` | 一般不需要改 |

## 功能

和 App 是同一个资料库：浏览、搜索（标签、正文、用户、文件夹；命中帖子里任意一张就显示整帖）、照片和视频网格、查看器、视频播放（可以拖动进度）、HEIC 和 AVIF、文件夹、标签、待审核和已审核、最近删除、下载帖子（链接、批量、Cookie）、导入（旧格式 ZIP、散图 ZIP、`.tlpack`，从浏览器上传）、整库备份和导出（浏览器下载）、存储管理、完整性检查、外部 AI 模型自动打标签（OpenAI 兼容接口，由服务器代发请求）、局域网同步（创建账户、用配对码加入，关掉浏览器后服务器照常同步）。

和 App 的不同：

- 照片网格只有几档固定的缩放，没有 App 里连续的捏合缩放。
- 本地 AI 模型只在 App 里运行，网页版使用外部模型。
- 宠物、应用锁、系统分享菜单、快捷操作这类设备功能没有。
- 视频封面由容器里的 ffmpeg 生成。

## 浏览器扩展

服务器一直在接收下载，不需要打开网页。在网页「设置 → 浏览器扩展 → 绑定浏览器」里复制绑定文本，粘贴到扩展里即可，详见 [extension/README.md](../extension/README.md)。

## 局域网同步

同步靠 mDNS 发现设备，组播只有在 host 网络（`network_mode: host` 或 `--network host`）下才能到达容器。用 `-p` 映射端口时网页版一切正常，只是发现不了局域网里的其他设备。macOS 上的 Docker Desktop 和 OrbStack 没有真正的 host 网络，同步请在 Linux 上使用。

同步端口由核心自动选择。如果开了防火墙，请放行容器的 TCP 连接和 UDP 5353（mDNS）。

## 多人同时访问

可以在多个浏览器、多台设备上同时打开。核心对数据库的操作是串行的，不会损坏数据；别处的修改大约 1 秒后自动刷新。网页版自己的后台工作（AI 自动打标签）同一时间只在一个窗口里运行，那个窗口关掉后，一分钟内由其他窗口接手。下载队列在每次操作前重新读取，不会互相覆盖。

## 公网访问

默认拒绝来自公网地址的请求，也会检查反向代理传来的 `X-Forwarded-For` 等请求头。需要从公网访问时：

1. 设置 `TL_ALLOW_PUBLIC=true`。
2. 放在 HTTPS 反向代理之后，例如 Caddy、Nginx 或 Cloudflare Tunnel。
3. 用 `twimshelf passwd` 换成自己的强密码。

## 不连外网的局域网

界面需要的一切（CanvasKit、Roboto、图标）都在镜像里。中文、日文、emoji 等字体在第一次用到时由服务器从 Google Fonts 取回，保存在 `/data/cache/fonts`，之后局域网里的浏览器不再需要外网。

## 更新

镜像是程序，容器是运行中的程序，`/data` 是数据。更新就是换上新镜像、重建容器，数据目录不动，资料库格式的升级在启动时自动完成。

```bash
docker compose -f docker/compose.yaml pull
```

```bash
docker compose -f docker/compose.yaml up -d
```

用 `docker run` 安装的：先 `docker pull ghcr.io/xgwytwgdyu/twimshelf:latest`，再 `docker rm -f twimshelf`，最后用原来的 `-p`、`-v`、`-e` 参数重新 `docker run`。

## GPU

Docker 可以直通 GPU：NVIDIA 安装 nvidia-container-toolkit 后加 `--gpus all`，Intel 和 AMD 映射 `/dev/dri`。不过这个镜像本身不使用 GPU，因为网页版的 AI 打标签用的是外部模型。想用这台机器的 GPU，推荐另外运行一个带 GPU 的 Ollama 容器，再在「设置 → 打标签 → 添加外部模型」里填 `http://<服务器地址>:11434`。

## 备份

停掉容器后复制整个数据目录即可。也可以在网页「设置 → 导入与备份」里做整库 `.tlpack` 备份，任何设备上的 App 都能导入。
