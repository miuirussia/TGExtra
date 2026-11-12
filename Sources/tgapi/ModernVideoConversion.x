#import "Compatibility.h"
#import "UI/Headers.h"
#import "UI/HostDisplayNode.h"

@interface TGExtraModernVideoConversion : NSObject
+ (BOOL)showOn:(NSObject *)controller node:(id)node view:(UIView *)view;
+ (void)hideOn:(NSObject *)controller;
@end

%group TGExtraModernVideoPreview
%hook TGExtraModernEditorController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIView *view = [(UIViewController *)self view];
    id node = [view respondsToSelector:@selector(asyncdisplaykit_node)] ? [view asyncdisplaykit_node] : nil;
    BOOL installed = node && [TGExtraModernVideoConversion showOn:self node:node view:view];
    TGExtraRecordHookStatus(@"Modern video preview", installed ? @"installed: gallery send adapter" : @"unavailable: editor fields");
}
- (void)viewDidDisappear:(BOOL)animated {
    [TGExtraModernVideoConversion hideOn:self];
    %orig;
}
%end
%end

%ctor {
    Class cls = NSClassFromString(@"ChatMediaEditorScreen.ChatMediaEditorScreen");
    if (cls) {
        %init(TGExtraModernVideoPreview, TGExtraModernEditorController = cls);
        TGExtraRecordHookStatus(@"Modern video preview", @"installed; awaiting editor");
    }
}
