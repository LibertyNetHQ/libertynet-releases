#!/usr/bin/env bash
#
# install.sh 完整性校验（SHA256）回归测试 —— fail-closed 红线。
#
# 为什么存在：install.sh 曾经是 fail-open —— 拿不到 <asset>.sha256 时只打印一行
# warn 就继续安装。攻击者只要让校验文件返回 404，完整性校验整段被跳过。本套测试
# 把「校验文件缺失 ⇒ 安装必须失败」钉成可执行断言，防止改回去。
#
# 完全 hermetic：不碰公网、不碰真 release、不写 $HOME。用本地 python3 http.server
# 假扮官方镜像与 GitHub 回退源，LN_HOME 指向临时目录。
#
# 用法： bash tests/test-install-sh.sh
# 退出码： 0 = 全部通过，非 0 = 有用例失败。

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${HERE}/../install.sh"
TAG="vtest"
SLUG="linux-x86_64"
ASSET="ln-node-${TAG}-${SLUG}"

PASS=0
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ -f "${INSTALL_SH}" ] || { echo "找不到 install.sh：${INSTALL_SH}"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "需要 python3 起 mock 服务器"; exit 2; }

WORK="$(mktemp -d)"
SRV_PID=""
cleanup() {
    if [ -n "${SRV_PID}" ]; then
        kill "${SRV_PID}" 2>/dev/null
        wait "${SRV_PID}" 2>/dev/null
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

# ---- mock 分发源 -------------------------------------------------
# 目录结构与真镜像一致： <root>/<tag>/<asset> 和 <root>/<tag>/<asset>.sha256
ROOT="${WORK}/www"
mkdir -p "${ROOT}/${TAG}"
printf 'fake ln-node binary payload\n' > "${ROOT}/${TAG}/${ASSET}"
if command -v sha256sum >/dev/null 2>&1; then
    REAL_SHA="$(sha256sum "${ROOT}/${TAG}/${ASSET}" | awk '{print $1}')"
else
    REAL_SHA="$(shasum -a 256 "${ROOT}/${TAG}/${ASSET}" | awk '{print $1}')"
fi

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${ROOT}" >/dev/null 2>&1 &
SRV_PID=$!
BASE="http://127.0.0.1:${PORT}"

# 等服务器起来（最多 5s）
for _ in $(seq 1 50); do
    curl -fsS -o /dev/null "${BASE}/${TAG}/${ASSET}" 2>/dev/null && break
    sleep 0.1
done
curl -fsS -o /dev/null "${BASE}/${TAG}/${ASSET}" || { echo "mock 服务器没起来"; exit 2; }

# ---- 用例执行器 --------------------------------------------------
# 每个用例都在独立 bash 进程里跑：install.sh 的 die() 会 exit，必须隔离。
# GH_BASE 也指向 mock（一个必然 404 的路径），保证不出网、且回退源同样不可用。
LAST_OUT=""
LAST_RC=0
run_case() {
    local home="${WORK}/home-$1"
    rm -rf "${home}"
    LAST_OUT="$(
        LN_LIB_ONLY=1 \
        LN_HOME="${home}" \
        LN_DOWNLOAD_BASE="${BASE}" \
        LN_GITHUB_BASE="${BASE}/no-such-github-fallback" \
        LN_DL_RETRIES=1 \
        bash -c '
            # shellcheck disable=SC1090
            source "$1"
            PLATFORM=linux
            download_prebuilt "$2" "$3"
        ' _ "${INSTALL_SH}" "${TAG}" "${SLUG}" 2>&1
    )"
    LAST_RC=$?
    INSTALLED_AT="${home}/bin/ln-node"
}

assert_rc_nonzero() { [ "${LAST_RC}" -ne 0 ] && ok "$1（退出码 ${LAST_RC}）" || bad "$1（期望非零退出，实际 0）"; }
assert_rc_zero()    { [ "${LAST_RC}" -eq 0 ] && ok "$1" || bad "$1（期望 0，实际 ${LAST_RC}）；输出：${LAST_OUT}"; }
assert_not_installed() {
    if [ -e "${INSTALLED_AT}" ]; then
        bad "$1（二进制不该落盘，却存在于 ${INSTALLED_AT}）"
    else
        ok "$1"
    fi
}
assert_installed() { [ -x "${INSTALLED_AT}" ] && ok "$1" || bad "$1（二进制没装上）"; }
assert_out_has()   { printf '%s' "${LAST_OUT}" | grep -q "$2" && ok "$1" || bad "$1（输出里找不到 '$2'）：${LAST_OUT}"; }

SUMS="${ROOT}/${TAG}/${ASSET}.sha256"

# =================================================================
head_ "用例 1 — 校验文件正常：安装成功且明确报告校验通过"
printf '%s  %s\n' "${REAL_SHA}" "${ASSET}" > "${SUMS}"
run_case 1
assert_rc_zero        "校验通过时退出码为 0"
assert_installed      "校验通过时二进制被安装"
assert_out_has        "输出中确认执行了校验" "SHA256 校验通过"

# =================================================================
head_ "用例 2 — 校验文件缺失（404）：必须 fail-closed（本次修复的核心漏洞）"
rm -f "${SUMS}"
run_case 2
assert_rc_nonzero     "校验文件缺失时非零退出"
assert_not_installed  "校验文件缺失时二进制不落盘"
assert_out_has        "报错说明是校验文件缺失" "未找到 SHA256 校验文件"

# =================================================================
head_ "用例 3 — 摘要不匹配（二进制被篡改）：必须中止"
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "${ASSET}" > "${SUMS}"
run_case 3
assert_rc_nonzero     "摘要不匹配时非零退出"
assert_not_installed  "摘要不匹配时二进制不落盘"
assert_out_has        "报错说明是校验失败" "SHA256 校验失败"

# =================================================================
head_ "用例 4 — 校验文件是 HTML 错误页（镜像返回 200 但内容是垃圾）：必须中止"
printf '<!doctype html><html><body>404 Not Found</body></html>\n' > "${SUMS}"
run_case 4
assert_rc_nonzero     "校验文件非法时非零退出"
assert_not_installed  "校验文件非法时二进制不落盘"
assert_out_has        "报错说明是校验文件内容非法" "校验文件内容非法"

# =================================================================
head_ "用例 5 — 校验文件为空：必须中止"
: > "${SUMS}"
run_case 5
assert_rc_nonzero     "空校验文件时非零退出"
assert_not_installed  "空校验文件时二进制不落盘"

# =================================================================
head_ "用例 6 — 大写十六进制摘要：应被接受（大小写不敏感，不误杀）"
printf '%s  %s\n' "$(printf '%s' "${REAL_SHA}" | tr 'a-f' 'A-F')" "${ASSET}" > "${SUMS}"
run_case 6
assert_rc_zero        "大写摘要仍然通过"
assert_installed      "大写摘要时二进制被安装"

# =================================================================
head_ "用例 7 — 静态红线：源码里不得存在跳过校验的逃生门"
if grep -nE 'SKIP_CHECKSUM|SKIP_SHA|INSECURE|跳过完整性校验|跳过校验' "${INSTALL_SH}" \
    | grep -vE '^\s*[0-9]+:\s*#' | grep -qv '不要改回 fail-open'; then
    bad "install.sh 里出现了跳过校验的开关/分支"
    grep -nE 'SKIP_CHECKSUM|SKIP_SHA|INSECURE|跳过完整性校验|跳过校验' "${INSTALL_SH}"
else
    ok "install.sh 中没有跳过校验的开关"
fi

# =================================================================
printf '\n\033[1m结果：%d 通过 / %d 失败\033[0m\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
