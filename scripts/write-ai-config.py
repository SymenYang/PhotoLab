"""Build-time configuration. Local builds retain existing model paths.
Distribution builds are explicit and contain no developer filesystem paths.
"""
import argparse
import json
from pathlib import Path

def configuration(root, app, distribution=False):
    if distribution:
        return {}
    result = {key: str(path) for key, path in {
        'python': root / '.ai-runtime/bin/python', 'model': root / '.ai-model',
        'qwenModel': root / '.ai-model-qwen', 'qwenCoreML': root / '.ai-model-qwen-coreml',
        'redlamp': app / 'Contents/Resources/ColorTools/Helpers/redlamp',
        'nativeRedlamp': app / 'Contents/Frameworks/PhotoLabRedlamp.framework/PhotoLabRedlamp',
        'jarvisPrompt': app / 'Contents/Resources/AI/jarvis_prompt.py',
        'colorWorker': app / 'Contents/Resources/AI/color_worker.py',
    }.items()}
    local = root / '.local/ai-config.json'
    if local.exists():
        overrides = json.loads(local.read_text())
        if not isinstance(overrides, dict) or not all(isinstance(v, str) for v in overrides.values()):
            raise ValueError('Local AI configuration must be an object of path strings')
        result.update(overrides)
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--distribution', action='store_true')
    args = parser.parse_args()
    target = args.app.resolve() / 'Contents/Resources/AI/config.json'
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix('.tmp')
    temporary.write_text(json.dumps(configuration(args.project.resolve(), args.app.resolve(), args.distribution), indent=2))
    temporary.replace(target)
