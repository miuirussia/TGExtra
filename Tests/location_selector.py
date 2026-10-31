#!/usr/bin/env python3
"""Exercise location input, search cancellation and selection with real UIKit."""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

if sys.platform != 'darwin':
    print('SKIP location selector: Mac Catalyst requires macOS')
    sys.exit(0)

ROOT = Path(__file__).resolve().parent.parent
sdk = Path(subprocess.check_output(
    ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
frameworks = sdk / 'System/iOSSupport/System/Library/Frameworks'
if not (frameworks / 'UIKit.framework/Headers/UIKit.h').exists():
    print('SKIP location selector: Mac Catalyst SDK unavailable')
    sys.exit(0)

HARNESS = r'''
#import "LocationSelector.m"
static NSUInteger saves, notifications;
BOOL TGExtraSavePreferences(void) { saves++; return YES; }
@implementation TGExtraLocalization
+ (instancetype)shared { return nil; }
+ (NSString *)localizedStringForKey:(NSString *)key { return key; }
@end

// Keep MapKit requests deterministic and deliver cancelled callbacks deliberately.
static NSMutableArray<MKLocalSearch *> *searches;
static char callbackKey, cancelledKey, actionKey;
@interface MKLocalSearch (TestSearch)
- (void)testStart:(MKLocalSearchCompletionHandler)callback;
- (void)testCancel;
@end
@implementation MKLocalSearch (TestSearch)
- (void)testStart:(MKLocalSearchCompletionHandler)callback {
    objc_setAssociatedObject(self, &callbackKey, callback, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [searches addObject:self];
}
- (void)testCancel { objc_setAssociatedObject(self, &cancelledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
@end
@interface UIAlertAction (TestAction)
+ (instancetype)testActionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler;
@end
@implementation UIAlertAction (TestAction)
+ (instancetype)testActionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler {
    UIAlertAction *action = [self testActionWithTitle:title style:style handler:handler];
    objc_setAssociatedObject(action, &actionKey, handler, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return action;
}
@end
@interface SearchResponse : MKLocalSearchResponse
@property(nonatomic, copy) NSArray<MKMapItem *> *items;
@end
@implementation SearchResponse
- (NSArray<MKMapItem *> *)mapItems { return self.items; }
@end
@interface LocationProbe : LocationSelector
@property(nonatomic, strong) UIAlertController *alert;
@end
@implementation LocationProbe
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    self.alert = (UIAlertController *)controller;
    if (completion) completion();
}
@end
static void finish(MKLocalSearch *search, NSArray<MKMapItem *> *items, NSError *error) {
    SearchResponse *response = [SearchResponse new];
    response.items = items;
    MKLocalSearchCompletionHandler callback = objc_getAssociatedObject(search, &callbackKey);
    callback(error ? nil : response, error);
    // The production callback dispatches its UI work to the main queue.
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
static void submit(LocationProbe *selector, NSString *query) {
    selector.searchBar.text = query;
    [selector searchBarSearchButtonClicked:selector.searchBar];
}
int main(void) { @autoreleasepool {
    CLLocationCoordinate2D value;
    for (NSArray *pair in @[@[@"55.7558", @"37.6173"], @[@" -33,8688 ", @"151,2093"],
                            @[@"0", @"0"], @[@"-90", @"180"], @[@"90", @"-180"]]) {
        NSCAssert(TGExtraParseCoordinate(pair[0], pair[1], &value), @"Accept valid signed, decimal and boundary coordinates");
    }
    NSCAssert(TGExtraParseCoordinate(@" -33,8688 ", @"151,2093", &value) &&
              fabs(value.latitude + 33.8688) < 0.000001 && fabs(value.longitude - 151.2093) < 0.000001,
              @"Interpret commas as decimal separators without losing signs");
    for (NSArray *pair in @[@[@"", @"0"], @[@" ", @"0"], @[@"91", @"0"], @[@"0", @"181"],
                            @[@"-90.0001", @"0"], @[@"0", @"-180.0001"], @[@"nan", @"0"],
                            @[@"0", @"inf"], @[@"1.2.3", @"0"], @[@"1,2,3", @"0"],
                            @[@"12x", @"0"], @[@"1 2", @"0"], @[@"--1", @"0"], @[@"+", @"0"]]) {
        NSCAssert(!TGExtraParseCoordinate(pair[0], pair[1], &value), @"Reject incomplete, malformed, nonfinite and out-of-range input");
    }
    method_exchangeImplementations(class_getInstanceMethod(MKLocalSearch.class, @selector(startWithCompletionHandler:)),
                                   class_getInstanceMethod(MKLocalSearch.class, @selector(testStart:)));
    method_exchangeImplementations(class_getInstanceMethod(MKLocalSearch.class, @selector(cancel)),
                                   class_getInstanceMethod(MKLocalSearch.class, @selector(testCancel)));
    method_exchangeImplementations(class_getClassMethod(UIAlertAction.class, @selector(actionWithTitle:style:handler:)),
                                   class_getClassMethod(UIAlertAction.class, @selector(testActionWithTitle:style:handler:)));
    searches = [NSMutableArray new];
    // Isolate defaults from the developer's Telegram/tweak settings.
    NSString *suite = NSUUID.UUID.UUIDString;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    method_setImplementation(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)),
                             imp_implementationWithBlock(^id(id cls) { return defaults; }));
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:@"TGExtraLocationChanged"
        object:nil queue:nil usingBlock:^(NSNotification *note) { notifications++; }];
    LocationProbe *selector = [LocationProbe new];
    [selector loadViewIfNeeded];
    selector.view.frame = CGRectMake(0, 0, 375, 812);
    [selector.view layoutIfNeeded];
    NSCAssert(selector.mapView.frame.size.height > 0 && selector.searchBar.frame.size.height >= 44,
              @"Map and search lay out on a small phone");
    NSCAssert(selector.searchResultsView.hidden && saves == 0, @"Opening the map does not change the location");
    [selector enterCoordinates];
    NSCAssert(!selector.alert.actions.lastObject.enabled, @"Empty input cannot be applied");
    selector.alert.textFields[0].text = @"-33,8688";
    selector.alert.textFields[1].text = @"151.2093";
    [selector coordinatesChanged:nil];
    NSCAssert(selector.alert.actions.lastObject.enabled, @"Both valid fields enable Apply");
    selector.alert.textFields[1].text = @"181";
    [selector coordinatesChanged:nil];
    NSCAssert(!selector.alert.actions.lastObject.enabled && saves == 0, @"Invalid input never saves");
    selector.alert.textFields[1].text = @"151.2093";
    [selector coordinatesChanged:nil];
    UIAlertAction *apply = selector.alert.actions.lastObject;
    void (^handler)(UIAlertAction *) = objc_getAssociatedObject(apply, &actionKey);
    handler(apply);
    NSCAssert(TGExtraSavedCoordinate(defaults, &value) && fabs(value.latitude + 33.8688) < 0.000001 &&
              saves == 1 && notifications == 1 && selector.mapView.annotations.count == 1,
              @"Manual selection persists, replaces the pin and notifies Telegram");
    [selector enterCoordinates];
    NSCAssert([selector.alert.textFields[0].text isEqual:@"-33.86880000"], @"Reopening pre-fills saved coordinates");
    submit(selector, @"   ");
    NSCAssert(searches.count == 0, @"Whitespace does not start a network request");
    submit(selector, @"First address");
    MKLocalSearch *oldSearch = searches.lastObject;
    NSCAssert(!selector.searchResultsView.hidden && !selector.searchStatusLabel.hidden,
              @"Search shows progress");
    [selector searchBar:selector.searchBar textDidChange:@"Second address"];
    NSCAssert([objc_getAssociatedObject(oldSearch, &cancelledKey) boolValue] && selector.searchResultsView.hidden,
              @"Changing input cancels and hides stale results");
    submit(selector, @"Second address");
    MKLocalSearch *newSearch = searches.lastObject;
    MKMapItem *item = [[MKMapItem alloc] initWithPlacemark:[[MKPlacemark alloc]
        initWithCoordinate:CLLocationCoordinate2DMake(55.7558, 37.6173)]];
    item.name = @"Test address";
    finish(oldSearch, @[item], nil);
    NSCAssert(selector.localSearch == newSearch && selector.searchResults.count == 0,
              @"A late cancelled response cannot replace the active search");
    finish(newSearch, @[item], nil);
    NSCAssert(selector.searchResults.count == 1 && selector.searchStatusLabel.hidden && saves == 1,
              @"Results alone do not change the saved location");
    [selector tableView:selector.searchResultsView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    NSCAssert(TGExtraSavedCoordinate(defaults, &value) && fabs(value.longitude - 37.6173) < 0.000001 &&
              selector.searchResultsView.hidden && saves == 2 && notifications == 2,
              @"Choosing an address saves its coordinates and returns to the map");
    submit(selector, @"Unknown address");
    finish(searches.lastObject, @[], nil);
    NSCAssert([selector.searchStatusLabel.text isEqual:@"LOCATION_SEARCH_EMPTY"], @"Empty results have useful feedback");
    submit(selector, @"Offline address");
    finish(searches.lastObject, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]);
    NSCAssert([selector.searchStatusLabel.text isEqual:@"LOCATION_SEARCH_FAILED"], @"Network failures allow retry");
    submit(selector, @"Cancelled address");
    MKLocalSearch *cancelledSearch = searches.lastObject;
    [selector searchBarCancelButtonClicked:selector.searchBar];
    finish(cancelledSearch, @[item], nil);
    NSCAssert(selector.searchResultsView.hidden && selector.searchResults.count == 0 && saves == 2,
              @"Cancel restores the map and ignores late callbacks");
    submit(selector, @"Closing address");
    [selector viewWillDisappear:NO];
    NSCAssert(selector.localSearch == nil && [objc_getAssociatedObject(searches.lastObject, &cancelledKey) boolValue],
              @"Leaving the screen cancels pending work");
    selector.view.frame = CGRectMake(0, 0, 812, 375);
    [selector.view layoutIfNeeded];
    NSCAssert(selector.mapView.frame.size.width == 812 && selector.mapView.frame.size.height > 0,
              @"The map resizes in landscape");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    [defaults removePersistentDomainForName:suite];
    puts("PASS location parsing, manual entry, address selection, cancellation, stale responses, errors and adaptive layout");
} return 0; }
'''

with tempfile.TemporaryDirectory(prefix='tgextra-location-') as directory:
    directory = Path(directory)
    (directory / 'roothide.h').write_text('#define jbroot(path) (path)\n')
    main = directory / 'main.m'
    main.write_text(HARNESS)
    binary = directory / 'tests'
    subprocess.run([
        'xcrun', 'clang', '-target', f'{platform.machine()}-apple-ios15.0-macabi',
        '-isysroot', str(sdk), '-iframework', str(frameworks), '-F', str(frameworks),
        '-fobjc-arc', '-Werror', '-Wno-deprecated-declarations',
        '-I', str(directory), '-I', str(ROOT / 'Sources/tgapi/UI'),
        '-framework', 'UIKit', '-framework', 'Foundation', '-framework', 'MapKit',
        '-framework', 'CoreLocation', '-framework', 'CoreGraphics',
        '-Wl,-rpath,/System/iOSSupport/System/Library/Frameworks',
        str(main), '-o', str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
