#!/usr/bin/env python3
"""Convert a real WAV through the production file-to-voice AAC exporter."""
from pathlib import Path
import math
import struct
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'Sources/tgapi/VideoAudioExtractor.m').read_text()
paths = source[source.index('static NSString *tgextraVoiceCacheRoot('):source.index('static AVAsset *tgextraResolvePhotosVideo(')]
export = source[source.index('static NSURL *tgextraExtractAudio('):source.index('NSDictionary *tgextraRewriteToVoice(')]
convert = source[source.index('NSURL *TGExtraConvertAudioFile('):]
support = r'''
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import "Constants.h"
#define tgextraDiag(...) ((void)0)
static const NSTimeInterval kTGExtraExtractionTimeout = 15;
static void TGExtraShowToast(NSString *text) {}
static NSData *TGExtraAudioWaveform(AVAsset *asset) { return [NSData dataWithBytes:"bars" length:4]; }
static NSString *registeredName;
static NSInteger registeredDuration;
@interface TGExtraLocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end
@implementation TGExtraLocalization
+ (NSString *)localizedStringForKey:(NSString *)key { return key; }
@end
@interface TLParser : NSObject
+ (void)registerVoiceUploadWithFileName:(NSString *)name duration:(NSInteger)duration waveform:(NSData *)waveform;
@end
@implementation TLParser
+ (void)registerVoiceUploadWithFileName:(NSString *)name duration:(NSInteger)duration waveform:(NSData *)waveform {
    registeredName = name; registeredDuration = duration;
    NSCAssert(waveform.length == 4, @"Register the exported waveform");
}
@end
'''
tests = r'''
int main(int argc, char **argv) { @autoreleasepool {
    NSURL *input = [NSURL fileURLWithPath:@(argv[1])];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:NO forKey:kAudioToVoice];
    NSCAssert(TGExtraConvertAudioFile(input) == input, @"Disabled conversion preserves the file");
    [defaults setBool:YES forKey:kAudioToVoice];
    NSURL *document = [NSURL fileURLWithPath:@"/tmp/document.pdf"];
    NSCAssert(TGExtraConvertAudioFile(document) == document, @"Other document types remain ordinary files");
    NSURL *output = TGExtraConvertAudioFile(input);
    NSCAssert(output && [output.lastPathComponent hasPrefix:@"TGExtraAudio-"], @"Audio files have registered, unique voice names");
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:output options:nil];
    NSCAssert([asset tracksWithMediaType:AVMediaTypeAudio].count == 1 && [asset tracksWithMediaType:AVMediaTypeVideo].count == 0,
              @"The exported file contains AAC audio without video");
    NSCAssert(fabs(CMTimeGetSeconds(asset.duration) - 1) < 0.1 && registeredDuration == 1 && [registeredName isEqual:output.lastPathComponent], @"Upload metadata matches the actual export");
    [NSFileManager.defaultManager removeItemAtURL:output.URLByDeletingLastPathComponent error:NULL];
    NSCAssert(TGExtraConvertAudioFile([input.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"missing.mp3"]) == nil,
              @"A failed audio conversion never sends the source as an ordinary document");
    [defaults removeObjectForKey:kAudioToVoice];
    puts("PASS real audio file to AAC voice export: waveform registration, duration, setting isolation, other documents and failed inputs");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='tgextra-audio-file-') as tmp:
    work = Path(tmp)
    audio = work / 'tone.wav'
    with wave.open(str(audio), 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b''.join(struct.pack('<h', int(math.sin(i * 2 * math.pi * 440 / 16000) * 12000)) for i in range(16000)))
    main = work / 'main.m'
    main.write_text(support + paths + export + convert + tests)
    binary = work / 'tests'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-Wno-deprecated-declarations',
                    '-framework', 'Foundation', '-framework', 'AVFoundation', '-framework', 'CoreMedia',
                    '-I' + str(ROOT / 'Sources/tgapi'), str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(audio)], check=True, timeout=30)
