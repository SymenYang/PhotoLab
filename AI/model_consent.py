"""Interactive consent for the developer-only download entry points."""
import json
from pathlib import Path

def confirm(model_id):
    root = Path(__file__).resolve().parent
    model = next(m for m in json.loads((root / 'models.json').read_text()) if m['id'] == model_id)
    print(f"{model['repo']} @ {model['revision']}\n{model['notice']}\n{model['licenseURL']}")
    print('第三方模型不是 PhotoLab 自有或出售的模型，PhotoLab 的开源许可不替代模型原始许可证。')
    print((root / 'licenses' / model['license']).read_text())
    try:
        accepted = input('已阅读并同意原协议？输入 AGREE 继续下载：') == 'AGREE'
    except EOFError:
        accepted = False
    if not accepted:
        raise SystemExit('未确认，未下载模型。请在 App 的 AI 模型管理中安装，或交互运行此脚本。')
