#!/usr/bin/env bash
# fnmedia-ext FPK 打包（native-only：每个架构各出一个 fpk，内置运行时）
# 组装骨架 + 项目主体 + 内置 Python/依赖/ffprobe（见 fetch_runtime.py）→ fnpack build
# → dist/fnmedia-ext-<版本>-<x86|arm>.fpk（含 .sha256）。
# NAS 上安装时不联网、不调用 apt/pip、不改动系统。
#
# 用法:
#   packaging/fpk/build.sh                     # x86 + arm 都打（fnpack 缺失时自动下载）
#   packaging/fpk/build.sh --arch x86|arm|all  # 指定架构
#   packaging/fpk/build.sh --stage-only DIR    # 只组装不打包（结构测试用，默认 x86 且不拉运行时）
#   packaging/fpk/build.sh --no-runtime        # 不下载内置运行时（仅结构测试）
#   packaging/fpk/build.sh --fnpack /path/fnpack --out dist
# 环境变量: FNPACK_VERSION（默认 1.2.3）、FNMEDIA_BUILD_CACHE（运行时下载缓存目录）
set -euo pipefail

FPK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${FPK_DIR}/../.." && pwd)"
VERSION="$(python3 "${REPO_ROOT}/scripts/release_version.py" --format version)" \
  || { echo "ERROR: VERSION / RELEASE_CHANNEL 不合法" >&2; exit 1; }

FNPACK_BIN="${FNPACK:-}"; STAGE=""; STAGE_ONLY=0; ARCH_ARG=""; NO_RUNTIME=0
OUT_DIR="${REPO_ROOT}/dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --stage-only) [ $# -ge 2 ] || { echo "用法: $0 --stage-only <dir>" >&2; exit 1; }
                  STAGE_ONLY=1; STAGE="$2"; shift 2 ;;
    --arch)       [ $# -ge 2 ] || { echo "用法: $0 --arch x86|arm|all" >&2; exit 1; }
                  ARCH_ARG="$2"; shift 2 ;;
    --no-runtime) NO_RUNTIME=1; shift ;;
    --fnpack)     [ $# -ge 2 ] || { echo "用法: $0 --fnpack <path>" >&2; exit 1; }
                  FNPACK_BIN="$2"; shift 2 ;;
    --out)        [ $# -ge 2 ] || { echo "用法: $0 --out <dir>" >&2; exit 1; }
                  OUT_DIR="$2"; shift 2 ;;
    -h|--help)    sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

# 架构：--stage-only 只组装一个架构（默认 x86），且默认不下载内置运行时。
if [ "${STAGE_ONLY}" -eq 1 ]; then
  ARCHES="${ARCH_ARG:-x86}"
  [ "${FNMEDIA_STAGE_RUNTIME:-0}" = "1" ] || NO_RUNTIME=1
else
  ARCHES="${ARCH_ARG:-all}"
fi
[ "${ARCHES}" = "all" ] && ARCHES="x86 arm"
for _a in ${ARCHES}; do
  case "${_a}" in x86|arm) ;; *) echo "ERROR: --arch 只能是 x86、arm 或 all（收到: ${_a}）" >&2; exit 1 ;; esac
done
if [ "${STAGE_ONLY}" -eq 1 ] && [ "$(echo ${ARCHES} | wc -w)" -ne 1 ]; then
  echo "ERROR: --stage-only 只能组装单个架构" >&2; exit 1
fi
command -v rsync >/dev/null 2>&1 || { echo "ERROR: 需要 rsync" >&2; exit 1; }

RUNTIME_CACHE="${FNMEDIA_BUILD_CACHE:-${FPK_DIR}/.build/runtime-cache}"
mkdir -p "${RUNTIME_CACHE}"

stage_arch() {
  local ARCH="$1"
  [ "${STAGE_ONLY}" -eq 1 ] || STAGE="${FPK_DIR}/.build/fpk-${ARCH}"
  rm -rf "${STAGE}"
  mkdir -p "${STAGE}/app/repo" "${STAGE}/app/ui"

  # 仓库主体：不含开发文件、测试、离线 wheelhouse（依赖改由内置运行时提供）、本地秘密与私有运行态
  rsync -a --delete \
    --exclude='.venv/' --exclude='__pycache__/' --exclude='*.pyc' \
    --exclude='.git/' --exclude='.git*' --exclude='.github/' --exclude='.agents/' \
    --exclude='dist/' --exclude='logs/' --exclude='state/' --exclude='.tools/' \
    --exclude='packaging/' --exclude='tests/' --exclude='wheelhouse/' --exclude='/runtime/' \
    --exclude='.release/' --exclude='*.fpk' --exclude='*.apk' --exclude='.DS_Store' \
    --exclude='/AGENTS.md' --exclude='/CLAUDE.md' \
    --exclude='/proxy/assets/guard/' --exclude='/proxy/assets/spiders/' \
    --exclude='/FORUM_POST*.md' --exclude='/FORUM_RELEASE_*.md' --exclude='/RELEASING.md' \
    "${REPO_ROOT}/" "${STAGE}/app/repo/"
  rm -f "${STAGE}/app/repo/proxy/"*local.json

  # 内置运行时（Python/依赖/ffprobe）：安装时无需联网、不调用 apt/pip
  if [ "${NO_RUNTIME}" -eq 1 ]; then
    echo "[WARN] 跳过内置运行时（--no-runtime）：该包只用于结构检查，不能安装使用"
  else
    python3 "${FPK_DIR}/fetch_runtime.py" --arch "${ARCH}" --cache "${RUNTIME_CACHE}" \
      --out "${STAGE}/app/repo/runtime"
  fi

  # manifest 版本、包内 VERSION、文件名一致保留数字 -N（飞牛对同版本号不会覆盖安装）
  sed -e "s/@VERSION@/${VERSION}/" -e "s/@PLATFORM@/${ARCH}/" "${FPK_DIR}/manifest.in" > "${STAGE}/manifest"
  cp "${FPK_DIR}/ICON.PNG" "${FPK_DIR}/ICON_256.PNG" "${STAGE}/"
  cp -a "${FPK_DIR}/app/ui/." "${STAGE}/app/ui/"
  cp -a "${FPK_DIR}/cmd" "${STAGE}/cmd"
  cp -a "${FPK_DIR}/config" "${STAGE}/config"
  [ -d "${FPK_DIR}/wizard" ] && cp -a "${FPK_DIR}/wizard" "${STAGE}/wizard"
  chmod +x "${STAGE}"/cmd/*

  # 内置运行时可执行文件显式 0755，目录对 group/other 可读（不依赖构建机 umask）
  if [ -d "${STAGE}/app/repo/runtime" ]; then
    find "${STAGE}/app/repo/runtime/python/bin" "${STAGE}/app/repo/runtime/ffmpeg" \
      "${STAGE}/app/repo/runtime/scripts" -maxdepth 1 -type f -exec chmod 0755 {} +
    chmod -R u+rwX,go+rX "${STAGE}/app/repo/runtime"
  fi
  echo "[fpk] 组装完成: ${STAGE} (version=${VERSION}, arch=${ARCH})"
}

if [ "${STAGE_ONLY}" -eq 1 ]; then
  for ARCH in ${ARCHES}; do stage_arch "${ARCH}"; done
  exit 0
fi

if [ -z "${FNPACK_BIN}" ]; then
  if command -v fnpack >/dev/null 2>&1; then FNPACK_BIN="$(command -v fnpack)"; else
    case "$(uname -m)" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) echo "不支持的架构" >&2; exit 1;; esac
    FNPACK_BIN="${REPO_ROOT}/.tools/fnpack"; mkdir -p "$(dirname "${FNPACK_BIN}")"
    if [ ! -x "${FNPACK_BIN}" ]; then
      curl -fsSL -o "${FNPACK_BIN}" "https://static2.fnnas.com/fnpack/fnpack-${FNPACK_VERSION:-1.2.3}-linux-${A}"
    fi
    chmod +x "${FNPACK_BIN}"
  fi
fi

mkdir -p "${OUT_DIR}"
for ARCH in ${ARCHES}; do
  stage_arch "${ARCH}"
  WORK="$(mktemp -d)"
  if ! ( cd "${WORK}" && "${FNPACK_BIN}" build --directory "${STAGE}" ); then
    rm -rf "${WORK}"; echo "ERROR: fnpack build 失败 (${ARCH})" >&2; exit 1
  fi
  BUILT="$(find "${WORK}" "${STAGE}" -maxdepth 2 -name '*.fpk' -print -quit 2>/dev/null || true)"
  [ -n "${BUILT}" ] || { rm -rf "${WORK}"; echo "ERROR: fnpack 未产出 .fpk (${ARCH})" >&2; exit 1; }
  FINAL="${OUT_DIR}/fnmedia-ext-${VERSION}-${ARCH}.fpk"
  mv "${BUILT}" "${FINAL}"; rm -rf "${WORK}"
  ( cd "$(dirname "${FINAL}")" && sha256sum "$(basename "${FINAL}")" > "$(basename "${FINAL}").sha256" )
  echo "[fpk] 打包完成: ${FINAL} ($(( $(stat -c %s "${FINAL}") / 1048576 )) MB)"
done
