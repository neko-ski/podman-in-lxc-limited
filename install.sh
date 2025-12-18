#!/bin/bash

# Podman in LXC limited environment 一键安装脚本
# 基于 https://github.com/neko-ski/podman-in-lxc-limited README
# 注意：需要 root/sudo 权限，大部分操作会覆盖配置，请备份！
# 可选：docker-compose 版本（改成你想要的，默认固定为 v5.0.0；可通过环境变量覆盖）
# 如需其它版本可在运行时通过环境变量覆盖，例如：
#   COMPOSE_VER=v5.0.0 sudo bash podman-in-lxc-limited.sh
COMPOSE_VER="${COMPOSE_VER:-v5.0.0}"
# 当自动检测失败时回退到该版本（可按需修改）
COMPOSE_FALLBACK="v5.0.0"

set -euo pipefail  # 出错退出并开启严格模式
IFS=$'\n\t'
# 在发生错误时打印行号与命令，便于调试（根据语言显示）
show_error() {
    if [ "${LANG_CHOICE:-}" = "2" ]; then
        echo "错误：脚本在第 $LINENO 行出错，命令：$BASH_COMMAND" >&2
    else
        echo "Error: script failed at line $LINENO, command: $BASH_COMMAND" >&2
    fi
}
trap 'show_error' ERR

# 语言选择：选择 English 或 中文
echo "Select language / 选择语言:"
echo "1) English"
echo "2) 中文"
read -rp "Choice [1/2]: " LANG_CHOICE
# Trim CR/LF and surrounding whitespace to tolerate Windows CRLF line endings or extra spaces
LANG_CHOICE="$(printf '%s' "${LANG_CHOICE:-}" | tr -d '\r' | tr -d '[:space:]')"
if [ "$LANG_CHOICE" != "1" ] && [ "$LANG_CHOICE" != "2" ]; then
    echo "Invalid choice, defaulting to English / 无效选择，默认 English"
    LANG_CHOICE=1
fi

# say 函数：根据语言打印消息，参数1=English, 参数2=中文
say() {
    if [ "${LANG_CHOICE}" = "2" ]; then
        printf '%b\n' "$2"
    else
        printf '%b\n' "$1"
    fi
} 

say "1. Update system and install required packages..." "1. 更新系统并安装必要包..."
sudo apt update && sudo apt -y upgrade
sudo apt -y install dnf curl git podman podman-docker docker-compose fuse-overlayfs  # fuse-overlayfs 是关键依赖
say "2. Create /etc/containers and copy default configs..." "2. 创建 /etc/containers 并复制默认配置..."
sudo mkdir -p /etc/containers /etc/containers/registries.conf.d

sudo cp -a /usr/share/containers/containers.conf /etc/containers/containers.conf 2>/dev/null || true
sudo cp -a /usr/share/containers/storage.conf /etc/containers/storage.conf 2>/dev/null || true

# 处理 registries.conf
if [ -f /usr/share/containers/registries.conf ]; then
    sudo cp -a /usr/share/containers/registries.conf /etc/containers/
elif [ -d /usr/share/containers/registries.conf.d ]; then
    sudo cp -a /usr/share/containers/registries.conf.d/* /etc/containers/registries.conf.d/
else
    sudo tee /etc/containers/registries.conf > /dev/null <<EOF
unqualified-search-registries = ["docker.io"]
EOF
fi

say "3. Modify configuration files (use POSIX sed for BusyBox compatibility)..." "3. 修改配置文件（使用 POSIX sed，兼容 BusyBox）..."
# 在 containers.conf 中启用 cgroup_manager = "systemd"
sudo sed -i.bak 's|^[[:space:]]*#\?[[:space:]]*cgroup_manager[[:space:]]*=.*|cgroup_manager = "systemd"|' /etc/containers/containers.conf

# 在 storage.conf 中设置 keyring = false 与 mount_program = "/usr/bin/fuse-overlayfs"
# 明确将 '#keyring = true'、'keyring = true' 或其他 keyring 行替换为 'keyring = false'；若不存在则追加该行
if grep -qi '^[[:space:]]*#\?[[:space:]]*keyring[[:space:]]*=' /etc/containers/storage.conf 2>/dev/null; then
    sudo sed -i.bak -E 's|^[[:space:]]*#?[[:space:]]*keyring[[:space:]]*=.*|keyring = false|' /etc/containers/storage.conf
else
    echo 'keyring = false' | sudo tee -a /etc/containers/storage.conf >/dev/null
fi
sudo sed -i.bak 's|^[[:space:]]*#\?[[:space:]]*mount_program[[:space:]]*=.*|mount_program = "/usr/bin/fuse-overlayfs"|' /etc/containers/storage.conf

# 在 registries.conf 中启用 unqualified-search-registries = ["docker.io"]（若文件存在）
if [ -f /etc/containers/registries.conf ]; then
    sudo sed -i.bak 's|^[[:space:]]*#\?[[:space:]]*unqualified-search-registries[[:space:]]*=.*|unqualified-search-registries = ["docker.io"]|' /etc/containers/registries.conf || true
fi

# 打印核验信息
sudo grep -nE 'cgroup_manager|keyring|mount_program|unqualified-search-registries' /etc/containers/containers.conf /etc/containers/storage.conf /etc/containers/registries.conf || true


say "4. Check for existing Podman data (containers/images/volumes)..." "4. 检查是否存在已有 Podman 数据（容器/镜像/卷）..."
if command -v podman >/dev/null 2>&1; then
    containers_count=$(sudo podman ps -a -q | wc -l)
    images_count=$(sudo podman images -q | wc -l)
    volumes_count=0
    if sudo podman volume ls >/dev/null 2>&1; then
        volumes_count=$(sudo podman volume ls -q | wc -l)
    fi
else
    containers_count=0
    images_count=0
fi

if [ "$containers_count" -eq 0 ] && [ "$images_count" -eq 0 ] && [ "$volumes_count" -eq 0 ]; then
    say "No existing Podman containers/images/volumes detected; skipping reset step." "未检测到现有 Podman 容器/镜像/卷，跳过 reset 步骤。"
else
    say "Detected existing Podman data: containers=$containers_count images=$images_count volumes=$volumes_count" "检测到存在 Podman 数据：容器=$containers_count 镜像=$images_count 卷=$volumes_count"
    say "Perform podman system reset (will delete containers/images/volumes/networks)? (y/N)" "是否执行 podman system reset（会删除容器/镜像/卷/网络等）？(y/N)"
    read -r reset_choice
    if [[ "$reset_choice" =~ ^[Yy]$ ]]; then
        sudo podman system reset -f
        say "Podman has been reset." "Podman 已重置。"
    else
        say "Skipping reset." "跳过 reset。"
    fi
fi

say "5. Install specified docker-compose version (v2 binary; v1 via apt)..." "5. 安装指定版本 docker-compose (v2 二进制，v1 由 apt 提供)..."
# 若 COMPOSE_VER 设置为 auto（默认），则尝试通过 GitHub API 获取最新 release 的 tag_name，若失败则使用多种回退方式
if [ "${COMPOSE_VER}" = "auto" ] || [ -z "${COMPOSE_VER}" ]; then
    say "Detecting latest docker-compose version..." "检测 docker-compose 最新版本..."

    latest_tag=""
    # 优先使用 GitHub API（如果网络允许）
    response=$(curl -fsS --connect-timeout 10 --max-time 30 "https://api.github.com/repos/docker/compose/releases/latest" 2>/dev/null || true)
    latest_tag=$(printf '%s' "$response" | grep -m1 '"tag_name":' | sed -E 's/.*"([^\"]+)".*/\1/' || true)

    # 如果 API 不可用，尝试通过 releases/latest 的重定向获取 tag
    if [ -z "${latest_tag}" ]; then
        redirect_url=$(curl -fsS -I -L "https://github.com/docker/compose/releases/latest" 2>/dev/null | grep -i '^location:' | tail -n1 | awk '{print $2}' | tr -d '\r' || true)
        if [ -n "${redirect_url}" ]; then
            latest_tag=$(basename "${redirect_url}")
        else
            # 最后手段：直接抓取 HTML 并尝试解析 tag 字样
            html=$(curl -fsS "https://github.com/docker/compose/releases/latest" 2>/dev/null || true)
            latest_tag=$(printf '%s' "$html" | grep -m1 -oE 'tag/[vV]?[0-9]+\.[0-9]+\.[0-9A-Za-z\.-]+' | sed 's|.*/||' || true)
        fi
    fi

    if [ -n "${latest_tag}" ]; then
        COMPOSE_VER="${latest_tag}"
        say "Found latest version: ${COMPOSE_VER}" "获取到最新版本: ${COMPOSE_VER}"
    else
        say "Warning: cannot fetch latest version from GitHub; falling back to ${COMPOSE_FALLBACK}" "警告：无法从 GitHub 获取最新版本，回退到 ${COMPOSE_FALLBACK}"
        say "Repository: https://github.com/docker/compose" "仓库地址: https://github.com/docker/compose"
        COMPOSE_VER="${COMPOSE_FALLBACK}"
    fi
else
    say "Using specified COMPOSE_VER=${COMPOSE_VER}" "使用指定的 COMPOSE_VER=${COMPOSE_VER}"
fi

# 下载并安装对应版本的二进制（按架构选择资产并验证下载）
ARCH=$(uname -m)
case "${ARCH}" in
    x86_64|amd64) asset="docker-compose-linux-x86_64" ;; 
    aarch64|arm64) asset="docker-compose-linux-aarch64" ;; 
    armv7l) asset="docker-compose-linux-armv7" ;; 
    *) asset="docker-compose-linux-x86_64" ;;
esac

# 如果系统已经存在 docker-compose，可先验证是否有效，若无效则备份/删除
if command -v docker-compose >/dev/null 2>&1; then
    if ! docker-compose -v >/dev/null 2>&1; then
        say "Existing /usr/local/bin/docker-compose appears invalid; backing up and removing" "检测到现有 /usr/local/bin/docker-compose 可能损坏，备份并移除"
        sudo mv /usr/local/bin/docker-compose /usr/local/bin/docker-compose.broken.$(date +%s) 2>/dev/null || sudo rm -f /usr/local/bin/docker-compose || true
    fi
fi

# 可通过环境变量 COMPOSE_DOWNLOAD_BASE 指定备用下载基地址（例如使用镜像站）
# 默认使用官方 releases download 路径
COMPOSE_DOWNLOAD_BASE="${COMPOSE_DOWNLOAD_BASE:-https://github.com/docker/compose/releases/download}"

# 检查是否有常见拼写错误（例如 jsdeliver -> jsdelivr），若发现则自动修正并提示
if printf '%s' "${COMPOSE_DOWNLOAD_BASE}" | grep -qi 'jsdeliver'; then
    say "Warning: COMPOSE_DOWNLOAD_BASE appears to contain 'jsdeliver' which is likely a typo; auto-correcting to 'cdn.jsdelivr.net'" "警告：COMPOSE_DOWNLOAD_BASE 看起来包含 'jsdeliver'，可能是拼写错误；已自动修正为 'cdn.jsdelivr.net'"
    COMPOSE_DOWNLOAD_BASE=$(printf '%s' "${COMPOSE_DOWNLOAD_BASE}" | sed -E 's/jsdeliver/cdn.jsdelivr.net/Ig')
fi

# 构建候选下载 URL 列表：固定为 v5.0.0 的 GitHub releases 与 jsDelivr 加速版本（x86_64 与 aarch64）
asset_x86="docker-compose-linux-x86_64"
asset_arm="docker-compose-linux-aarch64"
# 优先顺序：先尝试与当前主机架构匹配的两个链接（GitHub -> jsDelivr），然后再尝试另一架构的两个链接
candidates=()
if [ "${asset}" = "${asset_arm}" ] || [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
    # 当前为 aarch64，先尝试 aarch64，再尝试 x86_64
    candidates+=("https://github.com/docker/compose/releases/download/${COMPOSE_VER}/${asset_arm}")
    candidates+=("https://cdn.jsdelivr.net/gh/docker/compose/releases/download/${COMPOSE_VER}/${asset_arm}")
    candidates+=("https://github.com/docker/compose/releases/download/${COMPOSE_VER}/${asset_x86}")
    candidates+=("https://cdn.jsdelivr.net/gh/docker/compose/releases/download/${COMPOSE_VER}/${asset_x86}")
else
    # 默认或 x86_64，先尝试 x86_64，再尝试 aarch64
    candidates+=("https://github.com/docker/compose/releases/download/${COMPOSE_VER}/${asset_x86}")
    candidates+=("https://cdn.jsdelivr.net/gh/docker/compose/releases/download/${COMPOSE_VER}/${asset_x86}")
    candidates+=("https://github.com/docker/compose/releases/download/${COMPOSE_VER}/${asset_arm}")
    candidates+=("https://cdn.jsdelivr.net/gh/docker/compose/releases/download/${COMPOSE_VER}/${asset_arm}")
fi

# IPv4/IPv6 可达性检测：确定优先使用哪种协议（若仅一方可达则优先使用）
ipv6_ok=0; ipv4_ok=0
if curl -fsS --connect-timeout 5 --max-time 10 --ipv6 https://api.github.com/ >/dev/null 2>&1; then ipv6_ok=1; fi
if curl -fsS --connect-timeout 5 --max-time 10 --ipv4 https://api.github.com/ >/dev/null 2>&1; then ipv4_ok=1; fi
PREFERRED_CURL_OPTS=""
if [ "$ipv6_ok" -eq 1 ] && [ "$ipv4_ok" -eq 0 ]; then
    PREFERRED_CURL_OPTS="--ipv6"
    say "Detected IPv6-only connectivity; preferring curl --ipv6 for GitHub requests" "检测到仅 IPv6 可达，将优先使用 curl --ipv6 访问 GitHub"
elif [ "$ipv4_ok" -eq 1 ] && [ "$ipv6_ok" -eq 0 ]; then
    PREFERRED_CURL_OPTS="--ipv4"
    say "Detected IPv4-only connectivity; preferring curl --ipv4 for GitHub requests" "检测到仅 IPv4 可达，将优先使用 curl --ipv4 访问 GitHub"
else
    PREFERRED_CURL_OPTS=""
fi

# 尝试下载（对每个 URL 先尝试偏好协议，再系统默认，再显式 --ipv6/--ipv4）
tmpfile=$(mktemp)
success=0
for url in "${candidates[@]}"; do
    say "Attempting download from: ${url}" "尝试从 ${url} 下载"
    for opt in "${PREFERRED_CURL_OPTS}" "" "--ipv6" "--ipv4"; do
        if [ -z "${opt}" ]; then
            say "  Trying curl (default IP stack) -> ${url}" "  使用系统默认 IP 访问 -> ${url}"
        else
            say "  Trying curl ${opt} -> ${url}" "  使用 curl ${opt} 访问 -> ${url}"
        fi
        if curl -fSL --retry 3 --retry-connrefused --retry-delay 2 --connect-timeout 10 ${opt} -o "${tmpfile}" "${url}"; then
            size=$(wc -c < "${tmpfile}" 2>/dev/null || echo 0)
            if [ "${size}" -lt 20000 ]; then
                say "  Downloaded file small (${size} bytes), likely an error page; trying next candidate" "  下载文件很小 (${size} 字节)，可能是错误页；尝试下一个候选"
                rm -f "${tmpfile}"
                break
            fi
            if head -c 4 "${tmpfile}" | od -An -t x1 | grep -q '7f 45 4c 46'; then
                success=1
                break 2
            else
                say "  Downloaded file doesn't look like ELF; trying next candidate" "  下载文件看起来不是 ELF；尝试下一个候选"
                rm -f "${tmpfile}"
                break
            fi
        else
            say "  curl ${opt:-(default)} failed for ${url}" "  curl ${opt:-(默认)} 访问 ${url} 失败"
        fi
    done
done

if [ "${success}" -eq 1 ]; then
    sudo chmod +x "${tmpfile}"
    sudo mv "${tmpfile}" /usr/local/bin/docker-compose
    if docker-compose -v >/dev/null 2>&1; then
        say "Installed docker-compose ${COMPOSE_VER} at /usr/local/bin/docker-compose" "已安装 docker-compose ${COMPOSE_VER} 到 /usr/local/bin/docker-compose"
    else
        say "Warning: docker-compose installed but 'docker-compose -v' failed" "警告：docker-compose 已安装但 'docker-compose -v' 失败"
    fi
else
    say "Warning: all download attempts failed for docker-compose ${COMPOSE_VER}; skipping v2 installation." "警告：对 docker-compose ${COMPOSE_VER} 的所有下载尝试均失败，跳过 v2 安装。"
    say "Attempted URLs:" "尝试的 URL 列表："
    for url in "${candidates[@]}"; do
        say "  - ${url}" "  - ${url}"
    done
    say "If you are behind a firewall or your network blocks GitHub, consider setting COMPOSE_DOWNLOAD_BASE to a reachable mirror (only jsDelivr or GitHub are supported) or download manually from: https://github.com/docker/compose/releases" "如果您处于防火墙后或网络屏蔽 GitHub，请考虑将 COMPOSE_DOWNLOAD_BASE 指向可用镜像（仅支持 jsDelivr 或 GitHub），或手动从 https://github.com/docker/compose/releases 下载。"
    rm -f "${tmpfile}" || true
fi

say "6. Create docker group and docker_usr user..." "6. 创建 docker 组和 docker_usr 用户..."
# 确保必要的组存在，避免 usermod 因缺少组而失败
sudo groupadd -f docker
sudo groupadd -f sudo
sudo groupadd -f podman

# 如果用户已存在则跳过创建（保留 uid 1000 仅在创建时使用）
if id -u docker_usr >/dev/null 2>&1; then
    say "User docker_usr already exists, skipping creation." "用户 docker_usr 已存在，跳过创建。"
else
    sudo useradd -m -u 1000 docker_usr
fi

# 仅把存在的组加入用户，组列表用逗号分隔传给 usermod，避免 usermod 报错
groups_to_add=""
sep=""
for g in docker sudo podman; do
    if getent group "$g" >/dev/null 2>&1; then
        groups_to_add="${groups_to_add}${sep}${g}"
        sep="," 
    fi
done
if [ -n "$groups_to_add" ]; then
    sudo usermod -aG "$groups_to_add" docker_usr || true
fi

say "7. Enable linger for docker_usr (keep user systemd running when not logged in)..." "7. 为 docker_usr 启用 linger（无人登录时保持 user systemd 运行）..."
sudo loginctl enable-linger docker_usr

say "8. Enable Podman system socket and enable user socket for docker_usr..." "8. 启用 Podman system socket 并为 docker_usr 启用 user socket..."
sudo systemctl enable --now podman.socket

# 尝试在 docker_usr 的 user systemd 中启用 podman.socket（若没有登录环境或失败则容错）
# 如果 /run/user/1000 存在且 user systemd 可用，则直接启用；否则尝试通过 dbus-run-session 回退；若均不可用则显示警告并跳过。
if [ -d /run/user/1000 ]; then
    if sudo -u docker_usr XDG_RUNTIME_DIR=/run/user/1000 systemctl --user show-environment >/dev/null 2>&1; then
        sudo -u docker_usr XDG_RUNTIME_DIR=/run/user/1000 systemctl --user enable --now podman.socket || true
    elif command -v dbus-run-session >/dev/null 2>&1; then
        # 在没有可用 user bus 的非交互环境中，dbus-run-session 可以临时提供一个会话以运行 systemctl --user
        sudo -u docker_usr dbus-run-session -- sh -c 'systemctl --user enable --now podman.socket' || true
    else
        say "Warning: cannot contact docker_usr user systemd; skipping user unit enable. You can enable it manually after login or install dbus-user-session." "警告：无法连接 docker_usr 的 user systemd，跳过启用用户单元。登录后或安装 dbus-user-session 后可手动启用。"
    fi
else
    say "Warning: /run/user/1000 not found; skipping enabling podman.socket in user mode for docker_usr." "警告：未发现 /run/user/1000；跳过为 docker_usr 启用 podman.socket 用户模式。"
fi

say "9. Set DOCKER_HOST in docker_usr's shell config..." "9. 设置 DOCKER_HOST 到 docker_usr 的 shell 配置..."
# 将 DOCKER_HOST 追加到 docker_usr 的 ~/.bash_profile（若已存在则不重复添加）
sudo -u docker_usr bash -c 'touch ~/.bash_profile && grep -q "DOCKER_HOST" ~/.bash_profile || echo "export DOCKER_HOST=unix:///run/user/1000/docker.sock" >> ~/.bash_profile'
# 让当前脚本会话也能使用该变量（临时）
export DOCKER_HOST=unix:///run/user/1000/docker.sock
say "DOCKER_HOST written to docker_usr's ~/.bash_profile and exported in current session." "DOCKER_HOST 已为 docker_usr 写入 ~/.bash_profile 且当前会话已临时导出。"

say "10. Create socket symlinks..." "10. 创建 socket 软链接..."
sudo ln -sf /run/user/1000/podman/podman.sock /var/run/docker.sock
sudo ln -sf /run/user/1000/podman/podman.sock /run/user/0/docker.sock
sudo -u docker_usr ln -sf /run/user/1000/podman/podman.sock /run/user/1000/docker.sock || ln -sf /run/user/1000/podman/podman.sock /run/user/1000/docker.sock

say "11. Replace docker.service/socket with podman units (dangerous; backup first)..." "11. 替换 docker.service/socket 为 podman 的 (谨慎操作，先备份已有 unit)..."
# 备份已有 docker unit（如果存在）
if [ -f /etc/systemd/system/docker.service ]; then
    sudo cp /etc/systemd/system/docker.service /etc/systemd/system/docker.service.bak.$(date +%s)
    say "Backed up existing /etc/systemd/system/docker.service" "已备份现有 /etc/systemd/system/docker.service"
fi
if [ -f /etc/systemd/system/docker.socket ]; then
    sudo cp /etc/systemd/system/docker.socket /etc/systemd/system/docker.socket.bak.$(date +%s)
    say "Backed up existing /etc/systemd/system/docker.socket" "已备份现有 /etc/systemd/system/docker.socket"
fi
if [ -f /lib/systemd/system/podman.service ]; then
    sudo cp /lib/systemd/system/podman.service /etc/systemd/system/docker.service
fi
if [ -f /lib/systemd/system/podman.socket ]; then
    sudo cp /lib/systemd/system/podman.socket /etc/systemd/system/docker.socket
fi
sudo systemctl daemon-reload
# 启用 docker.service（复制的是 podman 的 unit，可能不完全等价）
sudo systemctl enable --now docker.service || true

say "12. Verify installation..." "12. 验证安装..."

verify_install() {
    say "Starting verification: checking systemd units and client availability..." "开始验证：检查 systemd 单元与客户端可用性..."
    local failed=0

    # 检查 service 单元（优先 docker.service，否则检查 podman.socket）
    if systemctl list-unit-files --type=service | grep -q "^docker.service"; then
        if systemctl is-active --quiet docker.service; then
            say "  [OK] docker.service active" "  [OK] docker.service active"
        else
            say "  [FAIL] docker.service is not active" "  [FAIL] docker.service 未处于 active"
            failed=$((failed+1))
        fi
    else
        if systemctl is-active --quiet podman.socket; then
            say "  [OK] podman.socket active" "  [OK] podman.socket active"
        else
            say "  [WARN] docker.service not detected and podman.socket is not active" "  [WARN] 未检测到 docker.service，且 podman.socket 未处于 active"
            failed=$((failed+1))
        fi
    fi

    # root 下的客户端检查
    (docker -v >/dev/null 2>&1) && say "  [OK] root: docker -v" "  [OK] root: docker -v" || { say "  [FAIL] root: docker -v" "  [FAIL] root: docker -v"; failed=$((failed+1)); }
    (docker-compose -v >/dev/null 2>&1) && say "  [OK] root: docker-compose -v" "  [OK] root: docker-compose -v" || { say "  [FAIL] root: docker-compose -v" "  [FAIL] root: docker-compose -v"; failed=$((failed+1)); }
    (podman -v >/dev/null 2>&1) && say "  [OK] root: podman -v" "  [OK] root: podman -v" || { say "  [FAIL] root: podman -v" "  [FAIL] root: podman -v"; failed=$((failed+1)); }

    # docker_usr 用户下的检查（通过 DOCKER_HOST 指向 rootless socket）
    sudo -u docker_usr bash -lc 'export DOCKER_HOST=unix:///run/user/1000/docker.sock && docker -v' >/dev/null 2>&1 && say "  [OK] docker_usr: docker -v" "  [OK] docker_usr: docker -v" || { say "  [FAIL] docker_usr: docker -v" "  [FAIL] docker_usr: docker -v"; failed=$((failed+1)); }
    sudo -u docker_usr bash -lc 'export DOCKER_HOST=unix:///run/user/1000/docker.sock && docker-compose -v' >/dev/null 2>&1 && say "  [OK] docker_usr: docker-compose -v" "  [OK] docker_usr: docker-compose -v" || { say "  [FAIL] docker_usr: docker-compose -v" "  [FAIL] docker_usr: docker-compose -v"; failed=$((failed+1)); }
    sudo -u docker_usr podman -v >/dev/null 2>&1 && say "  [OK] docker_usr: podman -v" "  [OK] docker_usr: podman -v" || { say "  [FAIL] docker_usr: podman -v" "  [FAIL] docker_usr: podman -v"; failed=$((failed+1)); }

    if [ "$failed" -eq 0 ]; then
        say "Verification passed: all checks succeeded." "验证通过：所有检查项均通过。"
        return 0
    else
        say "Verification failed: $failed checks failed. Please inspect logs or fix manually and retry." "验证失败：共 $failed 项失败。请检查日志或手动修复后重试。"
        return 2
    fi
}

if verify_install; then
    say "Proceeding with remaining steps..." "继续执行后续步骤..."
else
    say "Script aborted: verification did not pass. To skip verification and continue, set FORCE_CONTINUE=1 and retry." "脚本中止：验证未通过。若要跳过验证并继续，请设置环境变量 FORCE_CONTINUE=1 后重试。"
    if [ "${FORCE_CONTINUE:-0}" -eq 1 ]; then
        say "Detected FORCE_CONTINUE=1, forcing continue." "检测到 FORCE_CONTINUE=1，强制继续。"
    else
        exit 1
    fi
fi


say "13. (Optional) remove conflicting system-level docker.service..." "13. （可选清理）移除可能冲突的 system-level docker.service..."
sudo systemctl disable --now docker.service docker.socket || true
sudo rm -f /etc/systemd/system/docker.{service,socket} || true
sudo systemctl daemon-reload
say "Removed replaced docker.service to avoid conflicts with rootless." "已移除替换的 docker.service，避免与 rootless 冲突。"

say "Installation complete! If there are issues, check logs or adjust config manually." "安装完成！如果有问题，检查日志或手动调整配置。"
say "It is recommended to reboot the system or re-login to apply all settings." "建议重启系统或重新登录用户让所有设置生效。"
