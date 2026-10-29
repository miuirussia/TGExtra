#import "Headers.h"
void TGExtraShowToast(NSString *text) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ TGExtraShowToast(text); });
        return;
    }

    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (!window) return;

    UILabel *toast = [[UILabel alloc] init];
    toast.text = text;
    toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    toast.textColor = [UIColor whiteColor];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
    toast.numberOfLines = 0;
    toast.layer.cornerRadius = 14;
    toast.layer.masksToBounds = YES;
    toast.layer.zPosition = 99999;
    toast.alpha = 0.0;

    CGFloat maxWidth = window.bounds.size.width - 80;
    CGSize fitted = [toast sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    CGFloat width = MIN(maxWidth, fitted.width + 32);
    CGFloat height = fitted.height + 20;
    toast.frame = CGRectMake((window.bounds.size.width - width) / 2.0,
                             window.bounds.size.height - height - 120,
                             width, height);

    [window addSubview:toast];
    [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1.0; } completion:^(BOOL done) {
        [UIView animateWithDuration:0.3 delay:1.6 options:0 animations:^{
            toast.alpha = 0.0;
        } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    }];
}
