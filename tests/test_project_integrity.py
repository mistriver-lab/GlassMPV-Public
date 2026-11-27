"""Physical integrity tests for pure-ANE GlassMPV iOS project."""

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


def test_no_mpv_or_shader_leftovers():
    assert not (ROOT / "Resources" / "Shaders").exists(), "Resources/Shaders should be removed"
    assert not (ROOT / "Sources" / "Engine" / "MPVPlayerCore.swift").exists(), "MPVPlayerCore.swift should be removed"
    assert not (ROOT / "Sources" / "Models" / "ShaderPreset.swift").exists(), "ShaderPreset.swift should be removed"
    assert not (ROOT / "scripts" / "extract_shaders.py").exists(), "extract_shaders.py should be removed"


def test_project_yml_and_github_workflow_valid():
    project_cfg = yaml.safe_load((ROOT / "project.yml").read_text(encoding="utf-8"))
    assert project_cfg["name"] == "GlassMPV"
    assert project_cfg["options"]["deploymentTarget"]["iOS"] == "26.0"
    assert "packages" not in project_cfg, "MPVUI Swift package should be removed"

    target_cfg = project_cfg["targets"]["GlassMPV"]
    assert "dependencies" not in target_cfg
    assert "resources" not in target_cfg
    assert "info" not in target_cfg
    assert target_cfg["settings"]["base"]["SWIFT_VERSION"] == "6.0"
    assert target_cfg["settings"]["base"]["INFOPLIST_FILE"] == "Sources/Info.plist"
    assert target_cfg["settings"]["base"]["GENERATE_INFOPLIST_FILE"] in (False, "NO")
    assert target_cfg["settings"]["base"]["ASSETCATALOG_COMPILER_APPICON_NAME"] == "AppIcon"
    assert "GlassMPVTests" in target_cfg.get("scheme", {}).get("testTargets", [])

    assert not any(
        isinstance(s, dict) and "Shaders" in str(s.get("path", ""))
        for s in target_cfg["sources"]
    ), "Shaders source entry should be removed"
    assert any(isinstance(s, dict) and s.get("path") == "Resources/Assets.xcassets" for s in target_cfg["sources"])

    test_target = project_cfg["targets"].get("GlassMPVTests")
    assert test_target is not None, "Missing GlassMPVTests target in project.yml"
    assert test_target["type"] == "bundle.unit-test"
    assert any(isinstance(dep, dict) and dep.get("target") == "GlassMPV" for dep in test_target["dependencies"])

    workflow_raw = (ROOT / ".github" / "workflows" / "build-ios.yml").read_text(encoding="utf-8")
    assert "MPVUI" not in workflow_raw
    assert "Shaders" not in workflow_raw
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
    assert version.startswith("0.1.0-beta."), f"Expected 0.1.0-beta.x in VERSION, got {version}"
    short_version = version.split("-", 1)[0]
    project_cfg = yaml.safe_load((ROOT / "project.yml").read_text(encoding="utf-8"))
    assert project_cfg["targets"]["GlassMPV"]["settings"]["base"]["MARKETING_VERSION"] == short_version

    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    assert f"[v{version}]" in changelog

    release_info = (ROOT / "Sources" / "Models" / "AppReleaseInfo.swift").read_text(encoding="utf-8")
    assert f'releaseTag = "{version}"' in release_info, f"AppReleaseInfo.releaseTag must match VERSION ({version})"

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
    ats = plist.get("NSAppTransportSecurity")
    assert isinstance(ats, dict) and ats.get("NSAllowsArbitraryLoads") is True, "Missing NSAppTransportSecurity"
    photo_desc = plist.get("NSPhotoLibraryUsageDescription")
    assert isinstance(photo_desc, str) and photo_desc.strip(), "Missing NSPhotoLibraryUsageDescription"
    photo_add_desc = plist.get("NSPhotoLibraryAddUsageDescription")
    assert isinstance(photo_add_desc, str) and photo_add_desc.strip(), "Missing NSPhotoLibraryAddUsageDescription"
    query_schemes = plist.get("LSApplicationQueriesSchemes")
    assert isinstance(query_schemes, list) and "quark" in query_schemes, "Missing quark in LSApplicationQueriesSchemes"


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

    options_path = ROOT / "Sources" / "Models" / "OpticalFlowOptions.swift"
    assert options_path.is_file(), f"Missing {options_path}"
    options_src = options_path.read_text(encoding="utf-8")
    assert "enum InterpolationMode" in options_src
    assert "enum OpticalFlowTargetFPS" in options_src
    assert "fps72" not in options_src
    assert "smartPresets" in options_src
    assert "activeCapsuleSummary" in options_src

    enhance_opts = ROOT / "Sources" / "Models" / "VideoEnhancementOptions.swift"
    assert enhance_opts.is_file(), f"Missing {enhance_opts}"
    enhance_opts_src = enhance_opts.read_text(encoding="utf-8")
    assert "enum VideoEnhancementPreset" in enhance_opts_src
    assert "enum VideoEnhancementPlanner" in enhance_opts_src

    metal_enhancer = ROOT / "Sources" / "Engine" / "MetalVideoEnhancer.swift"
    assert metal_enhancer.is_file(), f"Missing {metal_enhancer}"
    metal_enhancer_src = metal_enhancer.read_text(encoding="utf-8")
    assert "final class MetalVideoEnhancer" in metal_enhancer_src
    assert "MTLFXSpatialScaler" in metal_enhancer_src
    assert "renderToLayer" in metal_enhancer_src
    assert "renderToLayerStatus" in metal_enhancer_src
    assert "displayEnhanceYUVFragment" in metal_enhancer_src

    local_proxy = ROOT / "Sources" / "Engine" / "LocalHTTPStreamProxy.swift"
    assert local_proxy.is_file(), f"Missing {local_proxy}"
    local_proxy_src = local_proxy.read_text(encoding="utf-8")
    assert "NWListener" in local_proxy_src
    assert "mergeSetCookieHeaders" in local_proxy_src
    assert "rewriteHLSManifest" in local_proxy_src
    assert "patchHEV1ToHVC1" in local_proxy_src
    assert "MP4HEV1StreamPatcher" in local_proxy_src

    for required_cloud_file in (
        ROOT / "Sources" / "Models" / "MediaSourceModels.swift",
        ROOT / "Sources" / "Models" / "SubtitleModels.swift",
        ROOT / "Sources" / "Models" / "WatchHistoryStore.swift",
        ROOT / "Sources" / "Engine" / "MediaSourceClients.swift",
        ROOT / "Sources" / "Engine" / "RemoteStreamOpticalFlowWorker.swift",
        ROOT / "Sources" / "Engine" / "SubtitleManager.swift",
        ROOT / "Sources" / "UI" / "CloudMediaLibraryView.swift",
    ):
        assert required_cloud_file.is_file(), f"Missing {required_cloud_file}"

    remote_worker_src = (ROOT / "Sources" / "Engine" / "RemoteStreamOpticalFlowWorker.swift").read_text(encoding="utf-8")
    assert "RemoteOpticalFlowBudgetPlanner" in remote_worker_src
    assert "OpticalFlowBudgetGuard" in remote_worker_src

    sub_models_src = (ROOT / "Sources" / "Models" / "SubtitleModels.swift").read_text(encoding="utf-8")
    assert "SubtitleParser" in sub_models_src
    assert "SubtitleCue" in sub_models_src

    sub_mgr_src = (ROOT / "Sources" / "Engine" / "SubtitleManager.swift").read_text(encoding="utf-8")
    assert "final class SubtitleManager" in sub_mgr_src
    assert "AVPlayerItemLegibleOutput" in sub_mgr_src

    history_src = (ROOT / "Sources" / "Models" / "WatchHistoryStore.swift").read_text(encoding="utf-8")
    assert "final class WatchHistoryStore" in history_src
    assert "WatchHistoryEntry" in history_src

    media_clients_src = (ROOT / "Sources" / "Engine" / "MediaSourceClients.swift").read_text(encoding="utf-8")
    assert "getTokenForQrcodeLogin" in media_clients_src
    assert "getServiceTicketByQrcodeToken" in media_clients_src

    vt_engine = (ROOT / "Sources" / "Engine" / "VTOpticalFlowEngine.swift").read_text(encoding="utf-8")
    assert "MPVUI" not in vt_engine
    assert "MPV 超分核" not in vt_engine
    assert "MPVPlayerController" not in vt_engine
    assert "kCMSampleAttachmentKey_DisplayImmediately" in vt_engine
    assert "interpolatedFrameCount" in vt_engine
    assert "failedInterpolationCount" in vt_engine
    assert "diagnosticLogs" in vt_engine
    assert "SuperResolutionPolicy" in vt_engine
    assert "#if targetEnvironment(simulator)" in vt_engine
    assert "OpticalFlowSyntheticClock" in vt_engine
    assert "requiresFlushToResumeDecoding" in vt_engine
    assert "preferredTransform" in vt_engine
    assert "pendingFirstFrame" in vt_engine
    assert "averageInterpolationMs" in vt_engine
    assert "layer.addSublayer(displayLayer)" in vt_engine
    assert "override class var layerClass" not in vt_engine
    assert "nonisolated static func isQuarterTurnTransform" in vt_engine
    assert "nonisolated static func normalizedRotationTransform" in vt_engine
    assert "private func markReaderEOF()" in vt_engine
    assert "formatDetailedError" in vt_engine
    assert "buildReaderSettingsTiers" in vt_engine
    assert "openAssetReaderWithFallback" in vt_engine
    assert "AVMutableComposition" in vt_engine
    assert "normalizeSourceBufferIfNeeded" in vt_engine
    assert "OpticalFlowPTSReorderBuffer" in vt_engine
    assert "HEVCFormatNormalizer" in vt_engine
    assert "VTDecompressionSessionHolder" in vt_engine
    assert "openCompressedPassthroughReader" in vt_engine
    assert "createDecompressionSessionWithFallback" in vt_engine
    assert "decoderSpecification:" in vt_engine
    assert "videoDecoderSpecification:" not in vt_engine
    assert "OpticalFlowBackendKind" in vt_engine
    assert "OpticalFlowCandidate" in vt_engine
    assert "struct OpticalFlowCandidate: Hashable" in vt_engine
    assert "OpticalFlowResolutionPlanner" in vt_engine
    assert "ActiveOpticalFlowConfiguration" in vt_engine
    assert "VTFrameRateConversionConfiguration" in vt_engine
    assert "VTFrameRateConversionParameters" in vt_engine
    assert "activeBackendLabel" in vt_engine
    assert "activateCandidate" in vt_engine
    assert "queryDimensionBounds" in vt_engine
    assert "interpolationExhausted" in vt_engine
    assert "OpticalFlowPhaseScheduler" in vt_engine
    assert "OpticalFlowBudgetGuard" in vt_engine
    assert "recommendedQueueLimits" in vt_engine
    assert "targetSummaryBadge" in vt_engine
    assert "downgradeResolutionIfPossible" in vt_engine
    assert "downgradeTargetFPSIfPossible" in vt_engine
    assert "updateQueueLimits" in vt_engine
    assert "readMaxQueuedFrames" in vt_engine
    assert "readPrebufferFrameTarget" in vt_engine
    assert "lowLatencyExponent" in vt_engine
    assert "selectOptimalPixelFormat" in vt_engine
    assert "nativeDecodePixelFormats" in vt_engine
    assert "awaitingClockCatchUpAfterSwitch" in vt_engine
    assert "thermalMaxTargetTier" in vt_engine
    assert "isPassthroughForced" in vt_engine
    assert "isInterpolationEnabled" in vt_engine
    assert "runPassthroughTask" in vt_engine
    assert "let preferFRC = false" in vt_engine
    assert "HH:mm:ss.SSS" in vt_engine
    assert "preferredDynamicRange" in vt_engine
    assert "isDolbyVision" in vt_engine
    assert "updateTargetConfiguration" in vt_engine
    assert "applyUserSwitchInPlace" in vt_engine
    assert "UIUpdateLink" in vt_engine
    assert "pulseProMotionCommit" in vt_engine
    assert "OpticalFlowFramePacer" in vt_engine
    assert "OpticalFlowDecodedFramePipe" in vt_engine
    assert "recommendedDecodeDimensions" in vt_engine
    assert "effectivePowerThermalCap" in vt_engine
    assert "recommendedMetalMaxLongSide" in vt_engine
    assert ".latencyCritical" in vt_engine
    task_start = vt_engine.index("private func runOpticalFlowTask(")
    task_end = vt_engine.index("#endif", task_start)
    optical_flow_task_body = vt_engine[task_start:task_end]
    assert ".lock()" not in optical_flow_task_body
    assert ".unlock()" not in optical_flow_task_body

    player_view = (ROOT / "Sources" / "UI" / "LiquidGlassPlayerView.swift").read_text(encoding="utf-8")
    assert "MPVUI" not in player_view
    assert "MPVPlayerController" not in player_view
    assert "MPVVideoSurface" not in player_view
    assert "MPV 超分核" not in player_view
    assert "playBuiltInSampleVideo" not in player_view
    assert "内置 3 秒" not in player_view
    assert "import PhotosUI" in player_view
    assert "PhotosPicker" in player_view
    assert ".fileImporter(" not in player_view
    assert "presentLocalVideoPicker()" in player_view
    assert "runRealDeviceSelfCheck()" in player_view
    assert "compactStatsHUD" in player_view
    assert "showStatsHUD" in player_view
    assert "closeToHome()" in player_view
    assert "OrientationController" in player_view
    assert "DiagnosticLogExporter" in player_view
    assert "NativeShareSheetPresenter" in player_view
    assert "runtimeTimeline" in player_view
    assert "currentInterpolationVerdict" in player_view
    assert "startRuntimeTelemetrySampling()" in player_view
    assert "captureRuntimeTelemetrySample()" in player_view
    assert "activeBackendLabel" in player_view
    assert "opticalFlowTargetFPS" in player_view
    assert "setOpticalFlowTargetFPS" in player_view
    assert "selectFrameRateOption" in player_view
    assert "setEDREnabled" in player_view
    assert "setAspectFill" in player_view
    assert "setLooping" in player_view
    assert "retryWithoutInterpolation" in player_view
    assert "lastSessionSummary" in player_view
    assert "uiAuditLogs" in player_view
    assert "recordUISwitch" in player_view
    assert "DeviceDiagnosticsSampler" in player_view
    assert "SubtitleControlSheet" in player_view
    assert "WatchHistorySheet" in player_view
    assert "subtitleManager" in player_view
    assert "watchHistoryStore" in player_view

    swift_test_src = swift_test_file.read_text(encoding="utf-8")
    assert "testOpticalFlowResolutionPlannerAndCandidateFallback" in swift_test_src
    assert "testOpticalFlowPhaseSchedulerAndMultiTierTargets" in swift_test_src
    assert "testOpticalFlowExponentPixelFormatAndThermalPolicy" in swift_test_src
    assert "testCoordinatorIdempotencyAndPassthroughMode" in swift_test_src
    assert "testDiagnosticLogUpgradeSessionSummaryAndMemorySampler" in swift_test_src
    assert "testIdentifiableSelectionTagsDolbyVisionAndDisplaySwitches" in swift_test_src
    assert "testVideoEnhancementPlannerAndMetalEnhancer" in swift_test_src
    assert "testQuarkDriveClientParsersAndStreamSelection" in swift_test_src
    assert "testEmbyClientParsersAndStreamBuilders" in swift_test_src
    assert "testWebDAVPropfindXMLParser" in swift_test_src
    assert "testMediaSourceStoreAndCloudPlaybackRequest" in swift_test_src
    assert "testLocalHTTPStreamProxyParsersCookieMergeAndHLSRewrite" in swift_test_src
    assert "testLocalHTTPStreamProxyLiveLoopbackRoundTrip" in swift_test_src
    assert "testMetalDirectRendererAspectMathAndZeroWaitMetrics" in swift_test_src
    assert "testQuarkQRLoginParsingAndURLBuilder" in swift_test_src
    assert "testMetalDrawableSizingAndTelemetryThrottling" in swift_test_src
    assert "testLocalHTTPStreamProxyHEV1ToHVC1RewriteAndChunkBoundary" in swift_test_src
    assert "testRemoteOpticalFlowBudgetPlannerAndAdaptiveLag" in swift_test_src
    assert "testSubtitleParserSRTWebVTTASSAndActiveLookup" in swift_test_src
    assert "testWatchHistoryStorePersistenceProgressAndContinueWatching" in swift_test_src

    orientation_ctrl = ROOT / "Sources" / "UI" / "OrientationController.swift"
    assert orientation_ctrl.is_file(), f"Missing {orientation_ctrl}"
    orientation_src = orientation_ctrl.read_text(encoding="utf-8")
    assert "enterVideoLandscape" in orientation_src
    assert "returnToHomeOrientation" in orientation_src

    log_exporter = ROOT / "Sources" / "UI" / "DiagnosticLogExporter.swift"
    assert log_exporter.is_file(), f"Missing {log_exporter}"
    log_exporter_src = log_exporter.read_text(encoding="utf-8")
    assert "DiagnosticLogExporter" in log_exporter_src
    assert "NativeShareSheetPresenter" in log_exporter_src
    assert "runtimeTimeline" in log_exporter_src
    assert "Runtime Telemetry Timeline" in log_exporter_src
    assert "MPV Logs" not in log_exporter_src

    doc_picker = ROOT / "Sources" / "UI" / "NativeDocumentPickerPresenter.swift"
    assert doc_picker.is_file(), f"Missing {doc_picker}"
    doc_picker_src = doc_picker.read_text(encoding="utf-8")
    assert "UIDocumentPickerViewController" in doc_picker_src
    assert "asCopy: true" in doc_picker_src

    telemetry_path = ROOT / "Sources" / "Models" / "PlaybackTelemetry.swift"
    assert telemetry_path.is_file(), f"Missing {telemetry_path}"
    telemetry_src = telemetry_path.read_text(encoding="utf-8")
    assert "PlaybackHUDMetrics" in telemetry_src
    assert "ThermalLevel" in telemetry_src
    assert "MPVProbeSnapshot" not in telemetry_src
    assert "InterpolationVerdict" in telemetry_src
    assert "RuntimeTelemetrySample" in telemetry_src
    assert "DeviceDiagnosticsSampler" in telemetry_src
    assert "task_self_trap()" in telemetry_src
    assert "mach_task_self_" not in telemetry_src
    assert "SessionDiagnosticSummary" in telemetry_src


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
