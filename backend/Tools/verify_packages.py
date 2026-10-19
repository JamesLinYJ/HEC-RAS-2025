"""Validate the local NuGet dependencies used by the product build."""
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

backend = Path(__file__).resolve().parents[1]
manifest = json.loads((backend / 'Dependencies/packages.json').read_text())
for entry in manifest['packages']:
    package = backend / 'Packages' / entry['file']
    if not package.is_file() or hashlib.sha256(package.read_bytes()).hexdigest() != entry['sha256']:
        raise SystemExit('Dependency package is missing or its hash differs: ' + package.name)
    with zipfile.ZipFile(package) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or archive.testzip() is not None:
            raise SystemExit('Dependency package is corrupt: ' + package.name)
        if not set(entry['requiredFiles']).issubset(names):
            raise SystemExit('Dependency package is incomplete: ' + package.name)
        nuspecs = [name for name in names if name.endswith('.nuspec')]
        if len(nuspecs) != 1:
            raise SystemExit('Dependency package identity is ambiguous: ' + package.name)
        spec = ET.fromstring(archive.read(nuspecs[0]))
        metadata = next((node for node in spec if node.tag.split('}')[-1] == 'metadata'), None)
        values = {} if metadata is None else {node.tag.split('}')[-1]: node.text for node in metadata}
        if values.get('id') != entry['id'] or values.get('version') != entry['version']:
            raise SystemExit('Dependency package identity differs: ' + package.name)
    print('Verified dependency package: ' + package.name)
