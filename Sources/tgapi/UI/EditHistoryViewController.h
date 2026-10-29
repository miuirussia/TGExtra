#import <UIKit/UIKit.h>

@interface TGExtraEditHistoryViewController : UITableViewController
- (instancetype)initWithVersions:(NSArray<NSString *> *)versions details:(NSArray<NSDictionary *> *)details;
@end
