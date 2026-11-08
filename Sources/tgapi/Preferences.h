#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL TGExtraSavePreferences(void);
void TGExtraRestorePreferences(void);
NSData *TGExtraExportSettings(NSError **error);
NSDictionary<NSString *, id> *TGExtraValidateSettings(NSData *data, NSError **error);
BOOL TGExtraImportSettings(NSData *data, NSError **error);

#ifdef __cplusplus
}
#endif
