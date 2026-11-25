"""Physical integrity tests for GlassMPV iOS project."""

from pathlib import Path
import plistlib
import re
import yaml

ROOT = Path(__file__).resolve().parent.parent


def _resolve_swift_test_file() -> Path:
    for candidate in (ROOT / "Tests" / "GlassMPVTests.swift", ROOT / "tests" / "GlassMPVTests.swift"):
        if candidate.is_file():
            return candidate
    raise AssertionError("Missing Swift test file: Tests/GlassMPVTests.swift")


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
    assert project_cfg["packages"]["MPVUI"]["url"] == "https://github.com/LePips/MPVUI.git"
    assert project_cfg["packages"]["MPVUI"]["from"] == "0.11.0"

    target_cfg = project_cfg["targets"]["GlassMPV"]
    assert "resources" not in target_cfg
    assert "info" not in target_cfg
    assert target_cfg["settings"]["base"]["SWIFT_VERSION"] == "6.0"
    assert target_cfg["settings"]["base"]["INFOPLIST_FILE"] == "Sources/Info.plist"
    assert target_cfg["settings"]["base"]["GENERATE_INFOPLIST_FILE"] in (False, "NO")
    assert target_cfg["settings"]["base"]["ASSETCATALOG_COMPILER_APPICON_NAME"] == "AppIcon"
    assert "GlassMPVTests" in target_cfg.get("scheme", {}).get("testTargets", [])

    shader_sources = [s for s in target_cfg["sources"] if isinstance(s, dict) and s.get("path") == "Resources/Shaders"]
    assert len(shader_sources) == 1 and shader_sources[0].get("buildPhase") == "resources"
    assert any(isinstance(s, dict) and s.get("path") == "Resources/Assets.xcassets" for s in target_cfg["sources"])

    test_target = project_cfg["targets"].get("GlassMPVTests")
    assert test_target is not None, "Missing GlassMPVTests target in project.yml"
    assert test_target["type"] == "bundle.unit-test"
    assert any(isinstance(dep, dict) and dep.get("target") == "GlassMPV" for dep in test_target["dependencies"])

    workflow_raw = (ROOT / ".github" / "workflows" / "build-ios.yml").read_text(encoding="utf-8")
    workflow = yaml.safe_load(workflow_raw)
    steps_text = "\n".join(str(step.get("run", "")) + str(step.get("with", "")) for step in workflow["jobs"]["build-ios"]["steps"])
    assert "xcodegen generate" in steps_text
    assert "xcodebuild test" in steps_text
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


def _assert_swift_delimiters_balanced(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    assert text.strip(), f"Empty Swift file: {path}"
    cleaned = _strip_comments_and_strings(text)
    pairs = {")": "(", "}": "{", "]": "["}
    stack: list[str] = []
    for ch in cleaned:
        if ch in "({[":
            stack.append(ch)
        elif ch in ")}]":
            assert stack and stack[-1] == pairs[ch], f"Unbalanced delimiter {ch} in {path}"
            stack.pop()
    assert not stack, f"Unclosed delimiters {stack} in {path}"


def test_swift_sources_non_empty_and_balanced():
    swift_files = sorted((ROOT / "Sources").rglob("*.swift"))
    assert len(swift_files) >= 6

    test_generator = ROOT / "Sources" / "Engine" / "TestVideoGenerator.swift"
    assert test_generator.is_file(), f"Missing {test_generator}"
    swift_test_file = _resolve_swift_test_file()

    for path in swift_files + [swift_test_file]:
        _assert_swift_delimiters_balanced(path)

    importer = ROOT / "Sources" / "Engine" / "LocalMediaImporter.swift"
    assert importer.is_file(), f"Missing {importer}"
    importer_src = importer.read_text(encoding="utf-8")
    assert "MovieFileTransferable" in importer_src
    assert "LocalMediaImporter" in importer_src
    assert "NSFileCoordinator" in importer_src
    assert "startAccessingSecurityScopedResource" in importer_src

    mpv_core = (ROOT / "Sources" / "Engine" / "MPVPlayerCore.swift").read_text(encoding="utf-8")
    assert "import MPVUI" in mpv_core
    assert "MPVVideoPlayer" in mpv_core
    assert "videoOutput: .metal" in mpv_core
    assert "display-fps-override" in mpv_core
    assert "setDiagnosticsEnabled(true)" in mpv_core
    assert 'joined(separator: ":")' in mpv_core
    assert 'joined(separator: ";")' not in mpv_core
    assert "DispatchQueue.main.sync" not in mpv_core

    vt_engine = (ROOT / "Sources" / "Engine" / "VTOpticalFlowEngine.swift").read_text(encoding="utf-8")
    assert "kCMSampleAttachmentKey_DisplayImmediately" in vt_engine
    assert "interpolatedFrameCount" in vt_engine
    assert "failedInterpolationCount" in vt_engine
    assert "#if targetEnvironment(simulator)" in vt_engine

    player_view = (ROOT / "Sources" / "UI" / "LiquidGlassPlayerView.swift").read_text(encoding="utf-8")
    assert "import PhotosUI" in player_view
    assert "PhotosPicker" in player_view
    assert "runRealDeviceSelfCheck()" in player_view
    assert "compactStatsHUD" in player_view
    assert "showStatsHUD" in player_view

    telemetry_path = ROOT / "Sources" / "Models" / "PlaybackTelemetry.swift"
    assert telemetry_path.is_file(), f"Missing {telemetry_path}"
    telemetry_src = telemetry_path.read_text(encoding="utf-8")
    assert "PlaybackHUDMetrics" in telemetry_src
    assert "ThermalLevel" in telemetry_src


def test_lessons_learned_and_research_documented():
    lessons_path = ROOT / "docs" / "LESSONS_LEARNED.md"
    assert lessons_path.is_file(), f"Missing {lessons_path}"
    content = lessons_path.read_text(encoding="utf-8")
    headings = re.findall(r"^## \d+\.", content, flags=re.MULTILINE)
    assert len(headings) == 9, f"Expected 9 numbered sections in LESSONS_LEARNED.md, found {headings}"

    research_path = ROOT / "docs" / "INTERPOLATION_ARCHITECTURE_RESEARCH.md"
    assert research_path.is_file(), f"Missing {research_path}"
    research_src = research_path.read_text(encoding="utf-8")
    assert "MEMC_RIFE_STD.vpy" in research_src
    assert "MEMC_SVP_LQ.vpy" in research_src
    assert "VTFrameProcessor" in research_src
