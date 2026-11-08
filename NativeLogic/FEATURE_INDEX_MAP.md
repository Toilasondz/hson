# HSON three-feature menu and native logic map

The visible menu contains exactly three tools. Its UI card tags intentionally preserve the engine indexes extracted from the original feature flow:

| UI order | HSON menu card | Engine index | Engine entrypoint |
|---:|---|---:|---|
| 1 | Auto nhập ảnh | 0 | `startFeatureReplaceMedia` |
| 2 | Auto chia beat | 2 | `startFeatureBeatSplit` |
| 3 | Auto nhập phân cảnh | 3 | `startFeatureMultiSceneApply` |

The former **Code gần nhất** preview is not compiled as a user-facing feature and is not present in the menu. QR decode is retained only inside Multi Scene because that workflow needs one QR payload per selected scene.

The engine uses an independent menu and runtime. It does not link the original dylib and does not modify Video Star authorization, entitlement, purchase or account checks.

Class names and selectors were reconstructed from supplied pseudocode/disassembly and the HSONScanner runtime class report. A class name in that report is not proof that a private selector has the assumed signature or behavior. Device-level validation is still required.
