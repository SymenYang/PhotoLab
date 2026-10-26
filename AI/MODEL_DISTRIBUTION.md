# 分发版模型安装

用户入口：左侧 AI 分析「管理 / 下载 AI 模型…」，或菜单「选片 → AI 模型管理…」。
首次下载前展示模型来源、固定版本、大小、许可摘要与完整许可。勾选并点击「同意并下载」后才联网；取消确认不会安装运行环境或模型。JarvisArt 单独要求确认非商业、非生产用途。修复或再次下载也需确认。

模型是第三方可选组件，不属于 PhotoLab 自有或出售的模型。PhotoLab 的代码许可不替代模型许可。声明“不售卖模型”或让用户自行下载，并不能豁免集成、使用或分发的许可义务。

| 功能 | 上游 | 许可 |
| --- | --- | --- |
| 相似照片、语义检索 | [Google SigLIP 2](https://huggingface.co/google/siglip2-base-patch16-256) | Apache 2.0 |
| 多模态检索 | [Qwen3-VL-Embedding-2B](https://huggingface.co/Qwen/Qwen3-VL-Embedding-2B) | Apache 2.0 |
| 艺术 / 质量评分 | [Q-ReAlign-Mini-0.8B](https://huggingface.co/q-future/Q-ReAlign-Mini-0.8B) | Apache 2.0 |
| AI 调色 | [JarvisArt-1208](https://huggingface.co/JarvisArt/JarvisArt-1208) | [JarvisArt Non-Commercial License v1.0](https://github.com/LYL1015/JarvisArt/blob/main/LICENSE) |

截至 2026-10-22 核对。许可证全文保存在 `AI/licenses`；固定权重版本、许可内容 SHA-256 和提示文案集中在 `AI/models.json`。修改许可文件必须同步更新清单校验值，不能静默沿用旧确认。JarvisArt 协议对模型使用和输出的条款有区别，确认框不把输出一概标为禁止商用。

JarvisArt attribution: This JarvisArt Model is licensed by Yunlong Lin under the JarvisArt Non-Commercial License. Copyright Yunlong Lin. IN NO EVENT SHALL THE LICENSOR BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE USE OF THIS MODEL.

`AI/jarvis_prompt.py` 是现有 JarvisArt 调色提示词的分发副本，受上游相应许可约束，不能当成 PhotoLab 自有许可内容。发布商业版本前必须单独审查 JarvisArt 集成与提示词分发，确认框并不构成商业授权。

## 安装与恢复

默认位置为 `~/Library/Application Support/PhotoLab/AI`（遵守 `PHOTOLAB_DATA_DIR`）。

- `python/`：固定 Python 3.13.7 Apple Silicon 独立运行时；从 Astral 官方 GitHub 发布下载并校验 SHA-256。运行时自身许可随归档保留。
- `runtimes/embedding` 和 `runtimes/scoring`：独立 venv，分别使用 `AI/requirements.lock` 和 `AI/scoring-requirements.lock`，避免 Transformers 4 / 5 冲突。依赖从 PyPI 安装，各包许可随包保留。
- `models/<id>/<revision>/`：仅从 Hugging Face 官方来源获取固定 commit 的模型文件。LFS 文件验证 SHA-256，普通 Git blob 验证 Git SHA-1。保留模型卡、LICENSE、NOTICE 和本地许可副本；不下载执行上游 Python 代码。
- `consent-<id>.json`：记录模型、版本、许可摘要校验值和用户同意时间。
- `installed.json`：全部文件校验完成后原子写入的安装完成记录。缺失该记录或确认版本不一致时不加载。
- `install.log`：当前安装阶段日志。安装窗口显示文件进度，支持取消及再次下载；模型临时文件支持 HTTP Range 续传，已完成文件会校验复用。Python 运行时归档重试会重新下载。

不自动接受 gated 仓库协议，不使用镜像。网络不可达、权限不足或磁盘空间不足时显示失败，可查看日志后重试。照片和文本推理保持离线；模型缺失不会触发隐式下载。安装完成后在当前推理结束时刷新工作进程配置，不中断正在执行的推理。

## 构建

默认 `scripts/build-app.sh` 从不入库的 `.local/ai-config.json` 读取既有本机模型路径，输出 `build/PhotoLab.app`。分发必须显式运行 `scripts/build-distribution.sh`（或设置 `PHOTOLAB_DISTRIBUTION_BUILD=1`），输出独立的 `build/PhotoLab-Distribution.app`，配置不含开发机路径，也不会注册或覆盖本地 App。既有本地模型不要求补造下载确认记录，模型管理显示“已接入本地模型”。`PHOTOLAB_AI_CONFIG` 保留给测试或显式自定义环境。

AI 调色所用上游 Redlamp CLI 与递归依赖打包在 `Vendor/Redlamp/vendor/color-tools.tar.gz`，其校验值、上游版本与源码链接在同名 `.tar.json`。构建先校验后解包至 `Resources/ColorTools`，与 PhotoLab 自建的原生引擎分离。原始第三方版权、许可文本随归档保留。该辅助程序只负责 XMP recipe 导入，不携带模型权重。维护者从对应上游发布包准备本地副本后，可显式运行 `python3 scripts/package-color-tools.py --app /path/to/Redlamp.app` 更新归档；正常构建不依赖 `research` 目录。

分发目标与现有应用一致：Apple Silicon、macOS 26.3 及以上。现有 Core ML 转换文件是可选开发优化，不进行下载；分发版 Qwen 使用原始权重的本地 PyTorch 路径。

验证：`zsh scripts/test-model-service.sh`（包含安装器单元测试），以及完整 `scripts/build-app.sh`。真实网络和大模型端到端推理还需在干净机器上做发布验收；自动化测试不会下载数十 GB 权重。

## 无真实权重的分发模拟

运行 `zsh scripts/test-model-downloads.sh` 可在新的临时目录中执行 16 项本机 HTTP / 子进程集成测试。`--ui` 保留服务器供独立模拟 App 的界面验收。不会打开现有图库、覆盖现有 App 或安装到现有模型目录。具体覆盖范围与隔离方式见 [模拟测试说明](../Tests/ModelDownloads/README.md)。
