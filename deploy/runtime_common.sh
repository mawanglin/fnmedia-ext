#!/usr/bin/env bash
# 内置运行时（native-only fpk）公共函数；被 source，无副作用。
#
# fpk 自带 Python / 依赖 / ffprobe 于 <ROOT>/runtime（由 packaging/fpk/fetch_runtime.py 生成，
# 以 runtime/BUNDLED 为标记）。存在标记即“内置模式”：只用包内文件，安装时不联网、
# 不调用 apt/pip，不改动系统。源码安装（无标记）仍走 bootstrap_deps.sh 的原有流程。

fnmedia_runtime_dir() {
  printf '%s' "${FNMEDIA_RUNTIME_DIR:-${ROOT:-.}/runtime}"
}

fnmedia_bundled() {
  [ -f "$(fnmedia_runtime_dir)/BUNDLED" ]
}

# 用内置 Python 离线创建 venv，并把内置依赖目录挂进去（不需要 pip）：
#   bundled_make_venv <venv 目录>
# venv 不含用户数据，路径或来源变化（应用换卷、升级换运行时）时直接重建。
bundled_make_venv() {
  local venv="$1"
  local rt py site scripts home_line stamp purelib
  rt="$(fnmedia_runtime_dir)"
  py="${rt}/python/bin/python3"
  site="${rt}/site"
  scripts="${rt}/scripts"
  [ -x "${py}" ] || { echo "内置 Python 缺失: ${py}" >&2; return 1; }
  [ -d "${site}" ] || { echo "内置依赖目录缺失: ${site}" >&2; return 1; }
  home_line="home = ${rt}/python/bin"
  stamp="${venv}/.fnmedia-bundled"
  if [ ! -x "${venv}/bin/python" ] \
     || ! grep -qxF "${home_line}" "${venv}/pyvenv.cfg" 2>/dev/null \
     || [ "$(cat "${stamp}" 2>/dev/null)" != "${site}" ]; then
    rm -rf "${venv}"
    "${py}" -m venv --without-pip "${venv}" || return 1
  fi
  purelib="$("${venv}/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')" || return 1
  mkdir -p "${purelib}"
  # 经 addsitedir 挂载：依赖里自带的 .pth 也会被处理
  printf 'import site; site.addsitedir(%s)\n' \
    "$("${py}" -c 'import sys; print(repr(sys.argv[1]))' "${site}")" \
    > "${purelib}/fnmedia_bundled.pth"
  if [ -d "${scripts}" ]; then
    cp -af "${scripts}/." "${venv}/bin/" || return 1
  fi
  printf '%s\n' "${site}" > "${stamp}"
}
