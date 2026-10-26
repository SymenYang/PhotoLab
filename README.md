# PhotoLab

PhotoLab 是面向 macOS 的本地照片与视频管理、选片和编辑工具，使用 SwiftUI 构建界面，SQLite 保存图录。素材可以位于本地磁盘或已挂载的网络共享目录。

## 功能

- 递归导入目录，配对同名 RAW / JPG / HEIC，浏览元数据、缩略图与原片。
- 星级、保留/淘汰、标签、组合筛选和已保存筛选器；支持多图对比与视频播放。
- 非破坏性照片编辑、裁剪、旋转和导出；编辑结果保存为原片旁的 `.photolab` 文件。
- 本地 AI 语义检索、相似照片聚合、艺术/质量评分和 AI 调色。
- 模型按需下载，下载前展示来源及许可并要求确认；提供进度、取消和失败重试。
- 本机缓存、后台任务队列与扫描续跑；推理在本机执行。

## 构建与运行

当前完整 App 打包面向 Apple Silicon、macOS 26.3 及以上，需要兼容的 Xcode Command Line Tools 和 Python 3。原生调色依赖及其固定版本归档包含在 `Vendor/Redlamp/` 中；构建不需要预先下载 AI 模型。

```sh
zsh scripts/build-app.sh
open build/PhotoLab.app
```

首次使用可在“管理 / 下载 AI 模型”中安装所需模型。开发者已有的模型环境可通过 `.local/ai-config.json` 配置，例如：

```json
{
  "python": "/absolute/path/to/embedding-env/bin/python",
  "model": "/absolute/path/to/siglip-model",
  "artPython": "/absolute/path/to/scoring-env/bin/python",
  "artModel": "/absolute/path/to/q-realign-model"
}
```

该文件只用于本地构建，不入 Git；支持的其他路径键为 `qwenModel`、`qwenCoreML` 和 `jarvisModel`。原有模型无需移动或重新下载。

分发包使用独立命令和文件名，不包含本地模型配置，不覆盖本地 App：

```sh
zsh scripts/build-distribution.sh
# 输出 build/PhotoLab-Distribution.app
```

当前脚本使用本机临时签名，正式发布仍需自行安排开发者签名与公证。模型协议独立于应用代码，尤其 JarvisArt 有非商业、非生产用途限制；详见 [模型分发说明](AI/MODEL_DISTRIBUTION.md) 和 `AI/licenses/`。

## 项目结构

| 目录 / 文件 | 用途 |
| --- | --- |
| `Sources/PhotoLab/` | SwiftUI 界面、图录、媒体浏览与编辑、后台任务及模型管理 |
| `Sources/CSQLite/` | SQLite 系统库桥接 |
| `Native/PhotoLabRedlamp/` | 原生调色引擎桥接 |
| `AI/` | Python 推理进程、模型安装器、模型清单和许可 |
| `Vendor/Redlamp/` | 固定版本第三方源码、构建依赖及许可 |
| `Resources/` | 图标源文件与设计说明 |
| `Tests/` | Swift / Python 测试与隔离下载模拟 |
| `scripts/` | 构建、打包和测试入口 |
| `Package.swift` | Swift Package 定义 |
| `REQUIREMENTS.md` | 功能需求与验收范围 |

`research/`、`checkpoints/`、`test_photo/`、`.local/`、模型目录和构建产物均不入 Git。源码和常规构建不依赖本项目的 `research/`；第三方源码中保留的上游研究路径仅出现在注释和模型说明中。真实模型/媒体集成测试需要自行提供本地环境与样本。图库默认存放在 `~/Library/Application Support/PhotoLab/`，不随源码分发。

## 测试

无需真实模型的下载模拟：

```sh
zsh scripts/test-model-downloads.sh
```

模拟使用独立临时目录、合成文件和本机 HTTP 服务，不下载真实权重。测试范围见 [模拟测试说明](Tests/ModelDownloads/README.md)。其他测试入口为 `scripts/test-*.sh`，部分依赖本地 AI Python 环境或 `test_photo/` 媒体。

外部验收样本通过参数提供：艺术评分使用 `PHOTOLAB_TEST_IMAGE`；Redlamp 使用 `PHOTOLAB_REDLAMP_FIXTURES`（含 768×576 的 `before.jpg` 和 `full.redrecipe`）；HEIC 参考图使用 `PHOTOLAB_HEIC_REFERENCES`；调色实验 JSON 使用 `PHOTOLAB_COLOR_FIXTURES`。性能报告默认写入忽略的 `build/reports/`。
