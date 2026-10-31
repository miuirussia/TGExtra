#import "Headers.h"
#import "../Location.h"
#import <objc/runtime.h>

#define TGExtraLoc(key) [TGExtraLocalization localizedStringForKey:(key)]

@interface LocationSelector () <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) MKMapView *mapView;
@property(nonatomic, strong) UISearchBar *searchBar;
@property(nonatomic, strong) UITableView *searchResultsView;
@property(nonatomic, strong) UILabel *searchStatusLabel;
@property(nonatomic, strong) MKLocalSearch *localSearch;
@property(nonatomic, copy) NSArray<MKMapItem *> *searchResults;
@property(nonatomic, weak) UIAlertController *coordinatesAlert;
@end

@implementation LocationSelector

- (void)viewDidLoad {
  [super viewDidLoad];

  self.title = TGExtraLoc(@"SELECT_FAKE_LOCATION_TITLE");
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  [self setupSearch];
  [self setupMapView];
  [self setupCloseButton];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithTitle:TGExtraLoc(@"LOCATION_COORDINATES") style:UIBarButtonItemStylePlain
      target:self action:@selector(enterCoordinates)];
  [self setupMapSelectorSegment];
  [self.view bringSubviewToFront:self.searchResultsView];
  [self loadDefaultLocation];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  [self cancelSearch];
}

- (void)setupSearch {
  self.searchBar = [UISearchBar new];
  self.searchBar.delegate = self;
  self.searchBar.placeholder = TGExtraLoc(@"LOCATION_SEARCH_ADDRESS");
  self.searchBar.accessibilityLabel = TGExtraLoc(@"LOCATION_SEARCH_ADDRESS");
  self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.searchBar];

  self.searchResultsView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
  self.searchResultsView.dataSource = self;
  self.searchResultsView.delegate = self;
  self.searchResultsView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
  self.searchResultsView.rowHeight = UITableViewAutomaticDimension;
  self.searchResultsView.estimatedRowHeight = 64;
  self.searchResultsView.hidden = YES;
  self.searchResultsView.translatesAutoresizingMaskIntoConstraints = NO;
  self.searchResultsView.tableFooterView = [UIView new];
  self.searchStatusLabel = [UILabel new];
  self.searchStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  self.searchStatusLabel.adjustsFontForContentSizeCategory = YES;
  self.searchStatusLabel.textColor = UIColor.secondaryLabelColor;
  self.searchStatusLabel.textAlignment = NSTextAlignmentCenter;
  self.searchStatusLabel.numberOfLines = 0;
  self.searchResultsView.backgroundView = self.searchStatusLabel;
  [self.view addSubview:self.searchResultsView];

  [NSLayoutConstraint activateConstraints:@[
    [self.searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
    [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
    [self.searchResultsView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
    [self.searchResultsView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
    [self.searchResultsView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
    [self.searchResultsView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
  ]];
}

- (void)cancelSearch {
  [self.localSearch cancel];
  self.localSearch = nil;
  self.searchResults = @[];
  self.searchResultsView.hidden = YES;
  [self.searchResultsView reloadData];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
  [searchBar setShowsCancelButton:YES animated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
  [self cancelSearch];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
  [self cancelSearch];
  searchBar.text = @"";
  [searchBar resignFirstResponder];
  [searchBar setShowsCancelButton:NO animated:YES];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
  [self cancelSearch];
  NSString *query = [searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!query.length) return;
  [searchBar resignFirstResponder];
  self.searchResultsView.hidden = NO;
  self.searchStatusLabel.text = TGExtraLoc(@"LOCATION_SEARCHING");
  self.searchStatusLabel.hidden = NO;

  MKLocalSearchRequest *request = [MKLocalSearchRequest new];
  request.naturalLanguageQuery = query;
  request.region = self.mapView.region;
  MKLocalSearch *search = [[MKLocalSearch alloc] initWithRequest:request];
  self.localSearch = search;
  __weak typeof(self) weakSelf = self;
  __weak MKLocalSearch *weakSearch = search;
  [search startWithCompletionHandler:^(MKLocalSearchResponse *response, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (!self || !self.localSearch || self.localSearch != weakSearch) return;
      self.localSearch = nil;
      self.searchResults = response.mapItems ?: @[];
      BOOL noResults = [error.domain isEqualToString:MKErrorDomain] && error.code == MKErrorPlacemarkNotFound;
      self.searchStatusLabel.text = TGExtraLoc(error && !noResults
          ? @"LOCATION_SEARCH_FAILED" : @"LOCATION_SEARCH_EMPTY");
      self.searchStatusLabel.hidden = self.searchResults.count > 0;
      [self.searchResultsView reloadData];
    });
  }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return self.searchResults.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LocationResult"];
  if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"LocationResult"];
  MKMapItem *item = self.searchResults[indexPath.row];
  cell.textLabel.text = item.name;
  cell.detailTextLabel.text = item.placemark.title;
  cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
  cell.textLabel.adjustsFontForContentSizeCategory = YES;
  cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
  cell.textLabel.numberOfLines = 0;
  cell.detailTextLabel.numberOfLines = 0;
  cell.accessibilityTraits |= UIAccessibilityTraitButton;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  MKMapItem *item = self.searchResults[indexPath.row];
  [self searchBarCancelButtonClicked:self.searchBar];
  [self selectCoordinate:item.placemark.coordinate title:item.name centerMap:YES];
}

- (void)enterCoordinates {
  [self searchBarCancelButtonClicked:self.searchBar];
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:TGExtraLoc(@"LOCATION_COORDINATES")
      message:TGExtraLoc(@"LOCATION_COORDINATES_HINT") preferredStyle:UIAlertControllerStyleAlert];
  CLLocationCoordinate2D coordinate = kCLLocationCoordinate2DInvalid;
  BOOL hasCoordinate = TGExtraSavedCoordinate(NSUserDefaults.standardUserDefaults, &coordinate);
  [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
    field.placeholder = TGExtraLoc(@"LOCATION_LATITUDE");
    field.accessibilityLabel = field.placeholder;
    field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    if (hasCoordinate) field.text = [NSString stringWithFormat:@"%.8f", coordinate.latitude];
    [field addTarget:self action:@selector(coordinatesChanged:) forControlEvents:UIControlEventEditingChanged];
  }];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
    field.placeholder = TGExtraLoc(@"LOCATION_LONGITUDE");
    field.accessibilityLabel = field.placeholder;
    field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    if (hasCoordinate) field.text = [NSString stringWithFormat:@"%.8f", coordinate.longitude];
    [field addTarget:self action:@selector(coordinatesChanged:) forControlEvents:UIControlEventEditingChanged];
  }];
  [alert addAction:[UIAlertAction actionWithTitle:TGExtraLoc(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
  __weak typeof(self) weakSelf = self;
  __weak UIAlertController *weakAlert = alert;
  UIAlertAction *apply = [UIAlertAction actionWithTitle:TGExtraLoc(@"APPLY") style:UIAlertActionStyleDefault
      handler:^(UIAlertAction *action) {
        UIAlertController *alert = weakAlert;
        CLLocationCoordinate2D value;
        if (TGExtraParseCoordinate(alert.textFields[0].text, alert.textFields[1].text, &value)) {
          [weakSelf selectCoordinate:value title:TGExtraLoc(@"LOCATION_SELECTED") centerMap:YES];
        }
      }];
  [alert addAction:apply];
  self.coordinatesAlert = alert;
  [self coordinatesChanged:nil];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)coordinatesChanged:(UITextField *)sender {
  UIAlertController *alert = self.coordinatesAlert;
  CLLocationCoordinate2D coordinate;
  alert.actions.lastObject.enabled = TGExtraParseCoordinate(alert.textFields[0].text, alert.textFields[1].text, &coordinate);
}

- (void)setupMapView {
  self.mapView = [[MKMapView alloc] initWithFrame:CGRectZero];
  self.mapView.translatesAutoresizingMaskIntoConstraints = NO;
  self.mapView.delegate = self;
  [self.view addSubview:self.mapView];
  [NSLayoutConstraint activateConstraints:@[
    [self.mapView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
    [self.mapView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [self.mapView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [self.mapView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
  ]];

  UITapGestureRecognizer *tapGesture =
      [[UITapGestureRecognizer alloc] initWithTarget:self
                                              action:@selector(handleMapTap:)];
  [self.mapView addGestureRecognizer:tapGesture];
}

- (void)setupCloseButton {
  UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [closeButton setImage:[UIImage systemImageNamed:@"xmark.square.fill"]
               forState:UIControlStateNormal];
  closeButton.tintColor = [UIColor redColor];
  closeButton.accessibilityLabel = TGExtraLoc(@"CLOSE");
  [closeButton.widthAnchor constraintEqualToConstant:44].active = YES;
  [closeButton.heightAnchor constraintEqualToConstant:44].active = YES;
  [closeButton addTarget:self
                  action:@selector(closeButtonTapped)
        forControlEvents:UIControlEventTouchUpInside];

  UIBarButtonItem *closeBarButtonItem =
      [[UIBarButtonItem alloc] initWithCustomView:closeButton];
  self.navigationItem.leftBarButtonItem = closeBarButtonItem;
}

- (void)closeButtonTapped {
  [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)setupMapSelectorSegment {
  NSArray *mapTypes = @[ TGExtraLoc(@"LOCATION_MAP"), TGExtraLoc(@"LOCATION_SATELLITE"), TGExtraLoc(@"LOCATION_HYBRID") ];
  UISegmentedControl *segmentControl =
      [[UISegmentedControl alloc] initWithItems:mapTypes];
  segmentControl.selectedSegmentIndex = 0;

  [segmentControl addTarget:self
                     action:@selector(mapTypeChanged:)
           forControlEvents:UIControlEventValueChanged];

  segmentControl.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:segmentControl];

  [NSLayoutConstraint activateConstraints:@[
    [segmentControl.leadingAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor
                       constant:16],
    [segmentControl.trailingAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor
                       constant:-16],
    [segmentControl.bottomAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                       constant:-12],
    [segmentControl.heightAnchor constraintGreaterThanOrEqualToConstant:44]
  ]];
}

- (void)mapTypeChanged:(UISegmentedControl *)sender {
  switch (sender.selectedSegmentIndex) {
  case 0:
    self.mapView.mapType = MKMapTypeStandard;
    break;
  case 1:
    self.mapView.mapType = MKMapTypeSatellite;
    break;
  case 2:
    self.mapView.mapType = MKMapTypeHybrid;
    break;
  default:
    break;
  }
}

- (void)loadDefaultLocation {
  CLLocationCoordinate2D centerCoordinate;
  if (TGExtraSavedCoordinate(NSUserDefaults.standardUserDefaults, &centerCoordinate)) {
    [self addPinAtCoordinate:centerCoordinate
                   withTitle:TGExtraLoc(@"LOCATION_SELECTED")];
  } else {
    centerCoordinate = CLLocationCoordinate2DMake(
        37.7749, -122.4194); // Default to San Francisco
  }

  MKCoordinateRegion region =
      MKCoordinateRegionMakeWithDistance(centerCoordinate, 5000, 5000);
  [self.mapView setRegion:region animated:!UIAccessibilityIsReduceMotionEnabled()];
}

- (void)handleMapTap:(UITapGestureRecognizer *)gesture {
  CGPoint touchPoint = [gesture locationInView:self.mapView];

  CLLocationCoordinate2D coordinate = [self.mapView convertPoint:touchPoint
                                            toCoordinateFromView:self.mapView];

  [self.view endEditing:YES];
  [self selectCoordinate:coordinate title:TGExtraLoc(@"LOCATION_SELECTED") centerMap:NO];
}

- (void)selectCoordinate:(CLLocationCoordinate2D)coordinate title:(NSString *)title centerMap:(BOOL)centerMap {
  if (!CLLocationCoordinate2DIsValid(coordinate)) return;
  [self addPinAtCoordinate:coordinate withTitle:title];
  if (centerMap) {
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 1000, 1000)
                  animated:!UIAccessibilityIsReduceMotionEnabled()];
  }

  [[NSUserDefaults standardUserDefaults] setDouble:coordinate.longitude
                                           forKey:FAKE_LONGITUDE_KEY];
  [[NSUserDefaults standardUserDefaults] setDouble:coordinate.latitude
                                           forKey:FAKE_LATITUDE_KEY];
  TGExtraSavePreferences();
  [[NSUserDefaults standardUserDefaults] synchronize];

  [[NSNotificationCenter defaultCenter]
      postNotificationName:@"TGExtraLocationChanged"
                    object:nil];
}

- (void)addPinAtCoordinate:(CLLocationCoordinate2D)coordinate
                 withTitle:(NSString *)title {
  MKPointAnnotation *annotation = [[MKPointAnnotation alloc] init];
  annotation.coordinate = coordinate;
  annotation.title = title;

  [self.mapView removeAnnotations:self.mapView.annotations];
  [self.mapView addAnnotation:annotation];
}

@end
