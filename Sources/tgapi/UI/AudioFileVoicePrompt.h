#import <Foundation/Foundation.h>

@class UIViewController;

typedef NS_ENUM(NSInteger, TGExtraAudioFileChoice) {
    TGExtraAudioFileChoiceOriginal,
    TGExtraAudioFileChoiceVoice,
    TGExtraAudioFileChoiceCancel,
};

void TGExtraConfirmAudioFileConversion(UIViewController *picker, NSUInteger count,
    void (^completion)(TGExtraAudioFileChoice choice));
