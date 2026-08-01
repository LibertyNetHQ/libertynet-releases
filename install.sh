#!/usr/bin/env bash
#
# LibertyNet Node —— 一键部署脚本
# =================================================================
# 用法（普通用户即可，无需预装任何东西）：
#
#     curl -sSL https://libertynet.ai/install.sh | bash
#
# 本脚本会自动完成：
#   1. 检测操作系统与 CPU 架构（macOS / Linux，x86_64 / arm64）
#   2. 下载最新 release 预编译二进制并**强制**校验 SHA256（fail-closed：
#      校验文件缺失、内容非法、或摘要不匹配，一律中止安装并非零退出，
#      不会“跳过校验继续装”，也没有跳过开关）
#      （官方产物：linux-x86_64 / macos-arm64 / macos-x86_64；
#       其它平台如 linux-arm64 自动从源码编译）
#   3. 安装 ln-node 到 ~/.libertynet/bin
#   4. 写入默认配置并生成节点身份（Node DID）
#   5. 启动节点服务并配置后台守护：
#        macOS        → 用户级 launchd LaunchAgent（无需 sudo）
#        Linux + root → systemd 系统服务（重启自动拉起）
#        其它         → nohup 后台进程
#
# 环境变量（可选，均有默认值）：
#   LN_REGISTRY   注册中心地址   默认 https://registry.libertynet.ai
#   LN_VERSION    指定版本 tag   默认 latest（拉取最新 release）
#   LN_HOME       安装目录       默认 $HOME/.libertynet
#
# 说明：有预编译产物的平台约 30 秒装好；无产物的平台需本机 Rust 工具链
#       从源码编译，耗时取决于机器性能（首次通常数分钟）。
# =================================================================

set -euo pipefail

# ---- 常量与默认值 ------------------------------------------------
REPO="LibertyNetHQ/libertynet-node"
BIN_NAME="ln-node"
LN_HOME="${LN_HOME:-$HOME/.libertynet}"
BIN_DIR="${LN_HOME}/bin"
BIN_PATH="${BIN_DIR}/${BIN_NAME}"
CONFIG_PATH="${LN_HOME}/node.toml"
KEY_PATH="${LN_HOME}/node.key"
LOG_PATH="${LN_HOME}/node.log"
PID_PATH="${LN_HOME}/node.pid"
REGISTRY="${LN_REGISTRY:-https://registry.libertynet.ai}"
VERSION="${LN_VERSION:-latest}"
# 官方预编译分发镜像（node-1 上 Caddy 托管，libertynet.ai/releases/）。
# 因源码仓库为私有，匿名无法从 GitHub Releases 下载二进制；故默认主源改为此镜像，
# GitHub Releases 退为回退源（仅在仓库公开时匿名可用）。可用 LN_DOWNLOAD_BASE 覆盖。
DL_BASE="${LN_DOWNLOAD_BASE:-https://libertynet.ai/releases}"
# GitHub Releases 回退源（仅在源码仓库公开时匿名可用）。可覆盖，便于测试指向本地 mock。
GH_BASE="${LN_GITHUB_BASE:-https://github.com/${REPO}/releases/download}"

# ---- 彩色日志（无 TTY 时自动降级为纯文本）------------------------
if [ -t 1 ]; then
    C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_B="\033[1m"; C_0="\033[0m"
else
    C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""
fi
info() { printf '%b==>%b %s\n' "${C_G}" "${C_0}" "$*"; }
warn() { printf '%b[!]%b %s\n' "${C_Y}" "${C_0}" "$*"; }
err()  { printf '%b[✗] %s%b\n' "${C_R}" "$*" "${C_0}" >&2; }
die()  { err "$*"; exit 1; }

# ---- 前置依赖检查 ------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1; }

# ---- 便携安装帮助函数 --------------------------------------------
# 等价于 GNU 的 `install -Dm755 SRC DST`：创建目标目录、复制文件、置 0755 权限。
# 之所以不直接用 `install -D`，是因为 macOS 自带的 BSD install 不支持 -D 选项
# （会报 "install: illegal option -- D"）。此写法在 macOS 与 Linux 上均可用。
install_bin() {
    # $1 = 源文件；$2 = 目标路径
    mkdir -p "$(dirname "$2")"
    cp -f "$1" "$2"
    chmod 755 "$2"
}

# ---- 带指数退避的下载 --------------------------------------------
# 网络抖动/瞬断时自动重试，退避 1→2→4→8→16 秒（可用 LN_DL_RETRIES 调整次数）。
# $1 = URL；$2 = 输出文件。成功返回 0，用尽次数返回 1。
download_with_retry() {
    local url="$1" out="$2"
    local attempts="${LN_DL_RETRIES:-5}"
    local delay=1 i=1
    while :; do
        if curl -fSL --connect-timeout 15 --progress-bar -o "${out}" "${url}"; then
            return 0
        fi
        if [ "${i}" -ge "${attempts}" ]; then
            return 1
        fi
        warn "下载失败（第 ${i}/${attempts} 次），${delay}s 后重试…"
        sleep "${delay}"
        delay=$((delay * 2))
        i=$((i + 1))
    done
}

# =================================================================
# 1) 检测系统与架构
# =================================================================
detect_platform() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    case "${ARCH}" in
        x86_64 | amd64) ARCH="x86_64" ;;
        arm64 | aarch64) ARCH="arm64" ;;
        *) die "不支持的 CPU 架构：${ARCH}" ;;
    esac
    case "${OS}" in
        Linux)  PLATFORM="linux" ;;
        Darwin) PLATFORM="macos" ;;
        *) die "不支持的操作系统：${OS}（仅支持 Linux / macOS）" ;;
    esac
    info "检测到系统：${C_B}${PLATFORM} / ${ARCH}${C_0}"
}

# =================================================================
# 2) 获取二进制：预编译优先，否则从源码编译
# =================================================================

# 拉取最新 release 的 tag 名（无 jq 依赖，用 grep/sed 解析）。
# 主源：官方镜像 ${DL_BASE}/latest.txt（纯文本一行 tag，如 v0.1.1）——仓库私有时也可匿名取。
# 回退：GitHub Releases API（仅在仓库公开时匿名可用）。
latest_release_tag() {
    local tag
    tag="$(curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 "${DL_BASE}/latest.txt" 2>/dev/null \
        | tr -d ' \t\r\n')"
    if [ -n "${tag}" ]; then
        printf '%s\n' "${tag}"
        return 0
    fi
    local api="https://api.github.com/repos/${REPO}/releases/latest"
    # 内置 3 次重试，避免 API 瞬时抖动导致取不到 tag。
    curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 "${api}" 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

# 拥有官方预编译 release 产物的平台（与 .github/workflows/release.yml 的
# 构建矩阵一一对应）。其余平台（如 linux-arm64）回退到源码编译。
PREBUILT_SLUGS="linux-x86_64 macos-arm64 macos-x86_64"

# 判断 "${PLATFORM}-${ARCH}" 是否有预编译产物。
has_prebuilt() {
    local slug="$1" s
    for s in ${PREBUILT_SLUGS}; do
        [ "${s}" = "${slug}" ] && return 0
    done
    return 1
}

# 下载预编译二进制并校验 SHA256。
# 参数：$1 = release tag，$2 = 平台标识（linux-x86_64 / macos-arm64 / macos-x86_64）。
# 资产命名 ln-node-<tag>-<platform>-<arch> 必须与 release.yml、ln-updater 一致。
download_prebuilt() {
    local tag="$1" slug="$2"
    local asset="${BIN_NAME}-${tag}-${slug}"
    # 主源 = 官方镜像 ${DL_BASE}/<tag>/<asset>（node-1，libertynet.ai，仓库私有也可匿名下）。
    # 回退源 = GitHub Releases（仓库公开时匿名可用）。
    local base="${DL_BASE}/${tag}"
    local gh_base="${GH_BASE}/${tag}"
    local tmp; tmp="$(mktemp -d)"
    # 注意：不要用 `trap ... RETURN` 清理 tmp。bash（未开 functrace）的 RETURN
    # trap 不会自动解除，会泄漏到调用者 install_binary 的 return；届时 tmp 已出
    # 作用域，在 `set -u` 下触发 “tmp: unbound variable”，导致预编译安装装完二进制
    # 就中止（不写配置/身份/服务）。改为在各返回点显式清理。
    info "下载预编译二进制 ${asset} ..."
    # 依次尝试：官方镜像（主源）→ GitHub Releases（回退）→ LN_MIRROR（可选自定义备用）。
    # 每个源都带指数退避重试。任一成功即停止。
    local got_bin=0
    if download_with_retry "${base}/${asset}" "${tmp}/${asset}"; then
        got_bin=1
    elif download_with_retry "${gh_base}/${asset}" "${tmp}/${asset}"; then
        warn "镜像主源不可用，改用 GitHub Releases"
        got_bin=1
    elif [ -n "${LN_MIRROR:-}" ] && download_with_retry "${LN_MIRROR%/}/${asset}" "${tmp}/${asset}"; then
        warn "改用自定义备用源：${LN_MIRROR}"
        got_bin=1
    fi
    if [ "${got_bin}" != "1" ]; then
        warn "预编译二进制下载失败（镜像 / GitHub / 备用源均失败：${asset}）"
        rm -rf "${tmp}"
        return 1
    fi

    # SHA256 校验 —— fail-closed（安全红线，不要改回 fail-open）。
    #
    # 历史缺陷：这里曾经是「校验文件缺失只告警不阻断」，攻击者只要让 <asset>.sha256
    # 返回 404（劫持 DNS / 中间人 / 镜像被污染时删掉校验文件即可），完整性校验就被
    # 整段跳过，被篡改的二进制照样装进用户机器并以守护进程常驻。
    #
    # 现在的规则，三种失败一律 die（非零退出，绝不继续安装、也不回退到源码编译）：
    #   1. 校验文件取不到（镜像与 GitHub 回退都失败）
    #   2. 校验文件内容不是合法的 64 位十六进制摘要（空文件 / HTML 错误页 / 被截断）
    #   3. 实际摘要与期望摘要不一致
    # 没有跳过开关：任何 “LN_SKIP_CHECKSUM” 之类的逃生门都会把这个洞原样带回来。
    info "校验 SHA256 ..."
    if ! curl -fsSL -o "${tmp}/${asset}.sha256" "${base}/${asset}.sha256" 2>/dev/null \
        && ! curl -fsSL -o "${tmp}/${asset}.sha256" "${gh_base}/${asset}.sha256" 2>/dev/null; then
        rm -rf "${tmp}"
        die "未找到 SHA256 校验文件（${asset}.sha256，镜像与 GitHub 回退均失败）；" \
            "拒绝安装未经校验的二进制。请稍后重试或到 https://github.com/LibertyNetHQ/libertynet-releases 报告。"
    fi
    local want got
    want="$(awk 'NR==1{print $1}' "${tmp}/${asset}.sha256" | tr -d ' \t\r\n')"
    # 合法性检查：必须是 64 位小写十六进制。挡住空文件 / 被 Caddy 返回的 HTML
    # 错误页 / 传输截断 —— 否则 "want" 是垃圾串，比对必然不等，报错信息也会误导。
    if ! printf '%s' "${want}" | grep -qiE '^[0-9a-f]{64}$'; then
        rm -rf "${tmp}"
        die "SHA256 校验文件内容非法（不是 64 位十六进制摘要）：'${want}'；拒绝安装。"
    fi
    if need sha256sum; then
        got="$(sha256sum "${tmp}/${asset}" | awk '{print $1}')"
    else
        got="$(shasum -a 256 "${tmp}/${asset}" | awk '{print $1}')"
    fi
    if [ "$(printf '%s' "${want}" | tr 'A-F' 'a-f')" != "$(printf '%s' "${got}" | tr 'A-F' 'a-f')" ]; then
        rm -rf "${tmp}"
        die "SHA256 校验失败：期望 ${want}，实际 ${got}；拒绝安装。"
    fi
    info "SHA256 校验通过"

    install_bin "${tmp}/${asset}" "${BIN_PATH}"

    # macOS：curl 下载的文件通常没有 quarantine 属性，但个别环境会带上，
    # 导致 Gatekeeper 拦截未签名二进制。尽力清除，失败无妨。
    if [ "${PLATFORM}" = "macos" ] && need xattr; then
        xattr -d com.apple.quarantine "${BIN_PATH}" 2>/dev/null || true
    fi

    rm -rf "${tmp}"
}

# 从源码编译（macOS / arm64 / 无 release 时的回退路径）
build_from_source() {
    need git   || die "从源码编译需要 git，请先安装后重试"
    need cargo || die "从源码编译需要 Rust 工具链（cargo），请安装：https://rustup.rs 后重试"

    local src="${LN_HOME}/src"
    info "从源码编译（平台无预编译产物，耗时较长）..."
    if [ -d "${src}/.git" ]; then
        git -C "${src}" fetch --depth 1 origin main --quiet && \
            git -C "${src}" reset --hard origin/main --quiet
    else
        rm -rf "${src}"
        git clone --depth 1 "https://github.com/${REPO}.git" "${src}" --quiet
    fi

    ( cd "${src}" && cargo build --release --bin "${BIN_NAME}" )
    install_bin "${src}/target/release/${BIN_NAME}" "${BIN_PATH}"
}

install_binary() {
    mkdir -p "${BIN_DIR}"

    local slug="${PLATFORM}-${ARCH}"
    # Linux x86_64 / macOS arm64 / macOS x86_64 有官方预编译 release，秒装；
    # 其余平台（如 linux-arm64）回退到源码编译。
    if has_prebuilt "${slug}"; then
        local tag="${VERSION}"
        if [ "${tag}" = "latest" ]; then
            tag="$(latest_release_tag || true)"
        fi
        if [ -n "${tag}" ] && download_prebuilt "${tag}" "${slug}"; then
            info "已安装预编译二进制（${tag} / ${slug}）→ ${BIN_PATH}"
            return
        fi
        warn "无可用预编译 release（${slug}），改为从源码编译"
    else
        warn "平台 ${slug} 暂无预编译产物，改为从源码编译"
    fi
    build_from_source
    info "已从源码编译并安装 → ${BIN_PATH}"
}

# =================================================================
# 3) 写入配置（若不存在）
# =================================================================
write_config() {
    if [ -f "${CONFIG_PATH}" ]; then
        info "配置已存在，保留不覆盖：${CONFIG_PATH}"
        return
    fi
    info "写入默认配置 → ${CONFIG_PATH}（注册中心：${REGISTRY}）"
    mkdir -p "${LN_HOME}"
    cat > "${CONFIG_PATH}" <<EOF
# LibertyNet Node 配置 —— 由 install.sh 生成
[identity]
key_file = "${KEY_PATH}"
auto_generate = true

[transport]
bind_port = 4433
alpn = ["libertynet/svrp/1"]

[relay]
urls = []
region = "default"

[discovery]
# 公共注册中心（可用 LN_REGISTRY 环境变量覆盖）
api_urls = ["${REGISTRY}"]
registry_urls = ["${REGISTRY}"]
heartbeat_interval_secs = 60
capabilities = ["relay", "inference"]

[policy]
enabled = true
allow_relay = true
accept_inbound = true

[agent]
tick_interval_secs = 30
evidence_enabled = true

[metrics]
enabled = true
bind_addr = "127.0.0.1:9090"
EOF
}

# =================================================================
# 4) 生成节点身份（DID）
# =================================================================
generate_identity() {
    if [ -f "${KEY_PATH}" ]; then
        info "已存在节点身份，复用现有 DID："
        "${BIN_PATH}" --config "${CONFIG_PATH}" identity || true
        return
    fi
    info "生成节点身份（DID）..."
    "${BIN_PATH}" --config "${CONFIG_PATH}" identity --generate
}

# =================================================================
# 4b) 绑定到 Operator 钱包（资产归属主体）
# =================================================================
# Node 干活赚的 Credits 归 Operator。已绑定则跳过；否则询问「已有/新建」。
# 交互从 /dev/tty 读取，兼容 `curl … | bash` 管道；无 tty 时默认自动新建，
# 由 ln-node 打印助记词并（尽力）存入 Keychain。
bind_operator() {
    # 已绑定则复用
    if grep -q '^operator_did' "${CONFIG_PATH}" 2>/dev/null; then
        info "已绑定 Operator，复用现有绑定："
        "${BIN_PATH}" --config "${CONFIG_PATH}" operator || true
        return
    fi

    info "绑定到你的 Operator 钱包（Node 干活，赚的 Credits 归你的钱包）"
    local choice=""
    if [ -r /dev/tty ]; then
        printf "  你有 LibertyNet Operator 钱包吗？\n"
        printf "  [1] 有 → 输入 Operator DID 绑定\n"
        printf "  [2] 没有 → 我帮你创建一个（默认）\n"
        printf "  > "
        read -r choice </dev/tty || choice=""
    else
        warn "无交互终端，默认自动创建新的 Operator 钱包"
        choice="2"
    fi

    if [ "${choice}" = "1" ]; then
        local did=""
        printf "  请输入 Operator DID（did:svrp:...）：> "
        read -r did </dev/tty || did=""
        if [ -n "${did}" ]; then
            "${BIN_PATH}" --config "${CONFIG_PATH}" operator --bind "${did}"
            return
        fi
        warn "未输入 DID，改为创建新钱包"
    fi

    # 新建：ln-node 生成身份+助记词、抽查、写 Keychain、写 operator_did
    "${BIN_PATH}" --config "${CONFIG_PATH}" operator --create
}

# =================================================================
# 5) 启动服务
# =================================================================

# Linux + root + systemd：安装并启用系统服务（重启后自动拉起）
start_systemd() {
    local unit="/etc/systemd/system/libertynet-node.service"
    info "安装 systemd 服务 → ${unit}"
    cat > "${unit}" <<EOF
[Unit]
Description=LibertyNet Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SUDO_USER:-root}
ExecStart=${BIN_PATH} start --auto-update --config ${CONFIG_PATH}
Restart=always
RestartSec=5
Environment=RUST_LOG=info

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now libertynet-node.service
    sleep 2
    if systemctl is-active --quiet libertynet-node.service; then
        info "节点服务已启动（systemd）。查看日志：journalctl -u libertynet-node -f"
    else
        die "服务启动失败，请查看：journalctl -u libertynet-node -e"
    fi
}

# macOS：安装用户级 launchd LaunchAgent（无需 sudo；关闭终端后仍运行，
# 且重新登录/重启后自动拉起）。日志写入 ${LOG_PATH}。
start_launchd() {
    local label="ai.libertynet.node"
    local plist_dir="${HOME}/Library/LaunchAgents"
    local plist="${plist_dir}/${label}.plist"
    mkdir -p "${plist_dir}"

    info "安装 launchd 守护 → ${plist}"
    cat > "${plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN_PATH}</string>
        <string>start</string>
        <string>--auto-update</string>
        <string>--config</string>
        <string>${CONFIG_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_PATH}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_PATH}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>RUST_LOG</key>
        <string>${RUST_LOG:-info}</string>
    </dict>
</dict>
</plist>
EOF

    # 先卸载旧实例（若有），再加载。优先用新式 bootstrap/bootout，
    # 失败回退到经典 load/unload -w（兼容旧版 macOS）。
    local uid domain
    uid="$(id -u)"
    domain="gui/${uid}"
    launchctl bootout "${domain}/${label}" 2>/dev/null || true
    launchctl unload -w "${plist}" 2>/dev/null || true
    if launchctl bootstrap "${domain}" "${plist}" 2>/dev/null \
        || launchctl load -w "${plist}" 2>/dev/null; then
        launchctl kickstart -k "${domain}/${label}" 2>/dev/null || true
        sleep 2
        if launchctl print "${domain}/${label}" >/dev/null 2>&1 \
            || pgrep -f "${BIN_PATH} start" >/dev/null 2>&1; then
            info "节点守护已启动（launchd）。日志：tail -f ${LOG_PATH}"
            info "停止：launchctl bootout ${domain}/${label}"
            return 0
        fi
    fi
    warn "launchd 加载失败，回退到 nohup 后台运行"
    start_background
}

# 通用回退：后台运行（非 root Linux / launchd 不可用时）
start_background() {
    # 若已有存活进程，先停掉，避免重复启动
    if [ -f "${PID_PATH}" ] && kill -0 "$(cat "${PID_PATH}")" 2>/dev/null; then
        info "停止已有节点进程（PID $(cat "${PID_PATH}")）"
        kill "$(cat "${PID_PATH}")" 2>/dev/null || true
        sleep 1
    fi
    info "后台启动节点，日志：${LOG_PATH}"
    RUST_LOG="${RUST_LOG:-info}" nohup \
        "${BIN_PATH}" start --auto-update --config "${CONFIG_PATH}" \
        >"${LOG_PATH}" 2>&1 &
    echo $! > "${PID_PATH}"
    sleep 2
    if kill -0 "$(cat "${PID_PATH}")" 2>/dev/null; then
        info "节点已在后台运行（PID $(cat "${PID_PATH}")）。跟踪日志：tail -f ${LOG_PATH}"
    else
        err "节点进程未能保持运行，最近日志："
        tail -n 20 "${LOG_PATH}" 2>/dev/null || true
        die "启动失败"
    fi
}

start_service() {
    if [ "${PLATFORM}" = "linux" ] && [ "$(id -u)" = "0" ] && need systemctl; then
        start_systemd
    elif [ "${PLATFORM}" = "macos" ] && need launchctl; then
        start_launchd
    else
        start_background
    fi
}

# =================================================================
# 安装失败最小清理（事务式思路的最小版；绝不动身份/密钥/配置）
# =================================================================
# 安装未走到最后一步就退出时，清掉本次留下的半成品（损坏的二进制、我们刚建的
# 空目录），但**绝不**删除已有的 Node DID / 密钥 / 配置——身份永远优先保留。
INSTALL_OK=0
FRESH_INSTALL=0
on_install_exit() {
    local rc=$?
    [ "${INSTALL_OK}" = "1" ] && return 0
    warn "安装未完成（退出码 ${rc}），正在做最小清理……"
    # 只删“跑不起来”的损坏二进制，避免误删已装好的旧版本。
    if [ -f "${BIN_PATH}" ] && ! "${BIN_PATH}" --help >/dev/null 2>&1; then
        rm -f "${BIN_PATH}" && warn "已删除损坏的二进制：${BIN_PATH}"
    fi
    # 仅当本次是全新安装、且尚未生成身份时，才清掉我们刚建的空壳目录
    # （rmdir 只删空目录：若已写入 node.toml/密钥则会失败并保留，符合预期）。
    if [ "${FRESH_INSTALL}" = "1" ] && [ ! -f "${KEY_PATH}" ]; then
        rmdir "${BIN_DIR}" 2>/dev/null || true
        rmdir "${LN_HOME}" 2>/dev/null || true
    fi
    err "安装未完成——你的身份与配置未受影响。"
    err "网络恢复后重新运行安装命令即可继续（幂等，不会重复创建身份）。"
}

# =================================================================
# 主流程
# =================================================================
main() {
    printf '%bLibertyNet Node 一键部署%b\n' "${C_B}" "${C_0}"
    need curl || die "缺少 curl，请先安装后重试"

    # 记录是否全新安装（须在创建任何目录之前），并挂上失败清理钩子。
    [ -e "${LN_HOME}" ] || FRESH_INSTALL=1
    trap on_install_exit EXIT

    detect_platform
    install_binary
    write_config
    generate_identity
    bind_operator
    start_service
    INSTALL_OK=1  # 走到这里即视为成功，关闭失败清理

    printf '\n%b%b✔ 部署完成！%b\n' "${C_G}" "${C_B}" "${C_0}"
    printf "  二进制：   %s\n" "${BIN_PATH}"
    printf "  配置：     %s\n" "${CONFIG_PATH}"
    printf "  身份：     %s\n" "${KEY_PATH}"
    printf "  注册中心： %s\n" "${REGISTRY}"
    printf "\n把 ln-node 加入 PATH（可选）：\n"
    # shellcheck disable=SC2016  # 有意保留字面 $PATH：这是打印给用户照抄的命令，不应展开
    printf '  %bexport PATH="%s:$PATH"%b\n' "${C_B}" "${BIN_DIR}" "${C_0}"

    # 引导下一步：把节点绑定到浏览器 Operator Console（双签名 Web 绑定闭环）。
    printf '\n%b下一步 — 绑定到 Operator Console：%b\n' "${C_B}" "${C_0}"
    printf '  %bln-node bind%b\n' "${C_B}" "${C_0}"
    printf "  会显示一个一次性绑定码；到 %s 输入即可完成绑定。\n" "${CONSOLE:-https://libertynet.ai/console}"

    printf "\n常用命令：\n"
    printf "  ln-node bind       绑定到 Operator Console（拿绑定码去网页授权）\n"
    printf "  ln-node chat       和我对话（关键词问答）\n"
    printf "  ln-node status     看节点状态\n"
    printf "  ln-node earnings   看 Operator 收益（测试估算）\n"
    printf "  ln-node operator   查看/创建/绑定 Operator 钱包\n"
    printf "  ln-node stop       停止后台节点\n"
    printf "  ln-node --version  查看版本（版本号 + git SHA + 构建时间）\n"
    printf "⚠️ Genesis 内测：Credits 是测试单位，非现金；数据可能重置。\n"
}

# LN_LIB_ONLY=1 时只定义函数、不执行安装 —— 供 tests/ 里的测试 source 本文件后
# 单独调用 download_prebuilt 等函数。正常 `curl | bash` 路径不设这个变量，行为不变。
if [ -z "${LN_LIB_ONLY:-}" ]; then
    main "$@"
fi
