# 验证 LibertyNet 发布产物

本仓（`LibertyNetHQ/libertynet-releases`）的每个 release 产物都用
**cosign keyless（Sigstore + GitHub OIDC）** 签名。信任根是 **Sigstore 公共透明日志**，
所以**不需要我们分发任何公钥**，你也不需要相信我们贴出来的某串指纹。

---

## 一、验证命令

只需要 [cosign](https://docs.sigstore.dev/cosign/system_config/installation/)（v2+）：

```bash
cosign verify-blob \
  --bundle "<产物>.sigstore.json" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --certificate-identity-regexp '^https://github\.com/LibertyNetHQ/libertynet-releases/\.github/workflows/sign-release\.yml@refs/' \
  "<产物>"
```

输出 `Verified OK` 即通过。

完整示例（下载 + 验证 macOS 安装包）：

```bash
TAG=v0.1.0-a5be046; F=LibertyNet-Node-0.1.0-a5be046.pkg; B=https://github.com/LibertyNetHQ/libertynet-releases/releases/download/$TAG; curl -fsSLO "$B/$F" && curl -fsSLO "$B/$F.sigstore.json" && cosign verify-blob --bundle "$F.sigstore.json" --certificate-oidc-issuer "https://token.actions.githubusercontent.com" --certificate-identity-regexp '^https://github\.com/LibertyNetHQ/libertynet-releases/\.github/workflows/sign-release\.yml@refs/' "$F"
```

---

## 二、必须核对的身份（重点）

`cosign verify-blob` 通过**只说明签名有效**。真正决定「是谁签的」的是这两个参数——
**不要省略、不要放宽**：

| 参数 | 必须是 | 含义 |
|------|--------|------|
| `--certificate-oidc-issuer` | `https://token.actions.githubusercontent.com` | 身份由 GitHub Actions 的 OIDC 签发，不是随便谁 |
| `--certificate-identity-regexp` | `^https://github\.com/LibertyNetHQ/libertynet-releases/\.github/workflows/sign-release\.yml@refs/` | 签名来自**本仓的 `sign-release.yml` 工作流**，不是别的仓、别的工作流、别的人 |

用 `--certificate-identity-regexp` 而不是精确 `--certificate-identity`，是因为证书里的身份
末尾带触发时的 git ref（发版时是 `@refs/tags/<tag>`，手动补签时是 `@refs/heads/main`），
逐版本不同。正则把仓库 + 工作流文件路径钉死，只放开 ref 部分。

想亲眼看证书里的身份：

```bash
cosign verify-blob --bundle "<产物>.sigstore.json" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --certificate-identity-regexp '.*' "<产物>" 2>&1 | head
# 或直接解出证书看 SAN：
openssl x509 -in "<产物>.pem" -noout -text | grep -A1 'Subject Alternative Name'
```

每个产物同时提供三个文件：

| 文件 | 用途 |
|------|------|
| `<产物>.sigstore.json` | Sigstore bundle（**推荐**，含签名+证书+透明日志条目，一条命令验完） |
| `<产物>.sig` | 裸签名（base64），给老工具链 |
| `<产物>.pem` | 短命签名证书，可自行解析查看身份 |

---

## 三、这个签名证明什么、不证明什么（诚实边界）

**证明：**

- 该文件**由 `LibertyNetHQ/libertynet-releases` 的 `sign-release.yml` 工作流签发**；
- 该文件自签发以来**一个字节都没被改过** —— 中间人、被污染的镜像、被替换的 GitHub 产物，验签都会失败；
- 签名事件已进入 **Rekor 公共透明日志**，任何人可独立审计，我们事后也删不掉。

**不证明：**

- ❌ **不证明「这个二进制是从某个源码 commit 构建出来的」。** 构建溯源（SLSA provenance）
  需要在**私有**构建仓里出具，尚未做，状态 = planned。release 说明里写的
  「built from commit `xxxxxxx`」目前**外部无法验证**，只能选择相信。
- ❌ **不证明代码没有漏洞、行为安全**，签名只管来源与完整性。
- ❌ **不等于 Apple 签名/公证。** macOS `.pkg` 仍是未签名未公证的，Gatekeeper 照旧拦，
  需要右键 → 打开。Apple 开发者账号（$99/年）= planned，另议。
- ❌ **不覆盖 `ln-node` 自身的发布产物**（`libertynet.ai/releases/…`、私有仓
  `LibertyNetHQ/libertynet-node` 的 release）。那条线目前只有 SHA256 校验，
  没有 cosign 签名 —— 因为签名工作流只能加在公开仓里。见下节。

---

## 四、另一条分发线：`install.sh` 装的 `ln-node`

`curl -sSL https://libertynet.ai/install.sh | bash` 安装的是 `ln-node`，产物来自
**另一套发布**（不是本仓的 release）。它当前的保护级别：

| 项 | 状态 |
|----|------|
| SHA256 校验 | ✅ 有，且 **fail-closed**：校验文件缺失 / 内容非法 / 摘要不匹配，一律**中止安装并非零退出**，没有跳过开关 |
| cosign 签名 | ❌ 无（签名工作流只能加在公开仓，`ln-node` 构建在私有仓）= 待办 |

⚠️ 老实说清楚：SHA256 与二进制走同一条通道，只防传输损坏与「删掉校验文件绕过校验」
这类攻击，**不防「同时替换二进制与校验文件」的攻击**。真正的信任锚要等 `ln-node`
那条线也接上 keyless 签名。

`install.sh` 本身的行为由本仓的
[`tests/test-install-sh.sh`](../tests/test-install-sh.sh) 钉死（含「校验文件被移除
⇒ 安装必须失败」用例），并由 CI 每天对比线上部署版是否与本仓一致。

---

## 五、我们自己也在跑这个验证

`.github/workflows/verify-release.yml` 每天在一台干净 runner 上**以外部人视角**跑一遍：
不 checkout 本仓、不用任何仓库密钥，匿名下载产物后用上面**一模一样的命令**验签，
并附带一个负向用例（篡改文件后验签必须失败）。

这条 CI 变红 = 我们的公开验签承诺当下是假的。
