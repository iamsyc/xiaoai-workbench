#!/usr/bin/env python3
"""Build the native app and bundle its non-system dynamic dependencies."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)

def run(*arguments):
    return subprocess.check_output(arguments, text=True).strip()

identity = os.environ.get("XIAOAI_SIGN_IDENTITY")
if not identity:
    identities = re.findall(r'\) ([0-9A-F]{40}) "(?:Apple Development|Developer ID Application):', run("security", "find-identity", "-v", "-p", "codesigning"))
    if not identities:
        raise SystemExit("A valid Apple code-signing identity is required for stable macOS local-network permission. Set XIAOAI_SIGN_IDENTITY.")
    identity = identities[0]
subprocess.run(["swift", "build", "-c", "release"], check=True)
binary_directory = Path(run("swift", "build", "-c", "release", "--show-bin-path"))
app = ROOT / "dist" / "XiaoaiWorkbench.app"
if app.exists():
    shutil.rmtree(app)
contents = app / "Contents"
macos = contents / "MacOS"
tools = contents / "Resources" / "Tools"
frameworks = contents / "Frameworks"
licenses = contents / "Resources" / "Licenses"
for directory in (macos, tools, frameworks, licenses):
    directory.mkdir(parents=True, exist_ok=True)
executable = macos / "XiaoaiWorkbench"
shutil.copy2(binary_directory / "XiaoaiWorkbench", executable)
bluetooth_proxy = macos / "XiaoaiBluetoothProxy"
shutil.copy2(binary_directory / "XiaoaiBluetoothProxy", bluetooth_proxy)
for name in ("unsquashfs", "mksquashfs"):
    source = shutil.which(name)
    if not source:
        raise SystemExit(f"Missing build dependency: {name}; install Homebrew squashfs")
    shutil.copy2(source, tools / name)

with (contents / "Info.plist").open("wb") as stream:
    plistlib.dump({
        "CFBundleExecutable": "XiaoaiWorkbench",
        "CFBundleIdentifier": "local.xiaoai.workbench",
        "CFBundleName": "小爱工作台",
        "CFBundleDisplayName": "小爱工作台",
        "CFBundleIconFile": "AppIcon",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.2.0",
        "CFBundleVersion": "2",
        "LSMinimumSystemVersion": "27.0",
        "NSHighResolutionCapable": True,
        "NSLocalNetworkUsageDescription": "通过局域网 SSH 核对你的 LX06 音箱的 root 权限和重启结果。",
        "NSBluetoothAlwaysUsageDescription": "通过已配对音箱的蓝牙 RFCOMM 通道连接 SSH。",
    }, stream)

iconset = ROOT / ".cache" / "AppIcon.iconset"
subprocess.run(["swift", str(ROOT / "scripts" / "Icon.swift"), str(iconset)], check=True)
subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(contents / "Resources" / "AppIcon.icns")], check=True)

copied = {}
def bundle_dependencies(binary):
    for line in run("otool", "-L", str(binary)).splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if not dependency.startswith("/opt/homebrew/"):
            continue
        source = Path(dependency)
        target = frameworks / source.name
        if dependency not in copied:
            copied[dependency] = target
            shutil.copy2(source.resolve(), target)
            target.chmod(0o755)
            subprocess.run(["install_name_tool", "-id", f"@rpath/{target.name}", str(target)], check=True)
            bundle_dependencies(target)
        relative = os.path.relpath(target, binary.parent)
        subprocess.run(["install_name_tool", "-change", dependency, f"@loader_path/{relative}", str(binary)], check=True)

for binary in (executable, tools / "unsquashfs", tools / "mksquashfs"):
    bundle_dependencies(binary)

for formula in ("libusb", "squashfs", "lzo", "lz4", "xz", "zstd"):
    prefix = Path(run("brew", "--prefix", formula)).resolve()
    destination = licenses / formula
    destination.mkdir(exist_ok=True)
    for file in prefix.iterdir():
        if file.is_file() and file.name.startswith(("COPYING", "LICENSE", "AUTHORS")):
            shutil.copy2(file, destination / file.name)
    info = json.loads(run("brew", "info", "--json=v2", formula))["formulae"][0]
    (destination / "SOURCE.json").write_text(json.dumps({
        "name": formula, "version": info["installed"][0]["version"],
        "source": info["urls"]["stable"], "license": info["license"],
    }, indent=2) + "\n")
shutil.copy2(ROOT / "THIRD_PARTY.md", contents / "Resources" / "THIRD_PARTY.md")
shutil.copytree(ROOT / "Licenses", licenses / "References")

for binary in [*frameworks.iterdir(), tools / "unsquashfs", tools / "mksquashfs", bluetooth_proxy, executable]:
    subprocess.run(["codesign", "--force", "--sign", identity, str(binary)], check=True)
subprocess.run(["codesign", "--force", "--sign", identity, str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)

manifest = {}
for file in sorted(contents.rglob("*")):
    if file.is_file():
        manifest[str(file.relative_to(app))] = hashlib.sha256(file.read_bytes()).hexdigest()
(ROOT / "dist" / "SHA256.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
print(app)
