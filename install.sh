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
# 节点写进 node.toml 的注册中心清单，按顺序尝试，第一个答应的算数。
# 三个实例之间用签名复制持有同一份记录，所以任何一个都能回答；单实例时代
# 那台机器一挂，全网无法注册、无法心跳、无法被发现。
#
# 但 LN_REGISTRY 一旦被显式指定，清单就**只有它**：有人把节点指向自己的注册
# 中心，却被悄悄追加上公共副本，等于把他的节点送进了公网——覆盖就要覆盖干净。
if [ -n "${LN_REGISTRY:-}" ]; then
    REGISTRY_URLS="\"${REGISTRY}\""
else
    REGISTRY_URLS='"https://registry.libertynet.ai", "https://registry-2.libertynet.ai"'
fi
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


# ---- 测试网告知（11 种语言）--------------------------------------
# 这个脚本会在别人的机器上装一个会显示余额和收益数字的软件。装之前必须先说清
# 三件事：这是测试网、数字不是钱、链可能被清空。
#
# 原来只有末尾一行 “⚠️ Genesis 内测…”，在几十行输出的最后，只有中文。那正好是
# 一条免责声明该长的样子——写了，但没打算被读到。现在它出现在**安装开始之前**，
# 以及安装完成之后，用读者自己的语言。
#
# 语言从 LC_ALL / LC_MESSAGES / LANG 取；取不到就是英文。curl | bash 拿不到浏览器
# 的 Accept-Language，POSIX locale 是这里唯一诚实的信号。
testnet_lang() {
    # Two things this has to survive, both found on a clean Ubuntu 24.04 (2026-08-20):
    #
    # 1. `LC_ALL=C.UTF-8` is set in the stock Ubuntu image and in a lot of cloud-init
    #    defaults. It is not a language — it is "no localisation" — but the old
    #    `${LC_ALL:-${LANG:-}}` chain took it as the answer and stopped there. Result:
    #    a machine with `LANG=zh_TW.UTF-8` got the notice in English, because LC_ALL was
    #    set to something that names no language at all. So C/POSIX are skipped rather
    #    than treated as an answer, and the search continues to LC_MESSAGES/LANG.
    #
    # 2. `LN_LANG=zh-TW` returned **Simplified**. The patterns spelled the region with an
    #    underscore (`zh_TW*`), so the BCP-47 hyphen form fell through to the bare `zh*`
    #    arm. Every other surface in this product — the Console's language menu, the docs,
    #    the App's `matchLocale` — uses the hyphen form, so this was the spelling most
    #    likely to be passed in by hand, and it was the one that silently gave a reader in
    #    Taipei the wrong script. `zh-HK` did the same.
    #
    # The tag is therefore lower-cased and both separators are folded together before
    # matching, so `zh-TW`, `zh_TW.UTF-8`, `zh-Hant` and `ZH-TW` all land on the same arm.
    local tag=""
    local candidate
    for candidate in "${LN_LANG:-}" "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
        case "${candidate}" in
            ''|C|POSIX|C.*|POSIX.*) continue ;;
        esac
        tag="${candidate}"
        break
    done
    tag="$(printf %s "${tag}" | tr 'A-Z-' 'a-z_')"
    case "${tag}" in
        zh_tw*|zh_hk*|zh_mo*|zh*hant*) printf %s 'zh-TW' ;;
        zh*) printf %s 'zh-CN' ;;
        ja*) printf %s 'ja' ;;
        ko*) printf %s 'ko' ;;
        es*) printf %s 'es' ;;
        pt*) printf %s 'pt' ;;
        de*) printf %s 'de' ;;
        fr*) printf %s 'fr' ;;
        ar*) printf %s 'ar' ;;
        hi*) printf %s 'hi' ;;
        *) printf 'en' ;;
    esac
}

testnet_notice() {
    local label headline novalue mayreset
    case "$(testnet_lang)" in
    zh-TW)
        label='測試網'
        headline='LibertyNet 目前作為測試網運行。'
        novalue='這裡顯示的代幣、餘額與收益全部是測試單位。它們沒有任何貨幣價值，不能兌換、出售或換成錢，也不代表對任何有價物的請求權。'
        mayreset='這條鏈隨時可能被重置。鏈上任何資料都不保證保留——餘額、歷史與紀錄可能在不另行通知的情況下被清空。'
        ;;
    zh-CN)
        label='测试网'
        headline='LibertyNet 目前作为测试网运行。'
        novalue='这里显示的代币、余额和收益全部是测试单位。它们没有任何货币价值，不能兑换、出售或换成钱，也不代表对任何有价物的索取权。'
        mayreset='这条链随时可能被重置。链上任何数据都不保证保留——余额、历史和记录可能在不另行通知的情况下被清空。'
        ;;
    ja)
        label='テストネット'
        headline='LibertyNet は現在テストネットとして稼働しています。'
        novalue='ここに表示されるトークン・残高・報酬はすべてテスト用の単位です。金銭的価値はなく、換金・売却・現金との交換はできず、価値のあるものに対する請求権でもありません。'
        mayreset='チェーンはいつでもリセットされる可能性があります。チェーン上のデータの保持は一切保証されません——残高・履歴・記録は予告なく消去されることがあります。'
        ;;
    ko)
        label='테스트넷'
        headline='LibertyNet은 현재 테스트넷으로 운영되고 있습니다.'
        novalue='여기에 표시되는 토큰·잔액·보상은 모두 테스트 단위입니다. 금전적 가치가 없고, 환전·판매·현금 교환이 불가능하며, 어떤 가치에 대한 청구권도 아닙니다.'
        mayreset='체인은 언제든지 초기화될 수 있습니다. 체인 위의 어떤 데이터도 보존이 보장되지 않으며, 잔액·이력·기록이 사전 통지 없이 삭제될 수 있습니다.'
        ;;
    es)
        label='RED DE PRUEBAS'
        headline='LibertyNet funciona como una red de pruebas.'
        novalue='Todos los tokens, saldos y recompensas que se muestran aquí son unidades de prueba. No tienen valor monetario, no se pueden canjear, vender ni cambiar por dinero, y no representan un derecho sobre nada de valor.'
        mayreset='La cadena puede reiniciarse en cualquier momento. No se garantiza que se conserve nada de lo que hay en ella: saldos, historial y registros pueden borrarse sin previo aviso.'
        ;;
    pt)
        label='REDE DE TESTES'
        headline='A LibertyNet está funcionando como uma rede de testes.'
        novalue='Todos os tokens, saldos e recompensas exibidos aqui são unidades de teste. Não têm valor monetário, não podem ser resgatados, vendidos ou trocados por dinheiro, e não representam direito sobre nada de valor.'
        mayreset='A rede pode ser reiniciada a qualquer momento. Nada nela tem preservação garantida — saldos, histórico e registros podem ser apagados sem aviso.'
        ;;
    de)
        label='TESTNETZ'
        headline='LibertyNet läuft als Testnetz.'
        novalue='Alle hier angezeigten Token, Guthaben und Belohnungen sind Testeinheiten. Sie haben keinen Geldwert, können nicht eingelöst, verkauft oder in Geld getauscht werden und stellen keinen Anspruch auf irgendeinen Wert dar.'
        mayreset='Die Chain kann jederzeit zurückgesetzt werden. Für nichts darauf ist der Erhalt garantiert — Guthaben, Verlauf und Aufzeichnungen können ohne Vorankündigung gelöscht werden.'
        ;;
    fr)
        label='RÉSEAU DE TEST'
        headline='LibertyNet fonctionne comme un réseau de test.'
        novalue='Tous les jetons, soldes et récompenses affichés ici sont des unités de test. Ils n'\''ont aucune valeur monétaire, ne peuvent être ni échangés, ni vendus, ni convertis en argent, et ne constituent aucun droit sur quoi que ce soit de valeur.'
        mayreset='La chaîne peut être réinitialisée à tout moment. Rien de ce qui s'\''y trouve n'\''est garanti d'\''être conservé : soldes, historique et enregistrements peuvent être effacés sans préavis.'
        ;;
    ar)
        label='شبكة اختبار'
        headline='تعمل LibertyNet حاليًا كشبكة اختبار.'
        novalue='كل الرموز والأرصدة والمكافآت المعروضة هنا هي وحدات اختبارية. ليس لها أي قيمة مالية، ولا يمكن استبدالها أو بيعها أو تحويلها إلى نقود، ولا تمثل حقًا في أي شيء ذي قيمة.'
        mayreset='قد تُعاد تهيئة السلسلة في أي وقت. لا يوجد أي ضمان بالاحتفاظ بما عليها — قد تُمحى الأرصدة والسجلات والتاريخ دون إشعار مسبق.'
        ;;
    hi)
        label='टेस्टनेट'
        headline='LibertyNet इस समय एक टेस्ट नेटवर्क के रूप में चल रहा है।'
        novalue='यहाँ दिखाए गए सभी टोकन, बैलेंस और इनाम परीक्षण इकाइयाँ हैं। इनका कोई मौद्रिक मूल्य नहीं है, इन्हें भुनाया, बेचा या पैसे में नहीं बदला जा सकता, और ये किसी भी मूल्यवान चीज़ पर दावा नहीं हैं।'
        mayreset='चेन को कभी भी रीसेट किया जा सकता है। उस पर मौजूद किसी भी चीज़ के बने रहने की गारंटी नहीं है — बैलेंस, इतिहास और रिकॉर्ड बिना सूचना के मिटाए जा सकते हैं।'
        ;;
    *)
        label='TESTNET'
        headline='LibertyNet is running as a test network.'
        novalue='Every token, balance and reward shown here is a test unit. It has no monetary value, cannot be redeemed, sold or exchanged for money, and is not a claim on anything of value.'
        mayreset='The chain can be reset at any time. Nothing on it is guaranteed to be kept — balances, history and records may be erased without notice.'
        ;;
    esac
    printf '\n%b%b[ %s ]%b\n' "${C_Y}" "${C_B}" "${label}" "${C_0}"
    printf '%b%s%b\n' "${C_B}" "${headline}" "${C_0}"
    printf '  %s\n' "${novalue}"
    printf '  %s\n\n' "${mayreset}"
}

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

# 下载并校验完的产物，在装进 PATH 之前先问它一句：这台机器的 libc 能不能把它拉起来。
#
# 为什么需要这道闸：官方 linux-x86_64 产物是**动态链接**的（实测
# `ldd ln-coordination-node` → libssl.so.3 / libcrypto.so.3 / libc.so.6）。glibc 比产物
# 构建时更旧的机器上，它在启动那一刻就被动态加载器拒掉，报的是
# `version \`GLIBC_2.xx' not found` —— 而这条消息会被读成「二进制坏了」或者「装坏了」，
# 于是真正的原因（发行版太旧）要排查很久才会浮出来。SHA256 校验管不了这件事：
# 摘要对得上，只说明下载的是那一份，不说明这台机器跑得动它。
#
# **判据取自产物自己，不写死版本号。** 这里不比较「glibc >= 2.xx」那样的常量 ——
# 产物需要什么版本，是它构建环境决定的、会随发布变化的事实；把它固化成脚本里的
# 一个数字，下一次产物换基础镜像时这个数字就开始说谎（而且是沉默地说谎）。
# `ldd` 直接把缺哪个版本符号告诉我们，它是自描述的。
#
# 退出方向：fail-closed，和 SHA256 那道闸一致，并且没有跳过开关。
glibc_gate() {
    local artifact="$1"

    # macOS 不走 glibc；Mach-O 产物的兼容性由 install_binary 的平台分支与
    # Gatekeeper 处理，这里不插手。
    [ "${PLATFORM}" = "linux" ] || return 0

    if ! need ldd; then
        # `ldd` 是 glibc 自带的。Linux 上它不在，基本意味着这台机器的 libc 不是 glibc
        # （musl / Alpine 最常见），而官方产物链接的是 glibc ⇒ 装上去也起不来。
        die "未找到 ldd：这台机器的 libc 似乎不是 glibc，而官方预编译产物是针对 glibc 构建的；" \
            "拒绝安装。请改用源码编译（见 README 的「从源码编译」），或换一台 glibc 发行版。"
    fi

    local out
    out="$(ldd "${artifact}" 2>&1 || true)"

    # 静态链接的产物没有 glibc 依赖可谈 —— 这是「放行」，不是「检查不出来」。
    case "${out}" in
        *"not a dynamic executable"*|*"statically linked"*)
            info "glibc 闸：产物是静态链接，无 glibc 版本要求"
            return 0
            ;;
    esac

    # 动态加载器会把缺的东西逐条列出来。有任何一条 ⇒ 这台机器跑不动它。
    #
    # 两种现实情形都会命中这里，而**诊断不一样，出路也不一样**，所以文案要分开 ——
    # 实测过：Alpine 上 `ldd` 存在（是 musl 的包装），输出是
    # `Error relocating …: __snprintf_chk: symbol not found`，也含 "not found"。
    # 如果这里统一报「glibc 版本不足」，会把人送去升级一个这台机器压根没有的东西。
    if printf '%s\n' "${out}" | grep -q "not found"; then
        local missing host
        missing="$(printf '%s\n' "${out}" | grep "not found" | sed 's/^[[:space:]]*//' | head -5)"
        host="$(ldd --version 2>&1 | head -1)"
        case "${host}" in
            *musl*)
                die "这台机器的 libc 是 musl，而官方预编译产物是针对 glibc 构建的，拒绝安装。" \
                    "这台机器：${host}；加载器报的缺失符号：" \
                    "${missing}" \
                    "这不是版本太旧，是 libc 实现不同 —— 升级发行版**不会**解决它。" \
                    "出路：改用源码编译（见 README 的「从源码编译」），或换一台 glibc 发行版。"
                ;;
            *)
                die "glibc 版本不足，拒绝安装。" \
                    "这台机器：${host}；产物缺少的符号版本：" \
                    "${missing}" \
                    "官方预编译产物是动态链接的，起不来的表现会像「二进制坏了」，所以在这里拦住而不是等它启动失败。" \
                    "出路：升级发行版，或改用源码编译（见 README 的「从源码编译」）。"
                ;;
        esac
    fi

    info "glibc 闸通过（$(ldd --version 2>&1 | head -1)）"
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

    # 顺序是有意的：先确认下载的是那一份（SHA256），再确认这台机器跑得动它（glibc）。
    # 反过来的话，一个被换掉的产物会先被问「你能跑吗」，那个问题对攻击者毫无约束力。
    glibc_gate "${tmp}/${asset}"

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
# 公共注册中心，按顺序 failover（可用 LN_REGISTRY 环境变量覆盖为单个地址）
api_urls = [${REGISTRY_URLS}]
registry_urls = [${REGISTRY_URLS}]
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
# HOME 必须显式给。
#
# systemd 服务不经过 shell，不继承 HOME，工作目录是 /。配置里任何 \`~\` 都会解析
# 成与操作员 shell 不同的路径 —— 越南那台就是这样跑出了两个身份：服务用
# /.libertynet/node.key，而 \`ln-node identity\` 读 /root/.libertynet/node.key，
# 两边各自签名、各自注册，所有信号都是绿的（见 deploy/libertynet-node.service）。
Environment=HOME=${LN_HOME%/*}
WorkingDirectory=${LN_HOME%/*}
ExecStart=${BIN_PATH} start --auto-update --config ${CONFIG_PATH}
Restart=always
RestartSec=5
Environment=RUST_LOG=info
# 默认 1024 个文件描述符 = 拨号+入站+日志共用一千个位置。这台节点的目标是
# 三百万节点网络里的一员，1024 会在远早于 CPU 的地方先撞墙。
#
# 这一行原本只在 deploy/libertynet-node.service 里有。install.sh **会覆盖**
# 已存在的 unit，所以任何按部署文档配好的机器，只要跑一次 install.sh 升级，
# 就会被静默降回 1024 —— 升级本身是成功的，没有任何一处会报错。
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable libertynet-node.service >/dev/null 2>&1 || true
    # `enable --now` 对**已经在跑**的服务什么都不做 —— 这正是升级路径上的坑。
    #
    # 越南那台实测（2026-08-18）：install.sh 把二进制换成 0.1.3、把 unit 重写好，
    # `enable --now` 看到服务 active 就直接返回，于是
    #
    #   /proc/<pid>/exe -> /root/.libertynet/bin/ln-node (deleted)
    #
    # 进程继续跑着已被删除的 0.1.1 inode，跑了五个小时。而命令行
    # `ln-node --version` 读的是磁盘上的新文件，回答 0.1.3 —— 升级脚本成功、
    # 服务 active、版本号是新的，**只有真正在跑的东西是旧的**。新 unit 里的
    # HOME / LimitNOFILE 同样没有生效。
    #
    # macOS 那条路径一直是对的（bootout + kickstart -k）；只有 systemd 这条
    # 少了重启。restart 对未运行的服务等价于 start，所以全新安装不受影响。
    systemctl restart libertynet-node.service
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

# =================================================================
# 算力 provider —— 这台机器能不能挣到 Credits，由这一段决定
# =================================================================
#
# 为什么这一段必须存在。
#
# `ln-node` 是**网络节点**：它注册、心跳、做中继。协调器派发的算力任务不发给它，
# 账本（`credit_ledger`）的收款方也从来不是它的 DID —— 收款方是**算力 provider**
# （`ln-coordination-node`）的 DID。协调器挑人只认注册中心里的一条能力串：
# `compute-batch-deterministic`。`ln-node` 从不公布这条能力
# （默认能力是 `relay`，见 `ln-config`），所以：
#
#   只装 ln-node ⇒ 注册成功、心跳新鲜、doctor 全绿、**收入永远是 0**。
#
# 2026-11-20 在一台刚用线上 install.sh 装好的 macOS 上实测：`ln-node doctor` 说
# 「registered, fresh … and in the dispatch pool」，`ln-node earnings` 说
# 「预计产出 15–20 测试 Credits/日」，而这台机器既没有公布那条能力、也没有任何
# 进程监听 provider 端口 4450 —— 它一个 Credit 都挣不到，而且屏幕上没有一个字
# 说出这件事。那一次之前，这个脚本是外部运营者的唯一入口。
#
# 为什么是下载 earn.sh 而不是在这里重写一遍 provider 安装。
#
# provider 那一半（产物 sha256、身份、价格、systemd 单元、防火墙、注册、验收）
# 已经在 `earn.sh` 里，并且在一台真实的德国 VPS 上端到端验收过
# （1 步 / 82 秒 / exit 0 → credit_ledger seq=75）。抄一份进来就是把同一个机制
# 劈成两半放在两个仓里，两半各自漂移，而漂移的那一天没有任何检查会红。
# 所以这里**调它**，并把它的 sha256 钉死在下面。
#
# 钉死的后果是：earn.sh 改了而这里没跟上 ⇒ 这一步停下并说清楚，不是静默装一个
# 来历不明的脚本。这与 `docs/ops/provisioning/deploy-node.sh` 钉死 install.sh 的
# 做法一致，是故意的。

# 算一个文件的 sha256，小写十六进制；本机两种工具都没有就打印空串。
# （上面 download_prebuilt 里是同样的 sha256sum/shasum 两分支；这里抽出来是因为
#  这一段要在 root 下执行一个下载来的脚本，校验不能是"尽力而为"。）
sha256_of() {
    local out
    if need sha256sum; then
        out="$(sha256sum "$1" | awk '{print $1}')"
    elif need shasum; then
        out="$(shasum -a 256 "$1" | awk '{print $1}')"
    else
        return 0
    fi
    printf '%s' "${out}" | tr 'A-F' 'a-f'
}

EARN_URL="${LN_EARN_URL:-https://libertynet.ai/earn.sh}"
# 2026-11-21 重钉：earn.sh 修掉了收尾摘要里那两句假话（「Operator 钱包 未装网络
# 节点」和一条指向不存在文件的 `operator --create`），见 LibertyNet-hq
# `docs/ops/INSTALL-SH-THREE-ITEMS-2026-11-21.md` 件 3。与 LibertyNet-hq
# `docs/ops/provisioning/earn.sh`（origin/main）逐字节相同。
#
# **这个值和线上 earn.sh 必须同时换。** 先发 earn.sh、再发 install.sh，两次之间
# 有一个几秒的窗口，窗口里这一步会停下并说清楚（不会静默装一个没校验的脚本）。
# 2026-11-21 第三次重钉：genesis #693（earn.sh 在单字节 locale 里第 1 步就死）
# 06:30Z 合并并部署，但**没有回来重钉这个值** ⇒ 从那一刻起线上这条一键命令在
# provider 那一步必然停住（摘要闸是 fail-closed 的，它说的是实话：线上 earn.sh
# 不是我钉的那一份）。07:35Z 实测线上 earn.sh = 33bfa9d2…，这里钉的是
# 1e351e71…（#218 那一版）。
#
# 2026-11-21 第四次重钉：线上 earn.sh 已经是 204158b5…（与 genesis origin/main 的
# `docs/ops/provisioning/earn.sh` 以及线上 `earn.sh.sha256` 三处逐字节一致），
# 而这里钉的还是 33bfa9d2… ⇒ 线上这条一键命令在 provider 那一步必然停住。
# 值的链条到此是四个：1e351e71 → 33bfa9d2 → 204158b5，每一次都是改了 earn.sh 没回来重钉。
#
# **这一次加了闸，不再只靠人记得。** genesis
# `code/portal-daemon/tests/install_pin_matches_live_earn.rs`：线上 install.sh 钉的值
# 与仓里 earn.sh 的 sha256 对不上就红。放在 genesis 是因为 earn.sh 住在那里，
# 而且那个仓的 `ci/libertynet`（ci-wdc2 自建）是**实测在跑**的；那 20 个
# GitHub Actions workflow 一个检查都没产出，闸放进去等于又造一道永远不响的闸。
#
# **改 earn.sh 的人必须回来改这一行。** 顺序只能是：先发 earn.sh，再钉 install.sh
# 并发出去 —— 中间那一小段时间里这一步会停下来并说出原因，那是对的；坏的是
# 像这次一样让那段时间变成一个小时。
# 第五次重钉（2026-11-22）：earn.sh 加了自动传 --reverse-connect，内容变了所以摘要变了。
# 这一次是和 earn.sh、earn.sh.sha256、以及新的 macos-arm64 产物在**同一次**上线里
# 一起换的（staging 目录 + 逐个 mv），所以上面那段说的「中间那一小段时间」压到了毫秒级。
# 第六次重钉（2026-11-22）：linux-aarch64 产物换成带 --reverse-connect 的那一版
# （线上那个是 a060853 的，0 处 --reverse-connect —— earn.sh 会把参数传给它而它
# 只是静默忽略）。同一次上线换四样：产物、产物 sidecar、earn.sh、earn.sh.sha256。
# 第七次重钉（2026-11-22）：earn.sh 修了 macOS 侧的假阳性（bootstrap 失败照样打印
# 「ok provider 在跑」，而「文件换了而进程还是旧的」在 macOS 上一直没有判据）。
EARN_SHA256="${LN_EARN_SHA256:-bcfec1660018e083b39a4a6e69608735736ba640c238515b229979c17ce206ec}"

# 有官方 provider 产物的平台。2026-11-21 起有三个：`libertynet.ai/releases/provider/`
# 下的 `ln-coordination-node-{linux-x86_64,macos-x86_64,macos-arm64}`。
#
# **这张表只许在产物真发出去之后才改。** 它决定脚本是去装 provider 还是说实话；
# 多写一个 slug，运营者就会在一个 404 上失败，而不是读到「这台机器挣不到钱」。
# linux-aarch64（ARM 服务器 / 树莓派）还没有产物，故意不在表里。
PROVIDER_SLUGS="linux-x86_64 macos-x86_64 macos-arm64"

provider_supported() {
    local slug s
    slug="${PLATFORM}-${ARCH}"
    for s in ${PROVIDER_SLUGS}; do
        [ "${s}" = "${slug}" ] && return 0
    done
    return 1
}

# 这台机器挣不到钱时说的那段话。它故意很长、很直白：这是运营者唯一会读到的
# 地方，而「什么都不说」正是之前的行为。
cannot_earn_notice() {
    # $1 = 为什么
    printf '\n%b━━━ 这台机器现在挣不到 Credits ━━━%b\n' "${C_Y}" "${C_0}"
    printf '  原因：%s\n' "$1"
    printf '  网络节点（ln-node）做的是入网与中继，它**本身不产生收入**。\n'
    printf '  账本的收款方是算力 provider（ln-coordination-node）的 DID，\n'
    printf '  而协调器只把任务派给在注册中心公布 %s 的节点。\n' "compute-batch-deterministic"
    printf '  你这台机器公布的不是这条能力，所以它会一直是 0 —— 不是还没开始，是不会开始。\n'
    printf '\n  要挣钱：在一台有 provider 产物的机器上跑（现在是 %s）\n' "${PROVIDER_SLUGS}"
    printf '    Linux： %bcurl -fsSL %s | sudo bash%b\n' "${C_B}" "${EARN_URL}" "${C_0}"
    printf '    macOS： %bcurl -fsSL %s | bash%b   ← 不要 sudo\n' "${C_B}" "${EARN_URL}" "${C_0}"
    printf '  它会装齐网络节点 + 算力 provider，并在屏幕上把验收结果打出来。\n'
    printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "${C_Y}" "${C_0}"
}

# 装 provider。装不了就说清楚为什么，**不**让安装失败 —— 一台只能做中继的机器
# 仍然是一台有用的节点，而它已经装好了。
install_provider() {
    local tmp script

    if [ "${LN_SKIP_PROVIDER:-0}" = "1" ]; then
        warn "LN_SKIP_PROVIDER=1，跳过算力 provider。"
        cannot_earn_notice "你自己要求跳过 provider（LN_SKIP_PROVIDER=1）"
        return 0
    fi

    if ! provider_supported; then
        cannot_earn_notice "官方算力 provider 产物目前有 ${PROVIDER_SLUGS}，这台是 ${PLATFORM}-${ARCH}"
        return 0
    fi

    # root 的要求**按平台**不同，和 earn.sh 里那一段必须一致：
    #   Linux：要 root（/usr/local/bin + systemd 系统单元）
    #   macOS：**不要** root（$HOME/.libertynet + 用户域 LaunchAgent）
    # 这里如果照旧一律要 root，Mac 上就会出现「产物明明有了，脚本还是说挣不到钱」。
    if [ "${PLATFORM}" = "linux" ] && [ "$(id -u)" != "0" ]; then
        cannot_earn_notice "Linux 上装 provider 要 root（它要写 /usr/local/bin 和 systemd 单元），现在不是 root"
        return 0
    fi
    if [ "${PLATFORM}" = "macos" ] && [ "$(id -u)" = "0" ]; then
        cannot_earn_notice "macOS 上装 provider 不能用 sudo（它要装进你自己的 \$HOME 和用户域 LaunchAgent），现在是 root"
        return 0
    fi

    # 测试用的干跑开关。到这里为止，所有「要不要装」的判断都已经做完了，下面是
    # 真下载、真以 root 跑一个脚本 —— 那两件事没法在 CI 里断言。有了这一行，
    # 「macOS arm64 这台机器应当去装 provider」才能被一条测试钉住；没有它，
    # 那条判断就只能靠人读代码，而它正是 2026-11-20 装完挣不到钱的那个判断。
    if [ "${LN_PROVIDER_DRY_RUN:-0}" = "1" ]; then
        printf 'DRY_RUN would install provider for %s-%s\n' "${PLATFORM}" "${ARCH}"
        return 0
    fi

    info "装算力 provider —— 这一步决定这台机器能不能挣到 Credits"
    tmp="$(mktemp -d)"
    script="${tmp}/earn.sh"

    if ! download_with_retry "${EARN_URL}" "${script}"; then
        rm -rf "${tmp}"
        warn "取不到 ${EARN_URL}。"
        cannot_earn_notice "下载 earn.sh 失败（网络问题，不是你这台机器不行）"
        return 0
    fi

    # 校验。对不上就停在这里，绝不执行 —— 这一步是要以 root 跑一个下载来的脚本。
    local got
    got="$(sha256_of "${script}")"
    if [ -z "${got}" ]; then
        rm -rf "${tmp}"
        warn "本机没有可用的 sha256 工具，无法校验 earn.sh —— 不执行未校验的脚本。"
        cannot_earn_notice "无法校验 earn.sh 的 sha256（缺 sha256sum / shasum）"
        return 0
    fi
    if [ "${got}" != "${EARN_SHA256}" ]; then
        rm -rf "${tmp}"
        err "earn.sh 校验失败：期望 ${EARN_SHA256}"
        err "                实得 ${got}"
        err "**没有执行它。** 要么 earn.sh 更新了而这个脚本还没跟上，要么文件被动过。"
        cannot_earn_notice "earn.sh 的 sha256 与钉死的值不符，已拒绝执行"
        return 0
    fi

    # 让 ln-node 出现在 PATH 上。（历史：2026-11-20 加这一行时的说法是「它让
    # earn.sh 的 `-x "$NODE_BIN"` 为真，但 `NODE_CONFIG` 仍写死在
    # /etc/libertynet/node.toml，所以摘要里那两句假话还在」。那个说法在 2026-11-21
    # 之后**不再成立** —— earn.sh 现在自己按实际存在的布局找 bin+config
    # （`resolve_node_layout`），不依赖这座桥。所以这一行今天只剩「让运营者能直接
    # 敲 ln-node」这一个作用，不要再把它当成摘要正确性的前提。）
    if [ -x "${BIN_PATH}" ] && [ ! -e /usr/local/bin/"${BIN_NAME}" ]; then
        ln -sf "${BIN_PATH}" /usr/local/bin/"${BIN_NAME}" 2>/dev/null \
            || warn "没能把 ${BIN_NAME} 链到 /usr/local/bin（不影响挣钱，只影响下面那几行字准不准）。"
    fi

    # `LN_SKIP_NODE=1`：网络节点这一半上面已经装完了，earn.sh 只需要装 provider
    # 那一半（它自己支持这个开关）。LN_ADVERTISE / LN_PRICE / LN_REGION / LN_CELL
    # 由运营者透传，这里不替他猜。
    # LN_HOME / LN_NODE_BIN / LN_NODE_CONFIG 透传：earn.sh 的默认值是 Linux 系统路径
    # （/usr/local/bin + /etc/libertynet），而这个脚本把节点装在 ${LN_HOME} 下。不传的话
    # earn.sh 在 Mac 上会把 provider 装到另一套路径去，并且在最后一段把一台正在跑的
    # 节点报成「没装 / 读不出」—— 2026-11-20 真机实测到的那两句假话。
    if LN_HOME="${LN_HOME}" LN_NODE_BIN="${BIN_PATH}" LN_NODE_CONFIG="${CONFIG_PATH}" \
       LN_SKIP_NODE=1 bash "${script}"; then
        rm -rf "${tmp}"
        # 别用现在时。打印这一行的那一刻，协调器**还不知道**这台机器存在 ——
        # 它每 120 秒才重读一次注册中心（2026-11-21 07:22Z 线上日志实测就是
        # 整 120 秒一行 `fleet discovered from registry`；11-20 实测注册到进
        # 候选池 111 秒，上界就是那个周期）。而同一次安装里 earn.sh 的收尾段
        # 早就说的是将来时加等待时间 —— 两份脚本对同一件事给两个强度不同的
        # 承诺，用户只会记住更强的那个，然后在 4 分钟内以为装坏了。
        info "算力 provider 已装好并注册到注册中心。"
        info "协调器每 120 秒重读一次注册中心 —— 最多 4 分钟后这台机器才进候选池。"
        PROVIDER_INSTALLED=1
        return 0
    fi

    rm -rf "${tmp}"
    warn "earn.sh 没有走完（它自己已经在上面说了是哪一步）。"
    cannot_earn_notice "provider 安装没有走完，见上面 earn.sh 自己打印的那一段"
    return 0
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
# 装完之后真去查一次：这台机器到底连上没有
# =================================================================
# 以前装完只打印一句「注册中心：<地址>」就结束——地址写得再漂亮，节点有没有
# 真的注册上去没人知道。真机上曾经连续 3400+ 次注册失败而安装脚本一声不吭。
# 这里不猜、不写「应该能连」：真发两个 HTTP 请求，按实际结果说话。
#
# 判定分三档，措辞对应真实状态：
#   1) 注册中心不认发现协议 → 地址配错了，明确说是哪一步坏的
#   2) 认协议，但注册表里查不到本机 DID → 明确说「没注册上」并给出排查命令
#   3) 查得到 → 才说连上了
verify_registration() {
    local peers_body did found=0 i

    printf '\n%b验证连接（真发请求，不是估计）：%b\n' "${C_B}" "${C_0}"

    # 第 1 步：这个地址到底认不认发现协议。registry 对 GET /api/v1/peers
    # 必须回 {"ok":true,...} 信封；回别的（404 / HTML / 连不上）都说明这个
    # 地址上没有节点要找的那个服务。
    peers_body="$(curl -fsS -m 15 "${REGISTRY}/api/v1/peers" 2>/dev/null || true)"
    case "${peers_body}" in
        *'"ok"'*'true'*)
            info "注册中心可达，且认识发现协议：${REGISTRY}"
            ;;
        "")
            err "连不上注册中心 ${REGISTRY}（GET /api/v1/peers 无响应）。"
            err "节点已装好并在后台运行，但它现在无法向网络announce自己。"
            err "排查：curl -v ${REGISTRY}/api/v1/peers"
            return 1
            ;;
        *)
            err "${REGISTRY} 有响应，但不是发现协议的应答——这个地址上没有节点要找的服务。"
            err "收到：$(printf '%s' "${peers_body}" | head -c 120)"
            err "用 LN_REGISTRY=<正确地址> 重装，或见 REGISTRY.md。"
            return 1
            ;;
    esac

    # 第 2 步：本机 DID 到底有没有落进注册表。守护进程刚起来，给它最多 45 秒。
    did="$("${BIN_PATH}" --config "${CONFIG_PATH}" identity 2>/dev/null \
        | awk '/DID:/ { print $2; exit }')"
    if [ -z "${did}" ]; then
        warn "读不到本机 DID，跳过注册确认（ln-node identity 无输出）。"
        return 1
    fi
    printf "  本机 DID： %s\n" "${did}"

    # 最多 ~30 秒。干净机器上实测 2 秒内就能查到；给到 30 秒是留给慢机器，
    # 再长就变成让用户干等（安装脚本不该阻塞几分钟）。
    i=0
    while [ "${i}" -lt 10 ]; do
        if curl -fsS -m 5 "${REGISTRY}/nodes" 2>/dev/null | grep -qF "${did}"; then
            found=1
            break
        fi
        i=$((i + 1))
        sleep 3
    done

    if [ "${found}" = "1" ]; then
        info "已确认：本机 DID 出现在注册表里，注册成功。"
    else
        err "注册未成功：30 秒内注册表 ${REGISTRY}/nodes 查不到本机 DID。"
        err "节点在跑，但网络上看不到它。看失败原因："
        err "  grep 'discovery registration failed' ${LOG_PATH} | tail -3"
        return 1
    fi

    # 已知的两个缺口——如实说，别让人以为"注册成功=已经在联网干活"。
    # 详见 REGISTRY.md。
    if printf '%s' "${peers_body}" | tr -d ' ' | grep -q '"data":\[\]'; then
        warn "对等发现（peer discovery）目前是空的：注册中心的 GET /api/v1/peers"
        warn "固定返回空列表，所以本机现在发现不到任何对端。这是已知未接通项"
        warn "（not_yet_wired），不是你这次安装的问题。"
    fi
    warn "重启后若本机监听地址变了，重新注册会被拒（发现注册尚未签名）。"
    warn "两项均见 REGISTRY.md「未接通」一节。"
    return 0
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
    testnet_notice
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

    # 装完就查，不让"装好了"和"连上了"混为一谈。查不通不删任何东西，也不谎报成功。
    if ! verify_registration; then
        printf '\n%b节点已安装并在运行，但尚未接入网络（见上面的 ✗）。%b\n' "${C_Y}" "${C_0}"
        printf '%b你的身份与配置完好，修好网络后 `ln-node stop && ln-node start` 即可重试。%b\n' "${C_Y}" "${C_0}"
    fi

    # 装 provider。放在这里（节点已经在跑、注册已经查过）而不是更早：provider 的
    # 验收会去读注册中心，先把节点那一半落定，失败时两半分得开。
    # 它不会让安装失败 —— 装不了就在屏幕上说清为什么挣不到钱。
    install_provider
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
    printf "  ln-node earnings   看 Operator 收益（测试估算，不是账本余额）\n"
    printf "  ln-node operator   查看/创建/绑定 Operator 钱包\n"
    printf "  ln-node stop       停止后台节点\n"
    printf "  ln-node --version  查看版本（版本号 + git SHA + 构建时间）\n"

    # 挣钱这件事只说实话。`ln-node earnings` 会打印一个「预计产出 15–20
    # 测试 Credits/日」的模拟估算 —— 那是模拟，不是这台机器的实际能力。
    if [ "${PROVIDER_INSTALLED:-0}" = "1" ]; then
        printf '\n%b收入：%b这台机器装了算力 provider，已注册到注册中心。\n' "${C_G}" "${C_0}"
        # 同上：将来时 + 说清要等多久，和 earn.sh 的收尾段一个强度。
        printf '      协调器每 120 秒重读一次注册中心，所以最多 4 分钟后你会进候选池；\n'
        printf '      进了之后有任务就派给你（有没有任务取决于当下有没有人下单，\n'
        printf '      不取决于这台机器 —— 等半天没动静不代表装坏了）。\n'
        printf '      账本收款方是 provider 的 DID；`ln-node earnings` 打印的是模拟估算，\n'
        printf '      不是账本余额。\n'
    fi
    testnet_notice
}

# LN_LIB_ONLY=1 时只定义函数、不执行安装 —— 供 tests/ 里的测试 source 本文件后
# 单独调用 download_prebuilt 等函数。正常 `curl | bash` 路径不设这个变量，行为不变。
if [ -z "${LN_LIB_ONLY:-}" ]; then
    main "$@"
fi
