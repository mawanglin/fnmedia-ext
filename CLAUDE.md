# fnmedia-ext · native-only 分支（fork）规矩

本仓库 `github_2008` = `mawanglin/fnmedia-ext`（fork），`upstream` = `yujian0815/fnmedia-ext`（官方，依赖系统 Python/pip 的单一 fpk）。
**同时遵守 `AGENTS.md`（播放底线 v0.2.42，最高优先级）；本文件只补充 fork 的分支、版本与打包规矩。**

## 铁律
- **作者信息一律用 `Cob`，不要用 `mawanglin`**：manifest 的 maintainer、关于页、README、提交的 author/committer（git config 已是 `Cob <Cob@88.com>`，提交时不要用 `-c user.name=` 覆盖）。`github.com/mawanglin/...` 是账号路径，仅作为 URL 保留。
- 定制改动（内置运行时、不动系统）只在 `native-only` 分支，**永远不合并进 `main`**；用户主动要求合并时也必须二次确认。
- `main` 只用来同步上游：`git fetch upstream && git checkout main && git merge --ff-only upstream/main`，然后把 `native-only` rebase / merge 到最新 `main` 上。
- **永远不要向上游（yujian0815）提 PR。**
- **普通迭代不得自动发版；发版（推 tag）前必须得到用户明确确认**（沿用 `AGENTS.md`）。

## 版本与发布
- `VERSION` = 上游基线 + 自有小版本：`x.y.z-N`（N≥1），`RELEASE_CHANNEL` 固定 `fork`；对外 `x.y.z-nN`，tag `vx.y.z-nN`。上游基线升级后 N 回到 1。推导与校验见 `scripts/release_version.py`。
- **只要改了任何会进包的内容并重新构建，就必须递增 N**：`VERSION` 与 `CHANGELOG.md` 的 `## [x.y.z-nN]` 标题两处同步（飞牛对相同版本号不会覆盖安装；试构建也算）。
- 发布：推 `native-only` 后，在其上打 tag `vx.y.z-nN` 并推送，触发 `.github/workflows/release.yml`：构建 x86、arm 两个 fpk 并创建 GitHub Release（只发 GitHub，不回填 `moo.json`，该文件仍是上游的索引，不要改）。
- 管理页自更新（`proxy/updater.py`）只检查本 fork 的 Release，按 CPU 架构取 `fnmedia-ext-<版本>-<x86|arm>.fpk`。

## 内置运行时（fpk 全集成，不碰系统）
- fpk 按架构各出一个：`packaging/fpk/build.sh`（默认 x86 + arm），产物 `dist/fnmedia-ext-<版本>-<x86|arm>.fpk`。
- 内置内容由 `packaging/fpk/fetch_runtime.py` 按 `packaging/fpk/runtime/runtime.json` + `requirements.lock` 生成到包内 `repo/runtime/`：Python（python-build-standalone）、依赖 wheel（解压到 `site/`）、ffprobe 静态构建（`ffmpeg/`）。所有下载校验 sha256，改版本必须同步改校验和。Python/ffprobe 的版本与校验和与 fnos_music_ext 的 native-only 同源。
- 安装脚本以 `runtime/BUNDLED` 判断内置模式（`deploy/runtime_common.sh` 的 `fnmedia_bundled` / `bundled_make_venv`）：离线用内置 Python 建 `.venv` 并挂载依赖目录，**绝不调用 apt / pip / 联网 / 系统 python3**。无标记（源码安装）保持上游行为（`bootstrap_deps.sh` 原流程）。
- systemd 单元的 PATH 把 `runtime/ffmpeg` 放最前，`quality.py`/`t4_metadata.py` 的 `which("ffprobe")` 即取到内置版本。
- 升级依赖：在内置 Python 里新建 venv 装 `requirements.txt`，`pip freeze` 覆盖 `requirements.lock`（去掉 pip 本身），再对 x86 和 arm 各跑一次 `fetch_runtime.py` 验证都能取到 wheel。只有源码包的依赖必须是纯 Python（否则构建中止）。
- 包内不含 `wheelhouse/`、`tests/`、`packaging/`（`wheelhouse/` 仅供源码安装用，留在仓库里）。

## 测试
- 打包约束：`python3 -m unittest tests.test_native_packaging -v`（release 工作流只卡这个）。
- 全量 `python3 -m unittest discover -s tests`：**上游公开树本身有 47 项失败**（引用已剥离的私有模块，如 `app.guard_native_enabled`），fork 不负责修；判断是否回归看失败数是否多于 47。
- 本地构建：`packaging/fpk/build.sh`（首次会下载 Python、ffprobe、fnpack，缓存在 `packaging/fpk/.build/`）。
