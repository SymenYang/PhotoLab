"""Package the pinned upstream CLI and its transitive frameworks, no model weights."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile
import argparse

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True, help='Path to the upstream Redlamp.app')
source = parser.parse_args().app.resolve() / 'Contents'
archive = root / 'Vendor/Redlamp/vendor/color-tools.tar.gz'
# Only run explicitly when refreshing the vendored upstream binary dependency.
helper = source / 'Helpers/redlamp'
frameworks = set()
def visit(binary):
    dependencies = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    for name in re.findall(r'@rpath/([^/]+)\.framework/', dependencies):
        if name in frameworks:
            continue
        frameworks.add(name)
        visit(source / 'Frameworks' / (name + '.framework') / name)
visit(helper)
with tarfile.open(archive, 'w:gz') as output:
    output.add(helper, arcname='Helpers/redlamp')
    for notice in sorted((source / 'Resources').glob('*.txt')):
        output.add(notice, arcname='Licenses/' + notice.name)
    for name in sorted(frameworks):
        output.add(source / 'Frameworks' / (name + '.framework'), arcname='Frameworks/' + name + '.framework')
metadata = dict(repository='https://github.com/pdcgomes/redlamp', tag='v0.3.3-alpha',
                source='https://github.com/pdcgomes/redlamp/tree/v0.3.3-alpha',
                license='MPL-2.0; see ../LICENSE', sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                frameworks=sorted(frameworks), purpose='Unmodified CLI used only for XMP recipe import; no model weights.')
archive.with_suffix('.json').write_text(json.dumps(metadata, indent=2) + '\n')
print(archive, archive.stat().st_size)
