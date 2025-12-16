## 本教程：在 LXC 受限内核的服务器环境下运行“原生”容器（示例以 Debian 13 为准）

### 思路
LXC 受限内核的服务器无法运行原生 Docker 的常见原因包括：  
- 母宿主机没有开启嵌套（nested virtualization / allowed cgroup nesting）；  
- cgroups 版本或 cgroup 驱动不符合容器运行要求（例如只有 cgroup v1 而期望 v2）。  

可以尝试使用不强制依赖这些特性的方案（例如 Podman + fuse-overlayfs），或将 `cgroup_manager` 改成 `systemd`（视环境可行性）。

---

## 在 Euserv IPv6-only 服务器上的验证（依次执行命令，需要 root 权限或 sudo）

下面命令示例均按顺序给出；请在接受风险（覆盖 `/etc`、以及 `podman system reset -f` 会清空数据）的前提下执行。

### 1) 更新系统并安装需要的软件包
```bash
sudo apt update && sudo apt -y upgrade && sudo apt -y install dnf podman podman-docker docker-compose
# 更新包索引、升级系统并安装 dnf、podman、podman-docker 与 docker-compose（使用 sudo 以适配非 root 情形）
```

---

### 2) 创建 /etc/containers 并从包内模板复制配置（会覆盖 /etc 下同名文件）
```bash
sudo mkdir -p /etc/containers
# 确保 /etc/containers 目录存在

sudo cp -a /usr/share/containers/containers.conf /etc/containers/containers.conf
# 从系统包模板复制 containers.conf 到 /etc（会覆盖同名文件）

sudo cp -a /usr/share/containers/storage.conf /etc/containers/storage.conf
# 从系统包模板复制 storage.conf 到 /etc（会覆盖同名文件）
```

---

### 3) 在 containers、storage、registries 三个配置文件中取消注释并设置指定值（按顺序执行并打印结果以便核验）
```bash
sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*cgroup_manager[[:space:]]*=.*|cgroup_manager = "systemd"|' /etc/containers/containers.conf
# 在 /etc/containers/containers.conf 中启用 cgroup_manager = "systemd"（取消注释并替换整行）

sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*keyring[[:space:]]*=.*|keyring = false|' /etc/containers/storage.conf
# 在 /etc/containers/storage.conf 中取消注释 keyring 并将其设为 false

sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*mount_program[[:space:]]*=.*|mount_program = "/usr/bin/fuse-overlayfs"|' /etc/containers/storage.conf
# 在 /etc/containers/storage.conf 中取消注释 mount_program 并设为 "/usr/bin/fuse-overlayfs"

sudo sed -i 's|^[[:space:]]*#\?[[:space:]]*unqualified-search-registries[[:space:]]*=.*|unqualified-search-registries = ["docker.io"]|' /etc/containers/registries.conf
# 在 /etc/containers/registries.conf 中取消注释 unqualified-search-registries 并把 example.com 改为 docker.io

sudo grep -nE 'cgroup_manager|keyring|mount_program|unqualified-search-registries' /etc/containers/containers.conf /etc/containers/storage.conf /etc/containers/registries.conf
# 打印三处配置以便快速核验已修改的行
```

> 说明：  
> - 我把 `cgroup_manager` 写到 `containers.conf`（这是官方惯例且更有可能被 Podman 读取），而 `keyring` 与 `mount_program` 写入 `storage.conf`。  
> - `sed` 使用 POSIX `[[:space:]]`，兼容 GNU sed 与 BusyBox sed。  
> - 若某模板中**根本不存在**相应行（极少见），上面的 `sed` 不会新增该行；但把 `/usr/share` 的模板复制到 `/etc` 后，模板通常包含这些条目，故 `sed` 能命中。

---

### 4) （可选且破坏性）重置 Podman 状态 — **危险，慎用**
```bash
sudo podman system reset -f
# 警告：此操作会删除 Podman 的容器、镜像、卷、网络等。仅在你确认可以接受清空数据时执行。
```

---

### 5) 下载并安装 docker-compose 二进制（请先确认版本号存在）
```bash
ver="PUT_DESIRED_VERSION_HERE"   # 例如 "v2.20.2"；请先确认 release 页面存在该版本
# 设置要下载的 docker-compose 版本字符串（请根据实际 release 填写）

curl -L -o docker-compose-linux-x86_64 "https://github.com/docker/compose/releases/download/${ver}/docker-compose-linux-x86_64"
# 下载指定版本的 docker-compose 二进制到当前目录

sudo chmod +x docker-compose-linux-x86_64
# 赋予可执行权限

sudo mv docker-compose-linux-x86_64 /usr/local/bin/docker-compose
# 移动到 /usr/local/bin 并命名为 docker-compose（放在 PATH 中）

docker-compose -v
# 显示 docker-compose 版本，检验安装是否成功
```

---

### 6) 创建 docker 组并建立用户（容错处理：若组或用户已存在则尽量不报错）
```bash
sudo groupadd -f docker
# 创建 docker 组；已存在则不报错

sudo useradd -m -u 1000 docker_usr || true
# 创建 uid=1000 的用户 docker_usr 并创建家目录；若用户已存在则忽略错误

sudo usermod -aG docker,sudo,podman docker_usr
# 把 docker_usr 加入 docker、sudo 与 podman 组（追加，不移除已有组）
```

---

### 7) 启用 podman socket（system 与 user 两种方式，user 需在登录会话中执行）
```bash
sudo systemctl enable --now podman.socket
# 启用 system-wide 的 podman.socket 并立即启动

systemctl --user enable --now podman.socket || true
# 尝试启用当前用户的 podman.socket（若非登录会话，此命令可能失败，故加 || true）
```

---

### 8) 设置 DOCKER_HOST 环境变量（写入用户 shell 配置并立即加载）
```bash
touch ~/.bash_profile
# 确保 ~/.bash_profile 存在

echo 'export DOCKER_HOST=unix:///run/user/1000/docker.sock' >> ~/.bash_profile
# 追加 DOCKER_HOST 到用户的 ~/.bash_profile

source ~/.bash_profile
# 立即在当前 shell 中载入（若你在脚本或 sudo 下执行，这一步可能以不同用户身份运行，请按需手动执行）
```

---

### 9) 建立 socket 符号链接，使依赖 /var/run/docker.sock 的客户端能访问到 podman socket
```bash
sudo ln -sf /run/user/1000/podman/podman.sock /var/run/docker.sock
# 将 podman socket 链接为 /var/run/docker.sock（覆盖式）

sudo ln -sf /run/user/1000/podman/podman.sock /run/user/0/docker.sock
# 为 root 用户创建链接（覆盖式）

ln -sf /run/user/1000/podman/podman.sock /run/user/1000/docker.sock
# 为普通用户会话创建链接（无需 sudo，当以同一用户执行时）
```

---

### 10) （非标准 hack）将 podman 的 systemd unit 作为 docker.service 的替代（**谨慎**）
```bash
sudo cp /lib/systemd/system/podman.service /etc/systemd/system/docker.service
# 将 podman.service 复制并命名为 docker.service（放到 /etc 以便覆盖系统 unit），此为 hack 手法

sudo cp /lib/systemd/system/podman.socket /etc/systemd/system/docker.socket
# 同上，把 podman.socket 复制为 docker.socket

sudo systemctl daemon-reload
# 重新加载 systemd 配置，使上面复制的 unit 生效

sudo systemctl enable --now docker.service
# 启用并立即启动 docker.service（实际上是 podman 的 unit）；可能与系统预期或面板冲突，慎用
```

---

### 11) 检查服务状态与版本
```bash
systemctl status docker.service
# 查看 docker.service（被替换为 podman unit）的运行状态

sudo docker -v
# 检查 docker 客户端版本（若有）

sudo docker-compose -v
# 检查 docker-compose 版本

sudo podman -v
# 检查 podman 版本
```

---

## 重要注意事项（请务必阅读）
1. **覆盖 `/etc/containers`**：上文中 `cp -a /usr/share/containers/* /etc/containers/` 会覆盖 `/etc` 下的同名文件，任何先前自定义配置将丢失。请确认你接受覆盖行为。  
2. **podman reset 的破坏性**：`podman system reset -f` 会删除容器、镜像、卷等数据。若需要保留数据请不要执行 reset，或先导出备份。  
3. **配置生效顺序（优先级）**：rootless Podman 会优先使用 `~/.config/containers/*.conf`，这些会覆盖 `/etc` 配置。若你以非 root（rootless）方式运行 Podman，请同时检查并修改用户目录下的配置文件。  
4. **cgroup_manager 的正确位置**：`cgroup_manager` 通常应在 `containers.conf` 中设置。若只在 `storage.conf` 修改，Podman 可能不会读取该项，因此本修订把其写到 `containers.conf` 以确保生效。  
5. **sed 兼容性**：我使用了 POSIX 的 `[[:space:]]`，以兼容常见的 sed 实现（包括 BusyBox sed）。  
6. **systemd unit hack 风险**：把 podman 的 systemd unit 拷贝并命名为 docker.service 是变通做法，可能与面板或其他软件期望的 docker 行为不完全一致（尤其是 socket 名、环境变量、PID、启动参数等）。如果你使用面板（如 1Panel），推荐先在测试环境验证。  

---
