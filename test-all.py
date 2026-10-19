#!/usr/bin/env python3
"""Build both products and run source-backed C# and Swift integration suites."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
BACKEND = ROOT / 'backend'
environment = os.environ.copy()
environment.update(DOTNET_CLI_USE_MSBUILD_SERVER='0', MSBUILDDISABLENODEREUSE='1')
dotnet = environment.get('HECRAS_DOTNET') or shutil.which('dotnet')
if not dotnet:
    raise SystemExit('.NET 10 SDK is required.')

def run(command):
    subprocess.run(command, cwd=ROOT, env=environment, check=True)

run(['bash', 'build-all.sh'])
artifacts = BACKEND / 'build/tests'
run([dotnet, 'build', 'backend/Tests/Ras.Backend.Tests.csproj', '-c', 'Release', '-warnaserror',
     '-m:1', '-nr:false', '-p:UseSharedCompilation=false',
     '-p:RestoreAdditionalProjectSources=' + str(BACKEND / 'Packages'),
     '-p:RestorePackagesPath=' + str(BACKEND / 'build/packages'), '--artifacts-path', str(artifacts)])
for key in list(environment):
    if key.startswith('HECRAS_') and any(part in key for part in ['ACCEPTANCE_', 'FIXTURE_DIRECTORY']):
        environment.pop(key)
fixtures_parent = BACKEND / 'build/fixtures'
fixtures_parent.mkdir(parents=True, exist_ok=True)
fixtures = Path(tempfile.mkdtemp(prefix='source-', dir=fixtures_parent))
exports = {}
for source in (BACKEND / 'Tests').glob('*.cs'):
    for key in re.findall(r'"(HECRAS_[A-Z0-9_]+)"', source.read_text()):
        if not key.endswith(('ACCEPTANCE_DIRECTORY', 'FIXTURE_DIRECTORY', 'ACCEPTANCE_RESULT')):
            continue
        stem = key.removeprefix('HECRAS_').removesuffix('_ACCEPTANCE_DIRECTORY')
        stem = stem.removesuffix('_FIXTURE_DIRECTORY').removesuffix('_ACCEPTANCE_RESULT')
        path = fixtures / stem.lower().replace('_', '-')
        if key.endswith('ACCEPTANCE_RESULT'):
            path /= 'Stored profile.h5'
        exports[key] = str(path)
environment.update(exports)
run([dotnet, str(artifacts / 'bin/Ras.Backend.Tests/release/Ras.Backend.Tests.dll')])
for key, value in exports.items():
    if not Path(value).exists():
        raise SystemExit('A required source fixture was not produced: ' + key)
    if key.endswith('_FIXTURE_DIRECTORY'):
        key = key.removesuffix('_FIXTURE_DIRECTORY') + '_ACCEPTANCE_DIRECTORY'
    if key == 'HECRAS_GRID_ACCEPTANCE_DIRECTORY':
        key = 'HECRAS_SPATIAL_GRID_ACCEPTANCE_DIRECTORY'
    environment[key] = value
environment['HECRAS_BACKEND_TEST_EXECUTABLE'] = str(
    ROOT / 'macos/build/HEC-RAS 2025.app/Contents/Resources/Backend/HECRASBackend')
cache_id = hashlib.sha256(str(ROOT / 'macos').encode()).hexdigest()[:16]
scratch = environment.get('HECRAS_SWIFT_SCRATCH_PATH', '/private/tmp/HECRAS2025Mac-' + cache_id)
command = ['swift', 'test', '--package-path', str(ROOT / 'macos'), '--scratch-path', scratch, '-c', 'release']
exclusive = 'BackendSavedGeometryMapWorkflowTests|PlanDiagnosticNavigationTests|PlanPrecomputeAssociatedDraftCaptureTests'
before = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in fixtures.rglob('*') if path.is_file()}
try:
    run(command + ['--no-parallel', '--filter', exclusive])
    run(command + ['--skip-build', '--skip', exclusive])
finally:
    changed = [str(path) for path, digest in before.items()
               if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest]
    if changed:
        raise SystemExit('Source fixtures changed during Swift tests: ' + repr(changed))
print('C# and Swift source/integration tests passed. Fixtures remain under backend/build/fixtures.')
