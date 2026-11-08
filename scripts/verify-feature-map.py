#!/usr/bin/env python3
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
tweak = (root / "Source/Tweak.m").read_text()
engine = (root / "Source/Features/HSONFeatureEngine.m").read_text()
header = (root / "Source/Features/HSONFeatureEngine.h").read_text()
makefile = (root / "Makefile").read_text()
filter_plist = (root / "HSONModernMenu.plist").read_text()
control = (root / "control").read_text()

checks = [
    (0, "Auto nhập ảnh", "startFeatureReplaceMedia"),
    (2, "Auto chia beat", "startFeatureBeatSplit"),
    (3, "Auto nhập phân cảnh", "startFeatureMultiSceneApply"),
]
if "HSONFeatureEngineRun(index);" not in tweak:
    sys.exit("FAIL: HSON menu is not calling HSONFeatureEngineRun")
for index, title, selector in checks:
    if title not in tweak:
        sys.exit(f"FAIL: menu card title missing: {title}")
    if not re.search(rf"- \(void\){selector}\s*\{{", engine):
        sys.exit(f"FAIL: feature implementation missing: {selector}")
    if f"case {index}: [g_hsonFeatureRuntime {selector}]; break;" not in engine:
        sys.exit(f"FAIL: engine dispatch missing for menu index {index}: {selector}")
    if f'@"engineIndex": @{index}' not in tweak:
        sys.exit(f"FAIL: UI card is not mapped to engine index {index}")

if "Code gần nhất" in tweak or "startFeatureLastCode" in engine:
    sys.exit("FAIL: removed Last Code feature is still exposed or compiled")
if len(re.findall(r'@"engineIndex": @\d+', tweak)) != 3:
    sys.exit("FAIL: menu must expose exactly three feature cards")

required_selectors = [
    "pickedWithClipPickerResponse:", "pickNewContent", "selectLayer:bordered:",
    "jumpToNextBeat", "setSplitPoint", "doSplit", "selectedCode:withImageData:",
]
for selector in required_selectors:
    if selector not in engine:
        sys.exit(f"FAIL: expected private selector missing from engine: {selector}")

for marker in ("// -> buildMergeCodePickerUI", "// helper_19470: bấm nút Create"):
    if marker in engine:
        sys.exit(f"FAIL: unimplemented placeholder remains: {marker}")

expected_bundle = "com.frontierdesign.videostar1"
if expected_bundle not in filter_plist or expected_bundle not in tweak:
    sys.exit("FAIL: runtime bundle check and tweak filter must target the scanned bundle ID")
if "HSONFeatureEngineRun" not in header:
    sys.exit("FAIL: public engine entrypoint missing from header")
if "Source/Features/HSONFeatureEngine.m" not in makefile:
    sys.exit("FAIL: Makefile does not compile the feature engine")
if "VideoStarTool_original.dylib" in makefile:
    sys.exit("FAIL: original dylib must not be linked")
if "Author: HSON" not in control or "Maintainer: HSON" not in control:
    sys.exit("FAIL: package author/maintainer metadata is not HSON")

print("PASS: exactly three HSON menu cards are present.")
print("PASS: menu cards map to Auto Replace, Auto Beat Split and Multi Scene engine methods.")
print("PASS: runtime bundle check and tweak filter match com.frontierdesign.videostar1.")
print("PASS: no legacy Last Code entrypoint remains in the feature engine.")
print("NOTE: static checks do not validate private API ABI or runtime behavior in Video Star.")
