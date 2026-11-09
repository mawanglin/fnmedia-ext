#!/usr/bin/env python3
"""native-only fork 的版本/发布标识（与 fnos_music_ext 的 native-only 同一规则）。

VERSION 文件 = 上游基线 + 自有小版本：x.y.z-N（N≥1）；RELEASE_CHANNEL 固定为 fork。
对外标识 x.y.z-nN，tag 为 vx.y.z-nN（既同步上游基线，又不与上游 tag 冲突）。
上游基线升级后 N 回到 1。

用法:
    release_version.py [--format version|display_version|ui_version|tag|channel]
                       [--tag vX.Y.Z-nN] [--github-output FILE]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_VERSION = re.compile(r"(?P<base>(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))-(?P<rev>[1-9]\d*)")


def read_first_line(path: Path) -> str:
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            return line
    return ""


def release_info(version: str, channel: str) -> dict[str, str]:
    if channel != "fork":
        raise ValueError(f"RELEASE_CHANNEL 必须是 fork，当前为 {channel!r}")
    m = _VERSION.fullmatch(version.strip())
    if not m:
        raise ValueError(f"VERSION 必须为 x.y.z-N（N≥1，N 为自有小版本），当前为 {version!r}")
    display = f"{m['base']}-n{int(m['rev'])}"
    return {
        "version": version.strip(),
        "display_version": display,
        "ui_version": f"v{display}",
        "tag": f"v{display}",
        "channel": channel,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=ROOT)
    ap.add_argument("--format", default="display_version",
                    choices=("version", "display_version", "ui_version", "tag", "channel"))
    ap.add_argument("--tag", help="要求该 tag 与 VERSION/RELEASE_CHANNEL 推导出的一致")
    ap.add_argument("--github-output", type=Path)
    args = ap.parse_args()
    try:
        info = release_info(read_first_line(args.root / "VERSION"),
                            read_first_line(args.root / "RELEASE_CHANNEL"))
        if args.tag is not None and args.tag != info["tag"]:
            raise ValueError(f"tag {args.tag} 与 VERSION {info['version']} 对应的 {info['tag']} 不一致")
    except (OSError, ValueError) as exc:
        print(exc, file=sys.stderr)
        return 1
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as out:
            out.writelines(f"{k}={v}\n" for k, v in info.items())
    print(info[args.format])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
