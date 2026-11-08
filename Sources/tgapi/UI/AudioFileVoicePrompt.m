#import "AudioFileVoicePrompt.h"
#import "TGExtraLocalization.h"
#import <UIKit/UIKit.h>

#define TGLoc(key) [TGExtraLocalization localizedStringForKey:(key)]

void TGExtraConfirmAudioFileConversion(UIViewController *picker, NSUInteger count,
    void (^completion)(TGExtraAudioFileChoice choice)) {
    UIViewController *presenter = picker.presentingViewController ?: picker.view.window.rootViewController
        ?: UIApplication.sharedApplication.keyWindow.rootViewController;
    if (!presenter) { completion(TGExtraAudioFileChoiceCancel); return; }
    void (^showPrompt)(void) = ^{
        UIViewController *top = presenter;
        while (top.presentedViewController) top = top.presentedViewController;
        if (top.isBeingDismissed) { completion(TGExtraAudioFileChoiceCancel); return; }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:TGLoc(@"AUDIO_TO_VOICE_PROMPT_TITLE")
            message:[NSString stringWithFormat:TGLoc(@"AUDIO_TO_VOICE_PROMPT_MESSAGE"), (unsigned long)count]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"AUDIO_TO_VOICE_SEND_VOICE")
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { completion(TGExtraAudioFileChoiceVoice); }]];
        UIAlertAction *original = [UIAlertAction actionWithTitle:TGLoc(@"AUDIO_TO_VOICE_SEND_FILE")
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { completion(TGExtraAudioFileChoiceOriginal); }];
        [alert addAction:original];
        alert.preferredAction = original;
        [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"CANCEL")
            style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { completion(TGExtraAudioFileChoiceCancel); }]];
        [top presentViewController:alert animated:YES completion:nil];
    };
    if (picker.transitionCoordinator && (picker.isBeingDismissed || !picker.presentingViewController)) {
        if (![picker.transitionCoordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) { showPrompt(); }]) showPrompt();
    } else if (picker.presentingViewController) [picker dismissViewControllerAnimated:YES completion:showPrompt];
    else showPrompt();
}
