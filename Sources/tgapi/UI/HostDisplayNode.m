#import "HostDisplayNode.h"
ASDisplayNode *TGExtraFindDisplayNode(ASDisplayNode *root, NSString *prefix) {
    if (!root) return nil;
    if ([NSStringFromClass([root class]) containsString:prefix]) {
        return root;
    }
    @try {
        NSArray *subs = root.subnodes;
        for (ASDisplayNode *child in subs) {
            ASDisplayNode *found = TGExtraFindDisplayNode(child, prefix);
            if (found) return found;
        }
    } @catch (NSException *e) {}
    return nil;
}
