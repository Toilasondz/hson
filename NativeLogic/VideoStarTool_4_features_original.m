// VideoStarTool_4_features.m
//
// Viết lại gọn từ VideoStarTool_cleaned_pseudocode.m + metadata của VideoStarTool.dylib.
// Chỉ gồm 4 chức năng tự động (không gồm UI menu, không gồm phần key/license):
//   0  Auto nhập ảnh vào các lớp hình ảnh     (MultiLayerWizEffectVC)
//   1  Hiển thị code gần nhất từng nhập       (ảnh QR cuối cùng)
//   2  Auto chia beat                          (VideoReviewEditVC + MultiSplitView)
//   3  Auto nhập code và ảnh vào các phân cảnh (VideoReviewEditVC + QRCodeManager)
//
// LƯU Ý ĐỘ TIN CẬY
//  - Tên class/selector/chuỗi/thời gian chờ lấy trực tiếp từ binary: đáng tin.
//  - Cấu trúc luồng (poll, retry, thứ tự gọi) dựng lại từ pseudocode: đúng ý, chưa chạy thử.
//  - Chỗ đánh dấu [INFERRED] là helper mà pseudocode bị mất selector (lifter ghi
//    *(page+0x520)); mình suy ra từ cách dùng, cần đối chiếu lại trong Hopper/Ghidra.
//  - Chưa biên dịch. Cần header khai báo private API (phần PRIVATE bên dưới).

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>

// ============================================================================
// PRIVATE API của Video Star (tên lấy từ binary)
// ============================================================================
@interface NSObject (VSPrivate)
// MultiLayerWizEffectVC
- (id)getMultiLayerEngine;
- (void)pickNewContent;
- (void)pickedWithClipPickerResponse:(id)response;
- (void)presentMLLayerButtonsCollectionViewItemLayerEditTitleViewWithMultiLayerLayer:(id)layer;
- (id)navigationController;
- (NSInteger)navSceneIndex;
- (id)navProject;
// MultiLayerEngine
- (id)layerAtLayerNum:(NSUInteger)n;
- (id)assetForLayer:(NSUInteger)n;
- (id)lastSelectedLayer;
- (NSUInteger)numActiveLayers;
- (void)selectLayer:(NSUInteger)n bordered:(BOOL)b;
- (void)handleImageGenUpdate;
- (void)engineResync;
- (void)refreshDisplay;
- (void)reloadLayerEffects;
- (id)multiLayerLayersWithContent;
- (id)layersWithContent;
- (NSUInteger)layerNum;
- (id)layerImage;
- (id)asset;
// VideoReviewEditVC / project
- (id)project;
- (NSUInteger)sceneCount;
- (NSUInteger)sceneIndex;
- (void)showMergeScenes;
- (void)closeMergePanel;
- (void)showMultiLayer;
- (NSUInteger)lastViewedSceneIndex;
- (void)setLastViewedSceneIndex:(NSUInteger)i;
// MultiSplitView
- (BOOL)beatModeOn;
- (void)toggleBeatMode;
- (BOOL)hasNextBeat;
- (void)jumpToNextBeat;
- (void)setSplitPoint;
- (void)doSplit;
- (CMTime)currentTime;
- (NSArray *)splitTimes;
- (BOOL)isEnoughStorageAvailableForSplit;
- (BOOL)sceneHasAtLeastOneClipWithSceneIndex:(NSUInteger)i;
- (NSUInteger)clipCountForSceneIndex:(NSUInteger)i;
- (id)clipURLForSceneIndex:(NSUInteger)i clipIndex:(NSUInteger)c;
- (id)fileManager;
// QRCodeManager / CustomPopup
+ (id)sharedInstance;
- (void)selectedCode:(NSString *)code withImageData:(NSData *)data;
- (void)buttonPressed:(id)button;
- (id)buttonWithTitle:(NSString *)title;
@end

// ============================================================================
// Thời gian chờ (ns trong binary -> ms)
//   0xaba9500=180  0x8f0d180=150  0x7270e00=120  0x5f5e100=100  0x4c4b400=80
//   0x3938700=60   0x2aea540=45   0x17d7840=25   0xe4e1c0=15    0xb71b00=12
// ============================================================================
static void VSAfter(int64_t ms, dispatch_block_t b) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC), dispatch_get_main_queue(), b);
}

// ============================================================================
// Helper dùng chung
// ============================================================================

// helper_dbcc: valueForKey an toàn (đọc ivar private như "delegate", "_buttons"...)
static id VSValue(id obj, NSString *key) {
    if (!obj || key.length == 0) return nil;
    @try { return [obj valueForKey:key]; } @catch (...) { return nil; }
}

// helper_159ec: obj có phải instance của class tên `name` không
static BOOL VSIsKind(id obj, NSString *name) {
    Class c = NSClassFromString(name);
    return obj && c && [obj isKindOfClass:c];
}

// helper_a574: view controller đang hiển thị (key window của scene foreground) [INFERRED phần đi xuống presented/nav]
static UIViewController *VSTopVC(void) {
    UIWindow *key = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        if (s.activationState != UISceneActivationStateForegroundActive &&
            s.activationState != UISceneActivationStateForegroundInactive) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) { if (w.isKeyWindow) { key = w; break; } }
        if (key) break;
    }
    UIViewController *vc = key.rootViewController;
    for (;;) {
        if (vc.presentedViewController) vc = vc.presentedViewController;
        else if ([vc isKindOfClass:UINavigationController.class]) vc = ((UINavigationController *)vc).visibleViewController ?: vc;
        else if ([vc isKindOfClass:UITabBarController.class]) vc = ((UITabBarController *)vc).selectedViewController ?: vc;
        else break;
    }
    return vc;
}

// helper_10c68: tìm subview đầu tiên thuộc class `cls` (duyệt ngược, đệ quy)
static UIView *VSFindSubview(UIView *v, Class cls) {
    if ([v isKindOfClass:cls]) return v;
    for (UIView *s in v.subviews.reverseObjectEnumerator) {
        UIView *r = VSFindSubview(s, cls);
        if (r) return r;
    }
    return nil;
}

// helper_10fec: "bấm" một nút native.
//   1) nếu view respondsToSelector(sel) thì gọi thẳng;
//   2) không thì lấy ivar `name` (hoặc "_name") và sendActionsForControlEvents:TouchUpInside (0x40).
static BOOL VSPress(id view, const char *ivarName, SEL sel) {
    if (!view) return NO;
    if (sel && [view respondsToSelector:sel]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(view, sel); return YES; }
        @catch (NSException *e) { NSLog(@"native split %@ exception: %@", NSStringFromSelector(sel), e.reason ?: e.name); }
    }
    Class c = [view class];
    Ivar iv = class_getInstanceVariable(c, ivarName);
    if (!iv) {
        char buf[0x80]; snprintf(buf, sizeof buf, "_%s", ivarName);
        iv = class_getInstanceVariable(c, buf);
    }
    if (!iv) return NO;
    id btn = object_getIvar(view, iv);
    if (![btn isKindOfClass:UIButton.class]) return NO;
    @try { [(UIButton *)btn sendActionsForControlEvents:UIControlEventTouchUpInside]; return YES; }
    @catch (NSException *e) { NSLog(@"native split button %s exception: %@", ivarName, e.reason ?: e.name); }
    return NO;
}

// helper_e1bc: bấm nút của CustomPopup
static BOOL VSPressPopupButton(id popup, id button) {
    if (!popup || !button) return NO;
    if ([popup respondsToSelector:@selector(buttonPressed:)]) {
        @try { [popup buttonPressed:button]; return YES; }
        @catch (NSException *e) { NSLog(@"CustomPopup buttonPressed exception: %@", e.reason ?: e.name); }
    }
    if ([button isKindOfClass:UIButton.class]) {
        @try { [(UIButton *)button sendActionsForControlEvents:UIControlEventTouchUpInside]; return YES; }
        @catch (NSException *e) { NSLog(@"popup UIButton action exception: %@", e.reason ?: e.name); }
    }
    return NO;
}

// helper_f308 / helper_d37c: lấy UIImage / AVAsset đang gắn trong lớp [INFERRED]
static id VSLayerMedia(id engine, id layer, NSUInteger num) {
    id a = [engine respondsToSelector:@selector(assetForLayer:)] ? [engine assetForLayer:num] : nil;
    if ([a isKindOfClass:AVAsset.class] || [a isKindOfClass:UIImage.class]) return a;
    if ([layer respondsToSelector:@selector(asset)] && [layer asset]) return [layer asset];
    if ([layer respondsToSelector:@selector(layerImage)]) return [layer layerImage];
    return nil;
}

// helper_ba74: danh sách lớp có nội dung ảnh/video của editor (tối đa 30) [INFERRED]
static NSArray<NSDictionary *> *VSCollectMediaLayers(id editor) {
    id engine = [editor respondsToSelector:@selector(getMultiLayerEngine)] ? [editor getMultiLayerEngine] : nil;
    if (!engine) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSUInteger n = 0; n < 30; n++) {
        id layer = [engine respondsToSelector:@selector(layerAtLayerNum:)] ? [engine layerAtLayerNum:n] : nil;
        if (!layer || [seen containsObject:@(n)]) continue;
        id media = VSLayerMedia(engine, layer, n);
        if (!media) continue;
        [seen addObject:@(n)];
        [out addObject:@{ @"layerIndex": @(n), @"layer": layer,
                          @"mediaKind": [media isKindOfClass:AVAsset.class] ? @"video" : @"image" }];
    }
    return out;
}

// helper_1be7c / helper_12a34: lưu ảnh QR cuối cùng vào Documents/VideoStarTool_LastQR.png
static NSString *VSLastQRPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
            stringByAppendingPathComponent:@"VideoStarTool_LastQR.png"];
}
static NSData *g_lastQRPNG;   // g_32720
static void VSRememberLastQR(id imageOrData) {
    UIImage *img = [imageOrData isKindOfClass:NSData.class] ? [UIImage imageWithData:imageOrData]
                 : [imageOrData isKindOfClass:UIImage.class] ? imageOrData : nil;
    NSData *png = img ? UIImagePNGRepresentation(img) : nil;
    if (!png.length) return;
    g_lastQRPNG = [png copy];
    [png writeToFile:VSLastQRPath() atomically:YES];
}
// helper_12984: đọc lại ảnh đã lưu
static NSData *VSLoadLastQR(void) {
    NSData *d = [NSData dataWithContentsOfFile:VSLastQRPath() options:NSDataReadingMappedIfSafe error:nil];
    if (d.length) { g_lastQRPNG = [d copy]; return g_lastQRPNG; }
    return g_lastQRPNG;
}

// ============================================================================
// VSToolOverlay (chỉ phần liên quan 4 chức năng)
// ============================================================================
@interface VSToolOverlay : UIView
{
@public
    NSInteger _activeFeature;                // 0 ảnh | 1 code gần nhất | 2 chia beat | 3 phân cảnh; -1 = không chạy
    // --- nhập ảnh
    id _mediaSourceEditor, _mediaSourceNav;  NSInteger _mediaSourceMode;  BOOL _mediaPickerResponseHandled;
    id _mediaPickerResponse, _mediaApplyResponse;
    UIImage *_pendingMediaImage;  AVAsset *_pendingMediaAsset;
    BOOL _mediaApplyInProgress;  id _mediaApplyEditor, _mediaApplyEngine;
    NSArray *_mediaApplyLayers;  NSUInteger _mediaApplyIndex, _mediaApplyChanged;
    UIImage *_mediaApplyImage;   AVAsset *_mediaApplyAsset;
    void (^_mediaApplyCompletion)(NSUInteger changed);
    // --- chia beat
    BOOL _beatSplitRunning;  id _beatSplitView, _beatSplitProject;
    NSUInteger _beatSplitSceneBefore, _beatSplitQueued, _beatSplitGuard, _beatSplitNoAdvanceRetries;
    CMTime _beatSplitLastTime;
    // --- phân cảnh
    id _mergeReviewVC, _mergeProject;
    NSUInteger _mergeStartScene, _mergeEndScene, _mergeOriginalLastViewedSceneIndex;
    NSMutableArray *_mergeCodeImages, *_mergePresets;
    BOOL _mergeWaitingForNativeImport;  id _mergeImportEditor, _mergeQRPreviousDelegate;
    NSUInteger _mergeImportOffset;
}
- (void)showSimpleAlert:(NSString *)t message:(NSString *)m index:(NSInteger)i;
- (void)finishFeatureIndex:(NSInteger)i;
- (void)hideToolOverlayForNativeUI;
- (void)restoreToolOverlayAfterNativeUI;
- (void)showFlowTitle:(NSString *)t message:(NSString *)m primary:(NSString *)p secondary:(NSString *)s full:(BOOL)f;
- (void)handleNativePickedMediaResponse:(id)response editor:(id)editor;
- (void)waitForNativeMergeMediaEditorAttempt:(NSUInteger)attempt;
@end

static VSToolOverlay *g_overlay;   // g_32728

// ---------------------------------------------------------------------------
// Hook: MultiLayerWizEffectVC -pickedWithClipPickerResponse:   (helper_ad24)
//   Lưu IMP gốc (để "phát lại" response sau này), rồi mỗi khi Video Star nhận
//   lựa chọn media thì báo cho overlay xử lý trên main queue.
// ---------------------------------------------------------------------------
static IMP g_origPicked;      // g_32748
static BOOL g_pickedHooked;   // g_32740
static void VSInstallPickedHook(void) {
    if (g_pickedHooked) return;
    Class c = NSClassFromString(@"MultiLayerWizEffectVC");
    if (!c) return;
    Method m = class_getInstanceMethod(c, @selector(pickedWithClipPickerResponse:));
    if (!m) { NSLog(@"pickedWithClipPickerResponse hook unavailable"); return; }
    g_origPicked = method_getImplementation(m);
    IMP orig = g_origPicked;
    IMP repl = imp_implementationWithBlock(^(id selfVC, id response) {
        if (orig) ((void (*)(id, SEL, id))orig)(selfVC, @selector(pickedWithClipPickerResponse:), response);
        VSToolOverlay *o = g_overlay;
        if (o) dispatch_async(dispatch_get_main_queue(), ^{
            [o handleNativePickedMediaResponse:response editor:selfVC];
        });
    });
    method_setImplementation(m, repl);
    g_pickedHooked = YES;
    NSLog(@"MultiLayerWizEffectVC pickedWithClipPickerResponse hook installed");
}

// helper_e5a8 + helper_e834: nhân bản response đã chọn rồi phát lại IMP gốc cho editor
static id VSCloneResponse(id r) {
    Class c = NSClassFromString(@"ClipPickerResponse") ?: NSClassFromString(@"_TtC10Video_Star18ClipPickerResponse");
    if (!c || ![r respondsToSelector:@selector(clipPickerResponseType)] || ![r respondsToSelector:@selector(clipIndex)]) return nil;
    @try {
        NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(r, @selector(clipPickerResponseType));
        NSInteger idx  = ((NSInteger (*)(id, SEL))objc_msgSend)(r, @selector(clipIndex));
        return ((id (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)([c alloc],
                 NSSelectorFromString(@"initWithClipPickerResponseType:clipIndex:"), type, idx);
    } @catch (NSException *e) { NSLog(@"ClipPickerResponse clone exception: %@", e.reason ?: e.name); }
    return nil;
}
static BOOL VSReplayPicked(id editor, id response) {
    if (!editor || !response || !g_origPicked) return NO;
    @try { ((void (*)(id, SEL, id))g_origPicked)(editor, @selector(pickedWithClipPickerResponse:), response); return YES; }
    @catch (NSException *e) { NSLog(@"native picked response replay exception: %@", e.reason ?: e.name); }
    return NO;
}

@implementation VSToolOverlay

// ===========================================================================
// CHỨC NĂNG 0 — Auto nhập ảnh vào các lớp hình ảnh
// Luồng: mở bộ chọn gốc (pickNewContent) -> người dùng chọn 1 ảnh/video ->
//        hook bắt response -> lấy media của lớp vừa chọn -> thay vào mọi lớp ảnh/video khác.
// ===========================================================================
- (void)startFeatureReplaceMedia {
    id vc = VSTopVC();
    if (!vc || !VSIsKind(vc, @"MultiLayerWizEffectVC")) {
        [self showSimpleAlert:@"Thông báo" message:@"Bạn chưa trong phần nhiều lớp h/ả." index:0];
        return;
    }
    VSInstallPickedHook();
    [self beginNativeMediaChoiceForEditor:vc mode:0];
}

- (void)beginNativeMediaChoiceForEditor:(id)editor mode:(NSInteger)mode {
    if (!editor || ![editor respondsToSelector:@selector(pickNewContent)]) {
        [self showSimpleAlert:@"Thông báo" message:@"Không tìm thấy bộ chọn nội dung gốc của Video Star." index:_activeFeature];
        return;
    }
    VSInstallPickedHook();
    _mediaSourceEditor = editor;
    _mediaSourceMode = mode;
    _mediaPickerResponseHandled = NO;
    [self hideToolOverlayForNativeUI];
    [self waitForNativeMediaEditorReady:editor attempt:0];
}

// Chờ editor hiện lên màn hình rồi mới gọi pickNewContent (tối đa 60 lần x 100ms)
- (void)waitForNativeMediaEditorReady:(id)editor attempt:(NSUInteger)attempt {
    if (_activeFeature < 0 || _mediaSourceEditor != editor) return;
    UINavigationController *nav = [editor respondsToSelector:@selector(navigationController)] ? [editor navigationController] : nil;
    id engine = [editor respondsToSelector:@selector(getMultiLayerEngine)] ? [editor getMultiLayerEngine] : nil;
    BOOL onScreen = [(UIViewController *)editor viewIfLoaded].window != nil &&
                    (!nav || nav.visibleViewController == editor);
    __weak typeof(self) ws = self;
    if (onScreen && engine) {
        VSAfter(80, ^{
            VSToolOverlay *s = ws;
            if (s && s->_activeFeature >= 0 && s->_mediaSourceEditor == editor &&
                [editor respondsToSelector:@selector(pickNewContent)]) {
                @try { [editor pickNewContent]; }
                @catch (NSException *e) {
                    s->_mediaSourceEditor = nil; s->_mediaSourceMode = -1;
                    [s restoreToolOverlayAfterNativeUI];
                    [s showSimpleAlert:@"Thông báo"
                               message:[NSString stringWithFormat:@"Video Star gặp lỗi khi mở bộ chọn nội dung: %@", e.reason ?: e.name]
                                 index:s->_activeFeature];
                }
            }
        });
    } else if (attempt < 60) {
        VSAfter(100, ^{ [ws waitForNativeMediaEditorReady:editor attempt:attempt + 1]; });
    } else {
        _mediaSourceEditor = nil; _mediaSourceMode = -1;
        [self restoreToolOverlayAfterNativeUI];
        [self showSimpleAlert:@"Thông báo" message:@"Bộ chọn ảnh/video gốc của Video Star chưa sẵn sàng." index:_activeFeature];
    }
}

// Hook gọi vào đây khi người dùng đã chọn media trong bộ chọn gốc
- (void)handleNativePickedMediaResponse:(id)response editor:(id)editor {
    if (!editor || _mediaSourceEditor != editor || _mediaPickerResponseHandled) return;
    _mediaPickerResponse = response;
    [self waitForNativePickedMediaResponse:response editor:editor attempt:0];
}

// Đọc media (UIImage hoặc AVAsset) của lớp vừa được chọn; thử tối đa 16 lần x 120ms
- (void)waitForNativePickedMediaResponse:(id)response editor:(id)editor attempt:(NSUInteger)attempt {
    if (!editor || _mediaSourceEditor != editor || _mediaPickerResponseHandled) return;
    id engine = [editor respondsToSelector:@selector(getMultiLayerEngine)] ? [editor getMultiLayerEngine] : nil;
    id last = [engine respondsToSelector:@selector(lastSelectedLayer)] ? [engine lastSelectedLayer] : nil;
    NSUInteger num = [last respondsToSelector:@selector(layerNum)] ? [last layerNum] : NSUIntegerMax;
    id media = (engine && num != NSUIntegerMax) ? VSLayerMedia(engine, last, num) : nil;
    UIImage *img = [media isKindOfClass:UIImage.class] ? media : nil;
    AVAsset *asset = [media isKindOfClass:AVAsset.class] ? media : nil;
    if (img || asset) {
        _mediaPickerResponseHandled = YES;
        if (_mediaSourceMode == 0) {                       // chế độ "thay ảnh trong các lớp"
            _mediaSourceEditor = nil; _mediaSourceMode = -1;
            __weak typeof(self) ws = self;
            VSAfter(100, ^{ [ws finishNativeMediaChoiceForEditor:editor image:img asset:asset]; });
        } else {                                           // mode 3: dùng cho phân cảnh
            [self finishNativeMediaChoiceForEditor:editor image:img asset:asset];
        }
        return;
    }
    if (attempt < 16) {
        __weak typeof(self) ws = self;
        VSAfter(120, ^{ [ws waitForNativePickedMediaResponse:response editor:editor attempt:attempt + 1]; });
        return;
    }
    _mediaPickerResponseHandled = YES; _mediaSourceEditor = nil; _mediaSourceMode = -1;
    [self restoreToolOverlayAfterNativeUI];
    [self showSimpleAlert:@"Thông báo"
                  message:@"Video Star đã nhận lựa chọn nhưng không lấy được media từ lớp vừa chọn."
                    index:_activeFeature];
}

- (void)finishNativeMediaChoiceForEditor:(id)editor image:(UIImage *)image asset:(AVAsset *)asset {
    if (!image && !asset) return;
    if (_activeFeature == 3) {                 // luồng phân cảnh: lưu media, rồi áp dụng từng phân cảnh
        _pendingMediaImage = image; _pendingMediaAsset = asset;
        [self applyMergePresetsAndMedia];
    } else if (_activeFeature == 0) {          // luồng thay ảnh
        [self handleNativePickedMediaResponse:nil editor:editor];  // (pseudocode gọi với nil để dọn trạng thái)
        __weak typeof(self) ws = self;
        [self startMediaApplyToEditor:editor image:image asset:asset completion:^(NSUInteger changed) {
            VSToolOverlay *s = ws;
            [s restoreToolOverlayAfterNativeUI];
            [s finishFeatureIndex:0];
        }];
    }
}

// Chuẩn bị danh sách lớp cần thay, rồi chạy tuần tự
- (void)startMediaApplyToEditor:(id)editor image:(UIImage *)image asset:(AVAsset *)asset
                     completion:(void (^)(NSUInteger))completion {
    if (_mediaApplyInProgress) return;
    if (!editor || (!image && !asset && !_mediaApplyResponse)) { if (completion) completion(0); return; }
    id engine = [editor respondsToSelector:@selector(getMultiLayerEngine)] ? [editor getMultiLayerEngine] : nil;
    NSArray *cands = VSCollectMediaLayers(editor);
    if (!engine || cands.count == 0) { if (completion) completion(0); return; }

    NSString *pickedKind = asset ? @"video" : (image ? @"image" : nil);
    NSMutableArray *targets = [NSMutableArray array];
    for (NSDictionary *d in cands) {
        // chỉ thay lớp cùng loại với media đã chọn (ảnh->lớp ảnh, video->lớp video)
        if (!pickedKind || [d[@"mediaKind"] isEqualToString:pickedKind] || [d[@"layer"] respondsToSelector:@selector(asset)])
            [targets addObject:d];
    }
    _mediaApplyInProgress = YES;
    _mediaApplyEditor = editor; _mediaApplyEngine = engine;
    _mediaApplyLayers = [targets copy];
    _mediaApplyIndex = 0; _mediaApplyChanged = 0;
    _mediaApplyImage = image; _mediaApplyAsset = asset;
    _mediaApplyCompletion = [completion copy];
    NSLog(@"native layer replace sequence: candidates=%lu targets=%lu pickedKind=%@ response=%@",
          (unsigned long)cands.count, (unsigned long)targets.count, pickedKind, NSStringFromClass([_mediaApplyResponse class]));
    [self applyNextMediaLayer];
}

// Với mỗi lớp: chọn lớp -> mở màn sửa lớp -> phát lại response -> chờ xác minh
- (void)applyNextMediaLayer {
    if (!_mediaApplyInProgress) return;
    if (_mediaApplyIndex >= _mediaApplyLayers.count) {            // hết lớp: dọn dẹp + làm mới engine
        id engine = _mediaApplyEngine; id editor = _mediaApplyEditor;
        if (_mediaApplyChanged) {
            if ([editor respondsToSelector:@selector(reloadLayerEffects)]) [editor reloadLayerEffects];
            if ([engine respondsToSelector:@selector(handleImageGenUpdate)]) [engine handleImageGenUpdate];
            if ([engine respondsToSelector:@selector(engineResync)]) [engine engineResync];
            if ([engine respondsToSelector:@selector(refreshDisplay)]) [engine refreshDisplay];
        }
        NSUInteger changed = _mediaApplyChanged;
        void (^done)(NSUInteger) = _mediaApplyCompletion;
        _mediaApplyInProgress = NO; _mediaApplyCompletion = nil;
        _mediaApplyImage = nil; _mediaApplyAsset = nil; _mediaApplyResponse = nil;
        _mediaApplyEditor = nil; _mediaApplyEngine = nil;
        if (done) done(changed);
        return;
    }
    NSDictionary *rec = _mediaApplyLayers[_mediaApplyIndex++];
    NSUInteger num = [rec[@"layerIndex"] unsignedIntegerValue];
    id engine = _mediaApplyEngine, editor = _mediaApplyEditor;
    @try {
        if (![engine respondsToSelector:@selector(selectLayer:bordered:)]) { [self applyNextMediaLayer]; return; }
        [engine selectLayer:num bordered:NO];
        __weak typeof(self) ws = self;
        VSAfter(25, ^{
            VSToolOverlay *s = ws;
            if (!s || !s->_mediaApplyInProgress) return;
            id layer = [engine respondsToSelector:@selector(layerAtLayerNum:)] ? [engine layerAtLayerNum:num] : rec[@"layer"];
            if (!layer) { [s applyNextMediaLayer]; return; }
            id before = VSLayerMedia(engine, layer, num);          // ảnh/asset TRƯỚC khi thay (để so sánh)
            if ([editor respondsToSelector:@selector(presentMLLayerButtonsCollectionViewItemLayerEditTitleViewWithMultiLayerLayer:)])
                [editor presentMLLayerButtonsCollectionViewItemLayerEditTitleViewWithMultiLayerLayer:layer];
            id resp = VSCloneResponse(s->_mediaPickerResponse);
            if (resp) { s->_mediaApplyResponse = resp; VSReplayPicked(editor, resp); }
            [s waitForMediaLayerReplacement:num editor:editor engine:engine before:before retry:0 record:rec];
        });
    } @catch (NSException *e) {
        NSLog(@"select media layer %lu exception: %@", (unsigned long)num, e.reason ?: e.name);
        [self applyNextMediaLayer];
    }
}

// Xác minh lớp đã đổi sang media mới (tối đa 14 lần x 45ms); sai/hết hạn thì bỏ qua lớp
- (void)waitForMediaLayerReplacement:(NSUInteger)num editor:(id)editor engine:(id)engine
                              before:(id)before retry:(NSUInteger)retry record:(NSDictionary *)rec {
    if (!_mediaApplyInProgress) return;
    @try {
        id layer = [engine respondsToSelector:@selector(layerAtLayerNum:)] ? [engine layerAtLayerNum:num] : nil;
        id now = VSLayerMedia(engine, layer, num);
        BOOL isVideo = [rec[@"mediaKind"] isEqualToString:@"video"];
        BOOL ok = isVideo ? (_mediaApplyAsset && [now isEqual:_mediaApplyAsset])
                          : (_mediaApplyImage && [now isEqual:_mediaApplyImage]);
        if (ok || (now && now != before && retry > 2)) {      // [INFERRED] điều kiện chấp nhận
            _mediaApplyChanged++;
            if ([layer respondsToSelector:@selector(handleImageGenUpdate)]) [layer handleImageGenUpdate];
            __weak typeof(self) ws = self;
            VSAfter(10, ^{ [ws applyNextMediaLayer]; });
            return;
        }
        if (retry > 13) {
            NSLog(@"native media state did not verify for layer %lu", (unsigned long)num);
            [self applyNextMediaLayer];
            return;
        }
        if (!_mediaApplyResponse) {                            // chưa có response thì clone lại và phát lại
            id resp = VSCloneResponse(_mediaPickerResponse);
            if (resp) VSReplayPicked(editor, resp);
        }
        __weak typeof(self) ws = self;
        VSAfter(45, ^{ [ws waitForMediaLayerReplacement:num editor:editor engine:engine before:before retry:retry + 1 record:rec]; });
    } @catch (NSException *e) {
        NSLog(@"verify native replace layer %lu exception: %@", (unsigned long)num, e.reason ?: e.name);
        [self applyNextMediaLayer];
    }
}

// ===========================================================================
// CHỨC NĂNG 1 — Hiển thị code gần nhất từng nhập
// Ưu tiên ảnh đã lưu ở Documents/VideoStarTool_LastQR.png; nếu chưa có thì quét
// Caches / Application Support / Documents, lấy ảnh mới nhất có chứa mã QR.
// ===========================================================================
- (void)startFeatureLastCode {
    NSData *data = VSLoadLastQR();
    UIImage *found = data.length ? [UIImage imageWithData:data] : nil;

    if (!found) {
        NSString *home = NSHomeDirectory();
        NSArray *roots = @[ [home stringByAppendingPathComponent:@"Library/Caches"],
                            [home stringByAppendingPathComponent:@"Library/Application Support"],
                            [home stringByAppendingPathComponent:@"Documents"] ];
        NSSet *exts = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"heic", @"webp"]];
        NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *root in roots) {
            NSDirectoryEnumerator *en = [fm enumeratorAtURL:[NSURL fileURLWithPath:root]
                includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLIsDirectoryKey]
                                   options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
            for (NSURL *u in en) {
                NSNumber *isDir; [u getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
                if (isDir.boolValue) continue;
                if (![exts containsObject:u.pathExtension.lowercaseString]) continue;
                NSDate *mod; [u getResourceValue:&mod forKey:NSURLContentModificationDateKey error:nil];
                [files addObject:@{ @"url": u, @"date": mod ?: NSDate.distantPast }];
                if (files.count > 300) break;                   // giới hạn 300 file
            }
            if (files.count > 300) break;
        }
        [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"date"] compare:a[@"date"]];             // mới nhất trước
        }];
        CIDetector *det = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil
                                             options:@{ CIDetectorAccuracy: CIDetectorAccuracyHigh }];
        for (NSDictionary *f in files) {
            UIImage *img = [UIImage imageWithContentsOfFile:[(NSURL *)f[@"url"] path]];
            CIImage *ci = img ? [[CIImage alloc] initWithImage:img] : nil;
            if (ci && [det featuresInImage:ci].count > 0) { found = img; VSRememberLastQR(img); break; }
        }
    }

    if (!found) {
        [self showSimpleAlert:@"Thông báo" message:@"Không tìm thấy ảnh code đã nhập gần nhất." index:1];
        return;
    }
    [self showFlowTitle:@"Code gần nhất" message:@"Ảnh code gần nhất." primary:@"OK" secondary:@"" full:NO];
    // hiển thị `found` trong _flowImageView (UIImageView bo góc 12, contentMode = AspectFit) — phần UI xem file gốc
}

// ===========================================================================
// CHỨC NĂNG 2 — Auto chia beat
// Điều khiển nút native của MultiSplitView: nextButton(jumpToNextBeat) ->
// setButton(setSplitPoint) lặp tới hết beat -> splitButton(doSplit).
// ===========================================================================
- (void)startFeatureBeatSplit {
    id vc = VSTopVC();
    Class reviewCls = NSClassFromString(@"VideoReviewEditVC"), splitCls = NSClassFromString(@"MultiSplitView");
    UIView *splitView = (vc && [vc isKindOfClass:reviewCls] && splitCls) ? VSFindSubview([(UIViewController *)vc view], splitCls) : nil;
    if (!vc || !reviewCls || !splitCls || ![vc isKindOfClass:reviewCls]) {
        [self showSimpleAlert:@"Thông báo" message:@"Bạn chưa trong phần chia phân cảnh." index:2];
        return;
    }
    if (!splitView) {
        [self showSimpleAlert:@"Thông báo" message:@"Không tìm thấy chức năng chia beat gốc của Video Star." index:2];
        return;
    }
    @try {
        id project = [vc respondsToSelector:@selector(project)] ? [vc project] : nil;
        NSUInteger sceneIdx = [vc respondsToSelector:@selector(sceneIndex)] ? [vc sceneIndex] : 0;

        // kiểm tra điều kiện của Video Star trước khi chia
        BOOL storageOK = ![splitView respondsToSelector:@selector(isEnoughStorageAvailableForSplit)] || [splitView isEnoughStorageAvailableForSplit];
        BOOL hasClip   = ![project respondsToSelector:@selector(sceneHasAtLeastOneClipWithSceneIndex:)] || [project sceneHasAtLeastOneClipWithSceneIndex:sceneIdx];
        NSUInteger clips = [project respondsToSelector:@selector(clipCountForSceneIndex:)] ? [project clipCountForSceneIndex:sceneIdx] : 0;
        NSString *bad = nil;
        if (!storageOK || !hasClip || clips == 0) bad = @"Tất cả clip trong phân cảnh phải hợp lệ trước khi chia.";
        // mỗi clip: file phải tồn tại, AVURLAsset có video track và duration hợp lệ
        for (NSUInteger i = 0; !bad && i < clips; i++) {
            NSURL *u = [project clipURLForSceneIndex:sceneIdx clipIndex:i];
            if (!u || ![NSFileManager.defaultManager fileExistsAtPath:u.path]) { bad = @"Tất cả clip trong phân cảnh phải hợp lệ trước khi chia."; break; }
            AVURLAsset *a = [AVURLAsset URLAssetWithURL:u options:nil];
            if ([a tracksWithMediaType:AVMediaTypeVideo].count == 0 || CMTIME_IS_INVALID(a.duration)) bad = @"Tất cả clip trong phân cảnh phải hợp lệ trước khi chia.";
        }
        if (bad) { [self showSimpleAlert:@"Thông báo" message:bad index:2]; return; }

        _beatSplitView = splitView;  _beatSplitProject = project;  _beatSplitRunning = YES;
        _beatSplitSceneBefore = [project respondsToSelector:@selector(sceneCount)] ? [project sceneCount] : 0;
        _beatSplitQueued = 0; _beatSplitGuard = 0; _beatSplitNoAdvanceRetries = 0;
        _beatSplitLastTime = kCMTimeInvalid;

        // bật chế độ beat nếu chưa bật
        if ([splitView respondsToSelector:@selector(beatModeOn)] && ![splitView beatModeOn] &&
            [splitView respondsToSelector:@selector(toggleBeatMode)])
            [splitView toggleBeatMode];

        __weak typeof(self) ws = self;
        VSAfter(180, ^{ [ws beatSplitAdvanceStepWithAttempt:0]; });   // chờ UI beat bật rồi bắt đầu
    } @catch (NSException *e) {
        _beatSplitRunning = NO;
        [self showSimpleAlert:@"Thông báo"
                      message:[NSString stringWithFormat:@"Video Star gặp lỗi khi chuẩn bị chia beat: %@", e.reason ?: e.name]
                        index:2];
    }
}

// Bấm "next beat"; nếu nút chưa sẵn sàng thì thử lại (tối đa 30 lần x 15ms)
- (void)beatSplitAdvanceStepWithAttempt:(NSUInteger)attempt {
    if (!_beatSplitRunning || !_beatSplitView || !_beatSplitProject) return;
    if (++_beatSplitGuard >= 4096) { [self finishBeatSplitNativeWorkflow]; return; }   // chốt chặn vòng lặp
    CMTime t = [_beatSplitView respondsToSelector:@selector(currentTime)] ? [_beatSplitView currentTime] : kCMTimeInvalid;
    if (VSPress(_beatSplitView, "nextButton", @selector(jumpToNextBeat))) {
        [self waitForBeatAdvanceFromTime:t attempt:0];
        return;
    }
    if (attempt > 29) { [self finishBeatSplitNativeWorkflow]; return; }
    __weak typeof(self) ws = self;
    VSAfter(15, ^{ [ws beatSplitAdvanceStepWithAttempt:attempt + 1]; });
}

// Chờ playhead nhảy sang beat mới (tối đa 100 lần x 12ms), rồi bấm "setSplitPoint"
- (void)waitForBeatAdvanceFromTime:(CMTime)from attempt:(NSUInteger)attempt {
    if (!_beatSplitRunning || !_beatSplitView) return;
    CMTime cur = [_beatSplitView respondsToSelector:@selector(currentTime)] ? [_beatSplitView currentTime] : kCMTimeInvalid;
    BOOL valid = CMTIME_IS_VALID(cur);
    __weak typeof(self) ws = self;
    if (!valid || (CMTIME_IS_VALID(from) && CMTimeCompare(cur, from) <= 0)) {          // chưa nhảy
        if (attempt > 99) {                                                              // quá lâu -> hết beat?
            if (![_beatSplitView respondsToSelector:@selector(hasNextBeat)] || [_beatSplitView hasNextBeat]) {
                if (_beatSplitNoAdvanceRetries <= 1) { _beatSplitNoAdvanceRetries++; [self beatSplitAdvanceStepWithAttempt:0]; return; }
            }
            [self finishBeatSplitNativeWorkflow];
            return;
        }
        VSAfter(12, ^{ [ws waitForBeatAdvanceFromTime:from attempt:attempt + 1]; });
        return;
    }
    if (CMTIME_IS_VALID(_beatSplitLastTime) && CMTimeCompare(cur, _beatSplitLastTime) <= 0) {  // lùi/đứng yên = đã hết beat
        [self finishBeatSplitNativeWorkflow];
        return;
    }
    _beatSplitLastTime = cur;
    _beatSplitNoAdvanceRetries = 0;
    if (!VSPress(_beatSplitView, "setButton", @selector(setSplitPoint))) { [self finishBeatSplitNativeWorkflow]; return; }
    _beatSplitQueued++;
    VSAfter(15, ^{ [ws beatSplitAdvanceStepWithAttempt:0]; });                              // sang beat kế
}

// Hết beat: bấm "Chia" (doSplit) một lần để chia tất cả điểm đã đặt
- (void)finishBeatSplitNativeWorkflow {
    if (!_beatSplitRunning) return;
    id view = _beatSplitView, project = _beatSplitProject;
    NSUInteger before = _beatSplitSceneBefore, queued = _beatSplitQueued;
    _beatSplitRunning = NO; _beatSplitView = nil; _beatSplitProject = nil;
    @try {
        if (queued == 0) { [self showSimpleAlert:@"Thông báo" message:@"Không còn beat nào để chia trong phân cảnh hiện tại." index:2]; return; }
        if (!VSPress(view, "splitButton", @selector(doSplit))) {
            [self showSimpleAlert:@"Thông báo" message:@"Không tìm thấy nút Chia của Video Star." index:2]; return;
        }
        NSLog(@"native manual beat workflow queued=%lu sceneCountBefore=%lu", (unsigned long)queued, (unsigned long)before);
        [self waitForBeatSplitCompletionOnProject:project beforeSceneCount:before expectedAdditional:queued attempt:0];
    } @catch (NSException *e) {
        [self showSimpleAlert:@"Thông báo" message:[NSString stringWithFormat:@"Không thể chia beat: %@", e.reason ?: e.name] index:2];
    }
}

// Đợi sceneCount tăng (tối đa 120 lần x 100ms) rồi báo kết quả
- (void)waitForBeatSplitCompletionOnProject:(id)project beforeSceneCount:(NSUInteger)before
                         expectedAdditional:(NSUInteger)expected attempt:(NSUInteger)attempt {
    NSUInteger now = [project respondsToSelector:@selector(sceneCount)] ? [project sceneCount] : before;
    if (now > before) {
        [self showSimpleAlert:@"Chia beat thành công"
                      message:[NSString stringWithFormat:@"Đã chia %lu phân cảnh từ các beat.", (unsigned long)(now - before)]
                        index:2];
        return;
    }
    if (attempt > 119) {
        [self showSimpleAlert:@"Thông báo" message:@"Video Star chưa hoàn tất thao tác chia beat. Vui lòng kiểm tra lại phân cảnh." index:2];
        return;
    }
    __weak typeof(self) ws = self;
    VSAfter(100, ^{ [ws waitForBeatSplitCompletionOnProject:project beforeSceneCount:before expectedAdditional:expected attempt:attempt + 1]; });
}

// ===========================================================================
// CHỨC NĂNG 3 — Auto nhập code và ảnh vào các phân cảnh
// Luồng:  (a) người dùng chọn khoảng phân cảnh trong "Hợp nhất phân cảnh"
//         (b) nhập 1 ảnh code (QR) cho mỗi phân cảnh -> _mergePresets/_mergeCodeImages
//         (c) chọn 1 ảnh/video dùng chung (mode 3)
//         (d) với từng phân cảnh: mở nhiều lớp -> QRCodeManager selectedCode:withImageData:
//             -> tự bấm popup xác nhận -> thay ảnh/video vào các lớp -> bấm Create
// ===========================================================================
- (void)startFeatureMultiSceneApply {
    id vc = VSTopVC();
    if (!vc || !VSIsKind(vc, @"VideoReviewEditVC") || ![vc respondsToSelector:@selector(showMergeScenes)]) {
        [self showSimpleAlert:@"Thông báo" message:@"Bạn chưa trong phần chia phân cảnh." index:3];
        return;
    }
    _mergeReviewVC = vc;
    _mergeOriginalLastViewedSceneIndex = [vc respondsToSelector:@selector(lastViewedSceneIndex)] ? [vc lastViewedSceneIndex] : 0;
    [vc showMergeScenes];
    [self showFlowTitle:@"Chọn phân cảnh"
                message:@"Chọn điểm bắt đầu và điểm cuối trong Hợp nhất phân cảnh, rồi bấm Bắt đầu."
                primary:@"Bắt đầu" secondary:@"Hủy" full:NO];
}

// (a) đọc phạm vi người dùng đã chọn trong panel gốc (key "startScene"/"lastScene")
- (void)beginMergeRangeFromNativePanel {
    id vc = _mergeReviewVC ?: VSTopVC();
    id project = [vc respondsToSelector:@selector(project)] ? [vc project] : nil;
    NSUInteger total = [project respondsToSelector:@selector(sceneCount)] ? [project sceneCount] : 0;
    NSUInteger start = [VSValue(vc, @"startScene") unsignedIntegerValue];
    NSUInteger last  = [VSValue(vc, @"lastScene") unsignedIntegerValue];
    if (!project || last < start || last >= total) {
        // báo: "Chưa chọn được phạm vi hợp lệ. Hãy chọn lại trong Hợp nhất phân cảnh."
        return;
    }
    _mergeProject = project; _mergeStartScene = start; _mergeEndScene = last;
    [_mergeCodeImages removeAllObjects]; [_mergePresets removeAllObjects];
    if ([vc respondsToSelector:@selector(closeMergePanel)]) [vc closeMergePanel];
    // -> buildMergeCodePickerUI: hiện danh sách "Phân cảnh N" + nút "Nhập code" cho từng phân cảnh
}

// (b) đọc QR từ ảnh người dùng chọn (CIDetector) -> lưu preset/ảnh cho phân cảnh `index`
- (void)acceptMergePreset:(id)preset imageData:(NSData *)imageData index:(NSUInteger)index {
    _mergePresets[index]    = preset;
    _mergeCodeImages[index] = imageData;
    VSRememberLastQR(imageData);                                   // đây là nguồn của chức năng 1
}

// (c) chọn media dùng chung: mở "nhiều lớp" của phân cảnh đầu để dùng bộ chọn gốc
- (void)beginNativeMediaChoiceForMergeProject {
    if (!_mergeProject || _mergeEndScene < _mergeStartScene) {
        [self showSimpleAlert:@"Thông báo" message:@"Chưa có phạm vi phân cảnh hợp lệ." index:3]; return;
    }
    id vc = _mergeReviewVC ?: VSTopVC();
    if (!vc || ![vc respondsToSelector:@selector(showMultiLayer)]) {
        [self showSimpleAlert:@"Thông báo" message:@"Không tìm thấy giao diện nhiều lớp của Video Star." index:3]; return;
    }
    VSInstallPickedHook();
    [self hideToolOverlayForNativeUI];
    @try {
        if ([vc respondsToSelector:@selector(setLastViewedSceneIndex:)]) [vc setLastViewedSceneIndex:_mergeStartScene];
        _mediaSourceNav = nil; _mediaSourceEditor = nil;
        _mediaSourceMode = 3; _mediaPickerResponseHandled = NO;
        [vc showMultiLayer];
        __weak typeof(self) ws = self;
        VSAfter(150, ^{ [ws waitForNativeMergeMediaEditorAttempt:0]; });
    } @catch (NSException *e) {
        [self restoreToolOverlayAfterNativeUI];
        [self showSimpleAlert:@"Thông báo" message:[NSString stringWithFormat:@"Không mở được phần nhiều lớp: %@", e.reason ?: e.name] index:3];
    }
}

// (c2) chờ editor nhiều lớp của phân cảnh đầu hiện lên (tối đa 100 lần x 60ms), rồi mở bộ chọn gốc (mode 3)
- (void)waitForNativeMergeMediaEditorAttempt:(NSUInteger)attempt {
    if (_activeFeature != 3) return;
    id top = VSTopVC();
    if (VSIsKind(top, @"MultiLayerWizEffectVC") && [top respondsToSelector:@selector(getMultiLayerEngine)] && [top getMultiLayerEngine]) {
        _mediaSourceEditor = top;
        _mediaSourceNav = [top respondsToSelector:@selector(navigationController)] ? [top navigationController] : nil;
        [self waitForNativeMediaEditorReady:top attempt:0];     // gọi pickNewContent khi editor sẵn sàng
        return;
    }
    if (attempt > 99) {
        [self restoreToolOverlayAfterNativeUI];
        [self showSimpleAlert:@"Thông báo" message:@"Không mở được bộ chọn ảnh/video gốc của Video Star." index:3];
        return;
    }
    __weak typeof(self) ws = self;
    VSAfter(60, ^{ [ws waitForNativeMergeMediaEditorAttempt:attempt + 1]; });
}

// (d1) áp dụng lần lượt từng phân cảnh
- (void)applyMergePresetsAndMedia {
    // hiện "Đang mở từng phân cảnh, nhập code và thay media…" rồi:
    [self applyMergeSceneOffset:0 project:_mergeProject];
}

- (void)applyMergeSceneOffset:(NSUInteger)offset project:(id)project {
    if (_activeFeature != 3) return;
    NSUInteger count = _mergeEndScene - _mergeStartScene + 1;
    if (offset >= count) {                                           // xong tất cả
        _mergeWaitingForNativeImport = NO; _mergeImportEditor = nil;
        id qr = [NSClassFromString(@"QRCodeManager") respondsToSelector:@selector(sharedInstance)]
                    ? [NSClassFromString(@"QRCodeManager") sharedInstance] : nil;
        [qr setValue:_mergeQRPreviousDelegate forKey:@"delegate"];     // trả delegate QR về như cũ
        _mergeQRPreviousDelegate = nil;
        if ([_mergeReviewVC respondsToSelector:@selector(setLastViewedSceneIndex:)])
            [_mergeReviewVC setLastViewedSceneIndex:_mergeOriginalLastViewedSceneIndex];
        // báo: "Đã áp dụng %lu code cho %lu phân cảnh."
        return;
    }
    id vc = _mergeReviewVC ?: VSTopVC();
    if ([vc respondsToSelector:@selector(setLastViewedSceneIndex:)]) [vc setLastViewedSceneIndex:_mergeStartScene + offset];
    [self openMergeSceneEditorAtOffset:offset project:project attempt:0];
}

// (d2) mở "nhiều lớp" của phân cảnh start+offset, chờ editor đúng phân cảnh (tối đa 100 lần x 80ms)
- (void)openMergeSceneEditorAtOffset:(NSUInteger)offset project:(id)project attempt:(NSUInteger)attempt {
    if (_activeFeature != 3) return;
    NSUInteger scene = _mergeStartScene + offset;
    id top = VSTopVC();
    BOOL isEditor = VSIsKind(top, @"MultiLayerWizEffectVC");
    UINavigationController *nav = isEditor && [top respondsToSelector:@selector(navigationController)] ? [top navigationController] : nil;
    NSInteger navScene = [nav respondsToSelector:@selector(navSceneIndex)] ? [nav navSceneIndex] : -1;
    id navProj = [nav respondsToSelector:@selector(navProject)] ? [nav navProject] : nil;
    if (isEditor && navScene == (NSInteger)scene && (!navProj || navProj == project)) {
        [self beginNativeMergeCodeImportForEditor:top offset:offset project:project];
        return;
    }
    if (attempt > 99) {
        [self showSimpleAlert:@"Thông báo"
                      message:[NSString stringWithFormat:@"Không mở được phần nhiều lớp ở phân cảnh %lu.", (unsigned long)(scene + 1)] index:3];
        return;
    }
    if (attempt == 0) {                                              // lần đầu: yêu cầu Video Star mở nhiều lớp
        id vc = _mergeReviewVC ?: VSTopVC();
        if ([vc respondsToSelector:@selector(showMultiLayer)]) {
            if ([vc respondsToSelector:@selector(setLastViewedSceneIndex:)]) [vc setLastViewedSceneIndex:scene];
            @try { [vc showMultiLayer]; }
            @catch (NSException *e) {
                [self showSimpleAlert:@"Thông báo"
                              message:[NSString stringWithFormat:@"Không mở được phân cảnh %lu: %@", (unsigned long)(scene + 1), e.reason ?: e.name] index:3];
                return;
            }
        }
    }
    __weak typeof(self) ws = self;
    VSAfter(80, ^{ [ws openMergeSceneEditorAtOffset:offset project:project attempt:attempt + 1]; });
}

// (d3) nhập code cho phân cảnh: gọi thẳng QRCodeManager selectedCode:withImageData:
//      (đặt delegate tạm = VSQRCaptureProxy để biết khi nào Video Star nhập xong)
- (void)beginNativeMergeCodeImportForEditor:(id)editor offset:(NSUInteger)offset project:(id)project {
    if (!editor || _activeFeature != 3 || offset >= _mergePresets.count || offset >= _mergeCodeImages.count) return;
    id preset = _mergePresets[offset];
    NSData *imgData = _mergeCodeImages[offset];
    Class qrCls = NSClassFromString(@"QRCodeManager");
    id qr = [qrCls respondsToSelector:@selector(sharedInstance)] ? [qrCls sharedInstance] : nil;
    if (!qr) { [self showSimpleAlert:@"Thông báo" message:@"Không tìm thấy bộ xử lý code của Video Star." index:3]; return; }
    if (preset == NSNull.null || ![imgData isKindOfClass:NSData.class] || imgData.length == 0) {
        [self showSimpleAlert:@"Thông báo"
                      message:[NSString stringWithFormat:@"Thiếu code cho phân cảnh %lu.", (unsigned long)(_mergeStartScene + offset + 1)] index:3];
        return;
    }
    // lấy chuỗi code: CIDetector QR trên ảnh -> messageString (thử các getter của preset nếu cần)
    NSString *code = nil;
    UIImage *img = [UIImage imageWithData:imgData];
    CIDetector *det = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:@{ CIDetectorAccuracy: CIDetectorAccuracyHigh }];
    CIImage *ci = img ? [[CIImage alloc] initWithImage:img] : nil;
    for (CIQRCodeFeature *f in (ci ? [det featuresInImage:ci] : @[])) if (f.messageString.length) { code = f.messageString; break; }
    if (!code.length || ![qr respondsToSelector:@selector(selectedCode:withImageData:)]) {
        [self showSimpleAlert:@"Thông báo" message:@"Không gọi được bộ xử lý code của Video Star." index:3];
        return;
    }
    _mergeWaitingForNativeImport = YES;
    _mergeImportEditor = editor;
    _mergeImportOffset = offset;
    _mergeQRPreviousDelegate = VSValue(qr, @"delegate");
    // [qr setValue:<VSQRCaptureProxy target=_mergeQRPreviousDelegate> forKey:@"delegate"];  (proxy gọi lại importedData:code:)
    NSLog(@"native QR import requested for scene %lu", (unsigned long)(_mergeStartScene + offset));
    @try { [qr selectedCode:code withImageData:imgData]; }
    @catch (NSException *e) {
        _mergeWaitingForNativeImport = NO; _mergeImportEditor = nil;
        [qr setValue:_mergeQRPreviousDelegate forKey:@"delegate"];
        [self showSimpleAlert:@"Thông báo"
                      message:[NSString stringWithFormat:@"Không nhập được code ở phân cảnh %lu: %@", (unsigned long)(_mergeStartScene + offset + 1), e.reason ?: e.name] index:3];
        return;
    }
    __weak typeof(self) ws = self;
    VSAfter(45, ^{ [ws waitForMergeImportMatch:editor offset:offset attempt:0]; });
}

// Proxy QR gọi khi Video Star báo đã nhập xong -> dẫn tới waitForMergeImportMatch
- (void)handleNativeMergeImportedData:(id)data editor:(id)editor code:(id)code {
    if (_mergeWaitingForNativeImport && _mergeImportEditor == editor)
        VSAfter(0, ^{ [self waitForMergeImportMatch:editor offset:self->_mergeImportOffset attempt:0]; });
}

// Tự bấm các popup xác nhận của Video Star khi nhập code (tối đa 180 lần x 25ms)
//   - "ourPopup" / "warningPopup" của editor, kiểu CustomPopup (_buttons/_buttonStrings)
//   - nút có tiêu đề: OK, Ok, Đồng ý, Tiếp tục, Continue; hoặc chứa "dong y"/"tiep tuc"
//   - popup có chữ "cài đặt sẵn"/"original preset layers"/"original layers" = hộp "Trùng khớp"
//   - popup có chữ "multi-layer qr"/"than the scene" = cảnh báo số lớp
//   Hết 180 lần mà vẫn còn popup -> báo lỗi tương ứng theo phân cảnh.
- (void)waitForMergeImportMatch:(id)editor offset:(NSUInteger)offset attempt:(NSUInteger)attempt {
    if (!_mergeWaitingForNativeImport || _mergeImportEditor != editor) return;
    __weak typeof(self) ws = self;
    id popup = VSValue(editor, @"ourPopup") ?: VSValue(editor, @"warningPopup");
    BOOL pressed = NO;
    if (popup && VSIsKind(popup, @"CustomPopup")) {
        NSArray *btns = VSValue(popup, @"_buttons");
        NSArray *titles = VSValue(popup, @"_buttonStrings");
        NSArray *accept = @[@"OK", @"Ok", @"Đồng ý", @"Tiếp tục", @"Continue"];
        for (NSUInteger i = 0; i < btns.count && !pressed; i++) {
            UIButton *b = [btns[i] isKindOfClass:UIButton.class] ? btns[i] : nil;
            NSString *t = b.currentTitle ?: (i < titles.count ? titles[i] : nil);
            NSString *low = [t.lowercaseString stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
            if ([accept containsObject:t] || [low containsString:@"dong y"] || [low containsString:@"tiep tuc"])
                pressed = VSPressPopupButton(popup, b);
        }
        NSLog(@"merge native Match press scene=%lu pressed=%d", (unsigned long)(_mergeStartScene + offset + 1), pressed);
    }
    id engine = [editor respondsToSelector:@selector(getMultiLayerEngine)] ? [editor getMultiLayerEngine] : nil;
    BOOL layersReady = [engine respondsToSelector:@selector(numActiveLayers)] && [engine numActiveLayers] > 0;
    if (!popup && layersReady) {                                     // không còn popup + đã có lớp -> nhập xong
        _mergeWaitingForNativeImport = NO; _mergeImportEditor = nil;
        id qr = [NSClassFromString(@"QRCodeManager") sharedInstance];
        [qr setValue:_mergeQRPreviousDelegate forKey:@"delegate"];
        [self waitForMergePresetReadyAndApplyMedia:editor offset:offset attempt:0];
        return;
    }
    if (attempt > 179) {
        _mergeWaitingForNativeImport = NO;
        [self showSimpleAlert:@"Thông báo"
                      message:[NSString stringWithFormat:popup ? @"Cảnh báo của Video Star ở phân cảnh %lu chưa được xử lý tự động."
                                                              : @"Code ở phân cảnh %lu chưa hoàn tất xử lý native.",
                                                         (unsigned long)(_mergeStartScene + offset + 1)] index:3];
        return;
    }
    VSAfter(pressed ? 45 : 25, ^{ [ws waitForMergeImportMatch:editor offset:offset attempt:attempt + 1]; });
}

// (d4) preset đã vào: thay ảnh/video vào các lớp của phân cảnh này (dùng lại chức năng 0),
//      rồi bấm Create gốc và chờ editor đóng (tối đa 140 lần x 60ms) trước khi sang phân cảnh kế.
- (void)waitForMergePresetReadyAndApplyMedia:(id)editor offset:(NSUInteger)offset attempt:(NSUInteger)attempt {
    if (!editor || _activeFeature != 3) return;
    id engine = [editor respondsToSelector:@selector(getMultiLayerEngine)] ? [editor getMultiLayerEngine] : nil;
    BOOL ready = [engine respondsToSelector:@selector(numActiveLayers)] && [engine numActiveLayers] > 0;
    if (!ready) {
        if (attempt > 99) {
            [self showSimpleAlert:@"Thông báo"
                          message:[NSString stringWithFormat:@"Code ở phân cảnh %lu đã nhập nhưng phần nhiều lớp chưa sẵn sàng.", (unsigned long)(_mergeStartScene + offset + 1)] index:3];
            return;
        }
        __weak typeof(self) ws = self;
        VSAfter(60, ^{ [ws waitForMergePresetReadyAndApplyMedia:editor offset:offset attempt:attempt + 1]; });
        return;
    }
    _mediaApplyResponse = _mediaPickerResponse;
    __weak typeof(self) ws = self;
    void (^afterApply)(NSUInteger) = ^(NSUInteger changed) {
        // không có lớp ảnh/video phù hợp thì log "scene %lu has no eligible image/video layer; continue to native Create"
        // helper_19470: bấm nút Create gốc của editor, sau đó:
        [ws waitForMergeCreateCompletionAtOffset:offset project:ws->_mergeProject editor:editor attempt:0];
    };
    if (VSCollectMediaLayers(editor).count == 0) afterApply(0);
    else [self startMediaApplyToEditor:editor image:_pendingMediaImage asset:_pendingMediaAsset completion:afterApply];
}

// (d5) chờ editor đóng (đã Create) rồi sang phân cảnh offset+1
- (void)waitForMergeCreateCompletionAtOffset:(NSUInteger)offset project:(id)project editor:(id)editor attempt:(NSUInteger)attempt {
    if (_activeFeature != 3) return;
    UIViewController *top = VSTopVC();
    BOOL stillOpen = [(UIViewController *)editor viewIfLoaded].window != nil && editor == top;
    if (stillOpen && attempt <= 139) {
        __weak typeof(self) ws = self;
        VSAfter(60, ^{ [ws waitForMergeCreateCompletionAtOffset:offset project:project editor:editor attempt:attempt + 1]; });
        return;
    }
    UINavigationController *nav = [(UIViewController *)editor navigationController];
    __weak typeof(self) ws = self;
    if (nav) [nav dismissViewControllerAnimated:NO completion:^{ [ws applyMergeSceneOffset:offset + 1 project:project]; }];
    else [self applyMergeSceneOffset:offset + 1 project:project];
}

@end
