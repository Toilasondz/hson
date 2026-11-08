# VideoStarTool HSON — 3-Feature Menu v5.0.0

Independent Objective-C tweak for Video Star 14.3.3, with the author credited as **HSON**.

## Menu features

| Feature | What it does | Important limitation |
|---|---|---|
| Auto nhập ảnh | Opens Video Star's native media picker, then attempts to apply the selected media across eligible multilayer slots of the same type. | Uses private picker response and layer APIs; must be tested on-device. |
| Auto chia beat | Locates the native beat-split view, sets split points, then invokes Video Star's native split operation. | Requires a valid scene and the private beat selectors to match this app build. |
| Auto nhập phân cảnh | Reads the selected scene range, requests one QR image per scene, decodes each QR, then applies a shared selected image/video while walking through the scenes. | Guided native workflow: confirm Video Star's QR prompts and press its native Create action when asked. HSON waits for the editor to close; it does not guess a private Create selector. |

The legacy **Code gần nhất** menu card is removed. QR decoding remains internal to Multi Scene; the separate last-code preview/cache is removed.

## Target

- Bundle ID: `com.frontierdesign.videostar1` (taken from the supplied HSONScanReport.json)
- App: Video Star 14.3.3, build 1809
- Device report: iOS 16.7.16, arm64
- Package scheme: rootless, arm64

## Build

Requires Theos and an iOS SDK:

```sh
make clean
make package FINALPACKAGE=1
```

GitHub Actions workflow: `.github/workflows/main.yml`.

## Test status

The project has not been built with an Apple iOS SDK in this environment and has not been executed on the target device. The underlying feature engine calls private Video Star APIs, so **100% operation cannot honestly be guaranteed** from source inspection alone. Test against a duplicate project before using valuable edits.

The original dylib is not linked into this independent tweak. Video Star authorization, entitlement, purchase and account logic are left untouched.
