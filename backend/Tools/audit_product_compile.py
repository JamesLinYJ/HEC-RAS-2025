#!/usr/bin/env python3
"""Evaluate solution C# inputs; offline audit, never a product build input."""
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
backend = root / "backend"
solution = ET.parse(backend / "Ras.Backend.slnx")
queue = [(backend / item.attrib["Path"]).resolve() for item in solution.iter("Project")]
seen = set()
projects = []
source_inputs = set()
while queue:
    project = queue.pop(0).resolve()
    if project in seen:
        continue
    if not project.is_relative_to(root):
        raise SystemExit("A product project is outside the reviewed repository: " + str(project))
    seen.add(project)
    result = subprocess.run([
        os.environ.get("HECRAS_DOTNET", "dotnet"), "msbuild", str(project), "-nologo",
        "-p:Configuration=Release", "-p:ArtifactsPath=" + str(backend / "build/artifacts"),
        "-p:RestorePackagesPath=" + str(backend / "build/packages"),
        "-getItem:Compile,ProjectReference,EmbeddedResource,Content,None",
        "-getProperty:MSBuildAllProjects",
    ], check=True, capture_output=True, text=True)
    evaluation = json.loads(result.stdout)
    items = evaluation["Items"]
    candidates = [str(project)] + evaluation.get("Properties", {}).get("MSBuildAllProjects", "").split(";")
    # Implicit hierarchical imports are not all represented by
    # MSBuildAllProjects. Include them when enumerating the complete build configuration.
    for parent in project.parents:
        if not parent.is_relative_to(root):
            break
        for name in ("Directory.Build.props", "Directory.Build.targets", "Directory.Packages.props",
                     "NuGet.Config", "nuget.config", "global.json"):
            if (parent / name).is_file():
                candidates.append(str(parent / name))
    candidates.extend(item.get("FullPath", "") for kind in ("Compile", "EmbeddedResource", "Content", "None")
                      for item in items.get(kind, []))
    for candidate in candidates:
        if not candidate:
            continue
        path = Path(candidate)
        if path.is_absolute() and path.is_file() and path.is_relative_to(root) and not path.is_relative_to(backend / "build"):
            source_inputs.add(str(path.relative_to(root)))
    paths = [item.get("FullPath", item["Identity"]) for item in items["Compile"]]
    unexpected = [path for path in paths if any(fragment in path for fragment in (
        "/backend/Tools/", "SourceRepair", "ExportBindingRepair", ".WinUI.dll/", "/WinRT.Runtime/",
    ))]
    projects.append({"project": str(project.relative_to(root)), "compile_items": len(paths), "unexpected_tool_inputs": unexpected})
    queue.extend(Path(item["FullPath"]) for item in items["ProjectReference"])
projects.sort(key=lambda item: item["project"])
receipt = {
    "projects_checked": len(projects),
    "compile_items": sum(item["compile_items"] for item in projects),
    "unexpected_tool_inputs": [path for item in projects for path in item["unexpected_tool_inputs"]],
    "projects": projects,
}
if receipt["unexpected_tool_inputs"]:
    raise SystemExit(json.dumps(receipt["unexpected_tool_inputs"], indent=2))
target = backend / "build/product-compile-audit.json"
target.write_text(json.dumps(receipt, indent=2) + "\n")
(backend / "build/product-source-inputs.json").write_text(json.dumps({
    "scope": "Evaluated product source/project/resource inputs inside this repository; SDK and package-cache files are restored separately.",
    "files": sorted(source_inputs),
}, indent=2) + "\n")
print(json.dumps({key: value for key, value in receipt.items() if key != "projects"}))
