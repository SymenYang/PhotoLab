# PhotoLab

PhotoLab 是面向 macOS 的本地照片与视频管理、选片和编辑工具，使用 SwiftUI 构建界面，SQLite 保存图录。素材可以位于本地磁盘或已挂载的网络共享目录。

## 功能

- 递归导入目录，配对同名 RAW / JPG / HEIC，浏览元数据、缩略图与原片。
- 星级、保留/淘汰、标签、组合筛选和已保存筛选器；支持多图对比与视频播放。
- 非破坏性照片编辑、裁剪、旋转和导出；编辑结果保存为原片旁的 `.photolab` 文件。
- 本地 AI 语义检索、相似照片聚合、艺术/质量评分和 AI 调色。
- 手动调色支持白平衡、基础明暗、HSL、黑白、RGB / 通道点曲线、参数曲线、色彩分级、锐化、降噪、暗角和颗粒；AI 与手动调整共享参数，支持撤销和重做。
- RAW 的 AI 输入和编辑预览按所需尺寸显影；完成编辑或导出时才生成全分辨率结果。RGB 白平衡以 5500 K / 色调 0 为相对中性参考。
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
| `Resources/` | 图标源文件、边框纹理、贴纸、品牌标识与来源说明 |
| `Tests/` | Swift / Python 测试与隔离下载模拟 |
| `scripts/` | 构建、打包和测试入口 |
| `Package.swift` | Swift Package 定义 |

`research/`、`checkpoints/`、`test_photo/`、`.local/`、模型目录和构建产物均不入 Git。源码和常规构建不依赖本项目的 `research/`；第三方源码中保留的上游研究路径仅出现在注释和模型说明中。真实模型/媒体集成测试需要自行提供本地环境与样本。忽略规则也覆盖常见模型权重、RAW／照片／视频、私钥与签名证书；应用图标和已注明来源的纸纹作为项目资源显式保留。新增应用位图素材时需审查用途与授权，并更新 `.gitignore` 的白名单。图库默认存放在 `~/Library/Application Support/PhotoLab/`，不随源码分发。

第三方依赖中保留 `Sam3AppPrompts.bin`（约 16 KB）及其许可，它是上游预计算的 Snow 文本提示特征，供 SAM3 分割代码读取，不是模型权重或用户照片。`Vendor/Redlamp/vendor/` 中的 LibRaw 源码归档、ColorTools 运行依赖归档及 Metal 库均为构建所需资源；模型清单 JSON 仅记录下载信息。

## 测试

无需真实模型的下载模拟：

```sh
zsh scripts/test-model-downloads.sh
```

模拟使用独立临时目录、合成文件和本机 HTTP 服务，不下载真实权重。测试范围见 [模拟测试说明](Tests/ModelDownloads/README.md)。其他测试入口为 `scripts/test-*.sh`，部分依赖本地 AI Python 环境或 `test_photo/` 媒体。

外部验收样本通过参数提供：艺术评分使用 `PHOTOLAB_TEST_IMAGE`；Redlamp 使用 `PHOTOLAB_REDLAMP_FIXTURES`（含 768×576 的 `before.jpg` 和 `full.redrecipe`）；HEIC 参考图使用 `PHOTOLAB_HEIC_REFERENCES`；调色实验 JSON 使用 `PHOTOLAB_COLOR_FIXTURES`。性能报告默认写入忽略的 `build/reports/`。

调色控件和 RAW 流程回归：`zsh scripts/test-color-controls.sh`（需要 Metal；推理使用固定测试响应）。加 `--snapshot` 输出面板截图；加 `--real-ai` 使用已配置的本地 JarvisArt 对测试 3FR 执行真实推理。

编辑器内的调色、裁剪、边框和贴纸修改先保留在内存草稿中，点击「完成」后才写入 `.photolab` 并触发 embedding／评分刷新；关闭会放弃本次修改，保留打开前已保存的版本。未修改就完成、撤销回原状态或直接关闭不会重写文件或触发分析。切换照片或 RAW／直出输入时，可选择保存、放弃或继续编辑。

### Focus 全屏观赏

按 F 打开观赏时先读取与当前编辑版本、旋转匹配的共享浏览缓存，再按屏幕像素尺寸加载 HDR 原图或已编辑预览；不再默认解码整张全尺寸照片。缩放／捏合时按可见像素需求补充更高清晰度，替换预览时保留视口。近期 HDR 原图预览有独立的有界内存缓存；RAW 在显影前设置解码比例。查看原图跳过已编辑缓存，原片离线时仍可保留已显示的缓存并提示错误，切换或退出后忽略过期结果。`zsh scripts/test-focus-viewing.sh` 验证渐进显示、缩放请求、取消、HDR、已编辑预览，并对本地 HEIC/JPG/RAW 实测解码耗时。

### 边框与贴纸

边框设置中的「照片阴影」开关可在照片周围添加柔和投影，默认关闭；阴影随照片尺寸缩放，支持保存、预设、撤销和导出，不改变照片区域的颜色或画布尺寸。新文字贴纸和信息预设中的机型、镜头、参数文字默认使用 Helvetica；字形菜单仍提供系统、衬线和手写字体，已有贴纸保留原字体选择。

照片编辑器的「边框贴纸」将边框与内容分开：边框仅负责纯色、棉纸、即影相纸或胶片片边，以及颜色、边距、下方留白、画布比例和纹理。左侧信息／两栏信息／签名预设生成独立的文字与 Logo 贴纸，不改变边框；生成后每项都能移动、缩放、旋转、改内容或删除。文字可绑定相机、镜头、拍摄参数、日期，直接输入内容会变为自定义文字。旧版信息边框在打开和渲染时转换为贴纸，保留原画布尺寸、底色和字段开关；打开不会改写原编辑文件。

贴纸栏分为「品牌 Logo／默认贴纸／导入贴纸」。品牌栏含 13 个主流品牌、哈苏 H 符号和徕卡独立字标，共 45 个原色／黑色／白色 SVG 版本。标识背景透明；尼康黄色方底已移除，徕卡原色保留圆形徽章，黑白版本使用透明字标。哈苏 H 符号依照官方 Phocus 透明图形资源转绘为矢量，来源记录注明它不是官方发布的 SVG。自动品牌贴纸根据每张照片的 EXIF Make / Model 匹配，Make 优先且不从镜头名称识别品牌；未知品牌留空，可改为指定 Logo。信息预设、批量套用和收藏保留这些动态绑定，文字改写后保留用户自定义内容。素材来源、处理过程、版权状态和 SHA-256 见 `Resources/Decorations/CREDITS.txt`、`manifest.json` 与 `Brands/*.source.json`。

支持导入 PNG、静态 SVG，以及可编辑的文字贴纸；提供 12 个原创矢量素材。画布中拖动贴纸，选中后拖动右下角手柄等比缩放、顶部圆柄旋转；一次拖动对应一次撤销。面板也可设置大小、旋转、透明度、文字字体与颜色、显示／隐藏和层级；支持复制、删除、撤销／重做。导入的素材收藏到本机素材库，也会嵌入 `.photolab` 编辑文件，原 PNG/SVG 移动后仍可重开和导出。PNG 单张最多 8 MB / 3200 万像素；SVG 最多 2 MB，保留矢量，支持基本形状、路径、文字、渐变和本地引用，拒绝脚本、外链、动画、嵌入图片和 HTML。每张照片最多 48 个贴纸、24 MB 素材。

可收藏整套预设，并将当前装饰显式保存到进入编辑器前在网格中多选的其他照片；批量保存保留各张照片的调色和裁剪，替换原有装饰，仅刷新成功保存且有变化的照片。当前照片仍点击「完成」保存，关闭当前编辑不撤销已经执行的批量保存。装饰在照片渲染后合成；拖动、换框不会重跑 RAW 调色，已有有效全尺寸照片缓存可在保存装饰时复用。缩略图、观赏和导出采用同一个装饰渲染器；当前带装饰的导出为 SDR，原始文件导出仍保持原文件。

内置纸纹来自 [ambientCG Paper 001](https://ambientcg.com/view?id=Paper001)，CC0 1.0；12 个内置贴纸 SVG 为 PhotoLab 原创并按 CC0 提供（品牌 Logo 另见各自来源说明）。来源、授权与 SHA-256 见 `Resources/Decorations/manifest.json` 和 `CREDITS.txt`，打包时随应用附带。使用系统字体，无需另装字体。执行 `zsh scripts/test-decorations.sh` 验证模板、旋转、PNG/SVG/文字、旧编辑文件、素材内嵌、缓存、导出及撤销；测试同时检查 45 个标识的透明度和黑白像素，生成 `build/decoration-preview.png`、`build/camera-logo-preview.png` 与 `build/logo-variants-preview.png` 供视觉检查。
