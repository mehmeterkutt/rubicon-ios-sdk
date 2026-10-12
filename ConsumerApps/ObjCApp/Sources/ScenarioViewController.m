#import "ScenarioViewController.h"

@interface ScenarioViewController ()
@property (nonatomic, strong) RBNAnalytics *analytics;
@property (nonatomic, strong) UILabel *queuedLabel;
@property (nonatomic, strong) UILabel *sentLabel;
@property (nonatomic, strong) UILabel *droppedLabel;
@property (nonatomic, strong) UILabel *deviceLabel;
@property (nonatomic, strong) UILabel *noteLabel;
@property (nonatomic, assign) NSInteger queued;
@property (nonatomic, assign) NSInteger sent;
@property (nonatomic, assign) NSInteger dropped;
@end

static __weak ScenarioViewController *gCurrent;

@implementation ScenarioViewController

+ (ScenarioViewController *)current {
    return gCurrent;
}

- (instancetype)initWithAnalytics:(RBNAnalytics *)analytics {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _analytics = analytics;
        gCurrent = self;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.queuedLabel = [self labelWithIdentifier:@"queued"];
    self.sentLabel = [self labelWithIdentifier:@"sent"];
    self.droppedLabel = [self labelWithIdentifier:@"dropped"];
    self.deviceLabel = [self labelWithIdentifier:@"device-id"];
    self.noteLabel = [self labelWithIdentifier:@"note"];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.queuedLabel, self.sentLabel, self.droppedLabel, self.deviceLabel, self.noteLabel,
        [self buttonWithTitle:@"Track" identifier:@"track" action:@selector(track)],
        [self buttonWithTitle:@"Flush" identifier:@"flush" action:@selector(flush)],
        [self buttonWithTitle:@"Second instance" identifier:@"second-instance" action:@selector(secondInstance)],
        [self buttonWithTitle:@"Opt out" identifier:@"opt-out" action:@selector(optOut)],
        [self buttonWithTitle:@"Opt in" identifier:@"opt-in" action:@selector(optIn)],
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
    ]];
    self.deviceLabel.text = self.analytics.deviceId;
    [self render];
}

- (void)applyUpdate:(RBNEventUpdate *)update {
    switch (update.kind) {
    case RBNEventUpdateKindQueued: self.queued += 1; break;
    case RBNEventUpdateKindSent: self.sent += update.messageIds.count; break;
    case RBNEventUpdateKindDropped: self.dropped += update.messageIds.count; break;
    }
    [self render];
}

- (void)render {
    self.queuedLabel.text = [NSString stringWithFormat:@"queued %ld", (long)self.queued];
    self.sentLabel.text = [NSString stringWithFormat:@"sent %ld", (long)self.sent];
    self.droppedLabel.text = [NSString stringWithFormat:@"dropped %ld", (long)self.dropped];
}

- (void)track {
    [self.analytics trackEvent:@"Button Tapped" properties:@{@"count": @(self.queued + 1), @"flag": @YES}];
}

- (void)flush {
    [self.analytics flush];
}

- (void)secondInstance {
    RBNConfiguration *other = [[RBNConfiguration alloc] initWithApiKey:@"rk_other"];
    other.debug = NO;
    RBNAnalytics *again = [RBNAnalytics makeWithConfiguration:other];
    self.noteLabel.text = again == self.analytics ? @"same instance" : @"another instance";
}

- (void)optOut {
    [self.analytics optOut];
    self.noteLabel.text = self.analytics.isOptedOut ? @"opted out" : @"opted in";
}

- (void)optIn {
    [self.analytics optIn];
    self.noteLabel.text = self.analytics.isOptedOut ? @"opted out" : @"opted in";
}

- (UILabel *)labelWithIdentifier:(NSString *)identifier {
    UILabel *label = [[UILabel alloc] init];
    label.accessibilityIdentifier = identifier;
    label.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    label.adjustsFontSizeToFitWidth = YES;
    return label;
}

- (UIButton *)buttonWithTitle:(NSString *)title identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.accessibilityIdentifier = identifier;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

@end
