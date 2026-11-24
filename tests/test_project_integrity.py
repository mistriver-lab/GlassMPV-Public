"""Physical integrity tests for GlassMPV iOS project."""

from pathlib import Path
import plistlib
import re
import yaml

ROOT = Path(__file__).resolve().parent.parent


def test_shaders_extracted_and_non_empty():
    shaders_dir = ROOT / "Resources" / "Shaders"
    assert shaders_dir.is_dir(), f"Missing directory: {shaders_dir}"
    glsl_files = sorted(shaders_dir.glob("*.glsl"))
    assert len(glsl_files) == 58, f"Expected 58 GLSL files, found {len(glsl_files)}"
    empty = [f.name for f in glsl_files if f.stat().st_size == 0]
    assert not empty, f"Empty GLSL files: {empty}"


def test_all_preset_shader_references_exist():
    preset_swift = (ROOT / "Sources" / "Models" / "ShaderPreset.swift").read_text(encoding="utf-8")
    referenced = set(re.findall(r'"([A-Za-z0-9_.-]+\.glsl)"', preset_swift))
    assert len(referenced) >= 15, f"Too few shader references parsed: {referenced}"

    shaders_dir = ROOT / "Resources" / "Shaders"
    missing = sorted(name for name in referenced if not (shaders_dir / name).is_file())
    assert not missing, f"Missing referenced GLSL files: {missing}"


def test_project_yml_and_github_workflow_valid():
    project_cfg = yaml.safe_load((ROOT / "project.yml").read_text(encoding="utf-8"))
    assert project_cfg["name"] == "GlassMPV"
    assert project_cfg["options"]["deploymentTarget"]["iOS"] == "26.0"
    assert project_cfg["packages"]["MPVKit"]["url"] == "https://github.com/mpvkit/MPVKit.git"
    assert project_cfg["packages"]["MPVKit"]["from"] == "1.0.0"
    target_cfg = project_cfg["targets"]["GlassMPV"]
    assert "resources" not in target_cfg
    assert "info" not in target_cfg
    assert target_cfg["settings"]["base"]["SWIFT_VERSION"] == "6.0"
    assert target_cfg["settings"]["base"]["INFOPLIST_FILE"] == "Sources/Info.plist"
    assert target_cfg["settings"]["base"]["GENERATE_INFOPLIST_FILE"] in (False, "NO")
    assert target_cfg["settings"]["base"]["ASSETCATALOG_COMPILER_APPICON_NAME"] == "AppIcon"
    shader_sources = [s for s in target_cfg["sources"] if isinstance(s, dict) and s.get("path") == "Resources/Shaders"]
    assert len(shader_sources) == 1 and shader_sources[0].get("buildPhase") == "resources"
    assert any(isinstance(s, dict) and s.get("path") == "Resources/Assets.xcassets" for s in target_cfg["sources"])

    workflow_raw = (ROOT / ".github" / "workflows" / "build-ios.yml").read_text(encoding="utf-8")
    workflow = yaml.safe_load(workflow_raw)
    steps_text = "\n".join(str(step.get("run", "")) + str(step.get("with", "")) for step in workflow["jobs"]["build-ios"]["steps"])
    assert "xcodegen generate" in steps_text
    assert "-unsigned.ipa" in steps_text
    assert "Assets.car" in steps_text
    assert "CFBundleIcons" in steps_text
    assert "SYMMROOT" not in workflow_raw


def test_version_changelog_and_app_icon():
    from PIL import Image

    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    assert version, "VERSION file must not be empty"
    project_cfg = yaml.safe_load((ROOT / "project.yml").read_text(encoding="utf-8"))
    assert project_cfg["targets"]["GlassMPV"]["settings"]["base"]["MARKETING_VERSION"] == version

    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    assert f"[v{version}]" in changelog

    icon_path = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"
    assert icon_path.is_file(), f"Missing AppIcon: {icon_path}"
    with Image.open(icon_path) as img:
        assert img.size == (1024, 1024)
        assert img.mode == "RGB"


def test_info_plist_valid_and_120hz_enabled():
    with (ROOT / "Sources" / "Info.plist").open("rb") as fh:
        plist = plistlib.load(fh)
    assert plist["CADisableMinimumFrameDurationOnPhone"] is True
    assert plist["UIFileSharingEnabled"] is True
    assert plist["LSSupportsOpeningDocumentsInPlace"] is True
    assert plist["CFBundleDisplayName"] == "GlassMPV"


def _strip_comments_and_strings(source: str) -> str:
    """Strip Swift line/block comments and string literals while respecting \\(...)."""
    out: list[str] = []
    i = 0
    n = len(source)
    in_line_comment = False
    block_depth = 0
    in_string = False
    interp_paren_depths: list[int] = []

    while i < n:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < n else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
                out.append(ch)
            i += 1
            continue

        if block_depth > 0:
            if ch == "/" and nxt == "*":
                block_depth += 1
                i += 2
            elif ch == "*" and nxt == "/":
                block_depth -= 1
                i += 2
            else:
                i += 1
            continue

        if in_string:
            if ch == "\\" and i + 1 < n:
                if nxt == "(":
                    in_string = False
                    interp_paren_depths.append(1)
                    out.append("(")
                    i += 2
                    continue
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue

        if ch == "/" and nxt == "/":
            in_line_comment = True
            i += 2
        elif ch == "/" and nxt == "*":
            block_depth = 1
            i += 2
        elif ch == '"':
            in_string = True
            i += 1
        else:
            if interp_paren_depths:
                if ch == "(":
                    interp_paren_depths[-1] += 1
                elif ch == ")":
                    interp_paren_depths[-1] -= 1
                    if interp_paren_depths[-1] == 0:
                        interp_paren_depths.pop()
                        in_string = True
            out.append(ch)
            i += 1

    return "".join(out)


def test_swift_sources_non_empty_and_balanced():
    swift_files = sorted((ROOT / "Sources").rglob("*.swift"))
    assert len(swift_files) >= 5

    pairs = {")": "(", "}": "{", "]": "["}
    for path in swift_files:
        text = path.read_text(encoding="utf-8")
        assert text.strip(), f"Empty Swift file: {path}"
        cleaned = _strip_comments_and_strings(text)
        stack: list[str] = []
        for ch in cleaned:
            if ch in "({[":
                stack.append(ch)
            elif ch in ")}]":
                assert stack and stack[-1] == pairs[ch], f"Unbalanced delimiter {ch} in {path}"
                stack.pop()
        assert not stack, f"Unclosed delimiters {stack} in {path}"

    mpv_core = (ROOT / "Sources" / "Engine" / "MPVPlayerCore.swift").read_text(encoding="utf-8")
    assert 'joined(separator: ":")' in mpv_core
    assert 'joined(separator: ";")' not in mpv_core
    assert 'setlocale(LC_NUMERIC, "C")' in mpv_core
