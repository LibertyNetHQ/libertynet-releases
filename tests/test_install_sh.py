"""把 `tests/test-install-sh.sh` 接到 ln-ci 上。

# 为什么要这一层而不是直接 `.ci/run.sh`

ln-ci 判断「配方到底跑起来了没有」的**主**判据不是耗时，是日志里有没有
**运行器自己打的**执行痕迹（`ln-ci.py` 的 `RUN_EVIDENCE`）。这条设计是对的：
只认工具打的行，不认仓里代码打的，否则任何脚本只要 `echo " passed"` 就能
把判据哄过去。

而 `test-install-sh.sh` 的汇总是中文（`结果：17 通过 / 0 失败`），`custom`
那一档的痕迹词（`Compiling ` / `test result:` / ` passed` / ` failed` /
`added `）一个都不会命中 —— 于是即使 17 个用例全过、退出码 0，ln-ci 也会
判成「日志里没有任何编译/测试痕迹」而报 error。

两条路摆在面前：把那个 bash 脚本改成打英文（等于用仓里代码去迎合痕迹判据，
正是它设计上不信的那种），或者让一个**真的测试运行器**来跑它。这里选后者：
pytest 自己会打 `1 passed`，痕迹由工具产生，判据按原意成立，`RUN_EVIDENCE`
一个字都不用改。

# 它比「跑一下看退出码」多查了什么

脚本自己的退出码只是一个信号。这里**两头都查**：

* 退出码必须为 0；
* 汇总行里 `失败` 必须是 0 —— 防「退出码 0 但汇总报了失败」；
* 通过数不得少于 17 —— 防「有人把用例悄悄删掉，剩下的全过所以仍然绿」。

第三条是阳性对照的意思：这套测试覆盖的是 install.sh 的 fail-closed 完整性
校验（校验文件缺失必须拒装），**用例数本身就是资产**，静悄悄变少必须报警。
"""

import pathlib
import re
import subprocess

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / "test-install-sh.sh"

#: 2026-11-25 收口线上 install.sh（1158 行）后实测的用例数。
#: 新增用例时把这个数字一起加上去；减少必须有明确理由。
EXPECTED_MIN_CASES = 17

SUMMARY = re.compile(r"结果：(\d+)\s*通过\s*/\s*(\d+)\s*失败")


def _run():
    assert SCRIPT.is_file(), f"找不到 {SCRIPT}"
    proc = subprocess.run(
        ["bash", str(SCRIPT)],
        capture_output=True,
        text=True,
        timeout=600,
        cwd=str(HERE.parent),
    )
    return proc, (proc.stdout or "") + (proc.stderr or "")


def test_install_sh_integrity_suite():
    proc, out = _run()
    tail = out[-6000:]

    match = SUMMARY.search(out)
    assert match, (
        "在 test-install-sh.sh 的输出里找不到汇总行（期望形如"
        "「结果：N 通过 / M 失败」）。脚本可能根本没跑到结尾，"
        f"退出码 {proc.returncode}。\n--- 输出尾部 ---\n{tail}"
    )

    passed, failed = int(match.group(1)), int(match.group(2))

    assert failed == 0, (
        f"install.sh 的完整性校验回归测试有 {failed} 个用例失败。\n"
        "这套测试钉的是 fail-closed 红线：拿不到 <asset>.sha256 时**必须拒绝安装**。\n"
        "它曾经是 fail-open（只打一行 warn 就继续装），攻击者让校验文件返回 404 即可\n"
        "整段跳过完整性校验。红了就是这条红线被改回去了，不要绕过。\n"
        f"--- 输出尾部 ---\n{tail}"
    )

    assert passed >= EXPECTED_MIN_CASES, (
        f"只跑了 {passed} 个用例，少于基线 {EXPECTED_MIN_CASES} 个。\n"
        "用例全过但数量变少 = 有覆盖被悄悄删掉，这和「测试失败」一样严重。\n"
        "确实要减少用例时，连同本文件的 EXPECTED_MIN_CASES 一起改，并在提交里说明理由。\n"
        f"--- 输出尾部 ---\n{tail}"
    )

    assert proc.returncode == 0, (
        f"汇总说 {passed} 通过 / 0 失败，但退出码是 {proc.returncode}。\n"
        "两者矛盾本身就是缺陷：调用方（含 ln-ci）只看退出码。\n"
        f"--- 输出尾部 ---\n{tail}"
    )
