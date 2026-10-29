#import <Foundation/Foundation.h>

// Runs have a text and a kind: equal, delete or insert. Both inputs are preserved verbatim.
NSArray<NSDictionary<NSString *, NSString *> *> *TGExtraTextDiff(NSString *before, NSString *after);
