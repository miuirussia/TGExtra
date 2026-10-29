#import "EditHistoryDiff.h"

static NSArray<NSString *> *tgextraDiffTokens(NSString *text) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    __block NSUInteger end = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByWords
        usingBlock:^(NSString *word, NSRange range, NSRange enclosingRange, BOOL *stop) {
            if (range.location > end) [tokens addObject:[text substringWithRange:NSMakeRange(end, range.location - end)]];
            [tokens addObject:word];
            end = NSMaxRange(range);
        }];
    if (end < text.length) [tokens addObject:[text substringFromIndex:end]];
    return tokens;
}

static void tgextraAppendDiffRun(NSMutableArray *runs, NSString *kind, NSString *text) {
    if (text.length == 0) return;
    NSMutableDictionary *last = runs.lastObject;
    if ([last[@"kind"] isEqualToString:kind]) {
        [last[@"text"] appendString:text];
    } else {
        [runs addObject:[@{@"kind": kind, @"text": [text mutableCopy]} mutableCopy]];
    }
}

NSArray<NSDictionary<NSString *, NSString *> *> *TGExtraTextDiff(NSString *before, NSString *after) {
    NSArray<NSString *> *old = tgextraDiffTokens(before);
    NSArray<NSString *> *new = tgextraDiffTokens(after);
    NSMutableArray *runs = [NSMutableArray array];
    NSUInteger prefix = 0, suffix = 0;
    while (prefix < old.count && prefix < new.count && [old[prefix] isEqualToString:new[prefix]]) prefix++;
    while (suffix < old.count - prefix && suffix < new.count - prefix &&
           [old[old.count - suffix - 1] isEqualToString:new[new.count - suffix - 1]]) suffix++;
    for (NSUInteger i = 0; i < prefix; i++) tgextraAppendDiffRun(runs, @"equal", old[i]);

    NSUInteger oldCount = old.count - prefix - suffix, newCount = new.count - prefix - suffix;
    // Bound work on the UI thread even for very large, completely replaced messages.
    NSUInteger columns = newCount + 1;
    uint32_t *lengths = NULL;
    if (oldCount && newCount && oldCount + 1 <= 250000 / columns) {
        lengths = calloc((oldCount + 1) * columns, sizeof(uint32_t));
    }
    if (lengths) {
        for (NSUInteger i = oldCount; i-- > 0;) {
            for (NSUInteger j = newCount; j-- > 0;) {
                lengths[i * columns + j] = [old[prefix + i] isEqualToString:new[prefix + j]]
                    ? 1 + lengths[(i + 1) * columns + j + 1]
                    : MAX(lengths[(i + 1) * columns + j], lengths[i * columns + j + 1]);
            }
        }
        NSUInteger i = 0, j = 0;
        while (i < oldCount || j < newCount) {
            if (i < oldCount && j < newCount && [old[prefix + i] isEqualToString:new[prefix + j]]) {
                tgextraAppendDiffRun(runs, @"equal", old[prefix + i]);
                i++; j++;
            } else if (i < oldCount && (j == newCount || lengths[(i + 1) * columns + j] >= lengths[i * columns + j + 1])) {
                tgextraAppendDiffRun(runs, @"delete", old[prefix + i++]);
            } else {
                tgextraAppendDiffRun(runs, @"insert", new[prefix + j++]);
            }
        }
        free(lengths);
    } else {
        for (NSUInteger i = 0; i < oldCount; i++) tgextraAppendDiffRun(runs, @"delete", old[prefix + i]);
        for (NSUInteger j = 0; j < newCount; j++) tgextraAppendDiffRun(runs, @"insert", new[prefix + j]);
    }
    for (NSUInteger i = old.count - suffix; i < old.count; i++) tgextraAppendDiffRun(runs, @"equal", old[i]);
    return runs;
}
