#import <UIKit/UIKit.h>

#import "VideoPlayerViewController.h"

#import "GCSVideoView.h"

@interface VideoPlayerViewController () <GCSVideoViewDelegate>

@end

static const CGFloat kMargin = 16;
static const CGFloat kVideoViewHeight = 250;

@implementation VideoPlayerViewController {
  GCSVideoView *_videoView;
  UIScrollView *_scrollView;
  UILabel *_titleLabel;
  UILabel *_subtitleLabel;
  UILabel *_preambleLabel;
  UILabel *_postambleLabel;
  UITextView *_attributionTextView;
  BOOL _isPaused;
}

- (instancetype)init {
  self = [super initWithNibName:nil bundle:nil];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  self.title = @"Video";
  self.view.backgroundColor = [UIColor whiteColor];

  _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
  _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:_scrollView];

  _titleLabel = [self createLabelWithFontSize:20 bold:YES text:@"Gorillas"];
  [_scrollView addSubview:_titleLabel];

  _subtitleLabel = [self createLabelWithFontSize:14 text:@"The great apes from Central Africa"];
  _subtitleLabel.textColor = [UIColor darkGrayColor];
  [_scrollView addSubview:_subtitleLabel];

  _preambleLabel =
  [self createLabelWithFontSize:16
                           text:@"Gorillas are ground-dwelling, predominantly "
      @"herbivorous apes that inhabit the forests of central Africa.\n\n"
      @"The 360 video below shows gorillas in the Congo rainforest."];
  [_scrollView addSubview:_preambleLabel];

  // Create a |GCSVideoView| and position in it in the top half of the view.
  _videoView = [[GCSVideoView alloc]
      initWithFrame:CGRectMake(16, 32, self.view.bounds.size.width - 32, 200)];
  _videoView.delegate = self;
  _videoView.enableFullscreenButton = YES;
  _videoView.enableCardboardButton = YES;

  [_scrollView addSubview:_videoView];

  _postambleLabel =
  [self createLabelWithFontSize:16
                           text:@"The eponymous genus Gorilla is divided into "
      @"species: the eastern gorillas and the western gorillas, and either four or "
      @"five subspecies. They are the largest living primates by physical size.\n\n"
      @"The DNA of gorillas is highly similar to that of humans, from 95–99%"
      @"depending on what is counted, and they are the next closest living  "
      @"relatives to humans after the chimpanzees and bonobos.\n\n"
      @"Gorillas\' natural habitats cover tropical or subtropical forests in Africa."
      @" Although their range covers a small percentage of Africa, gorillas cover a "
      @"wide range of elevations. The mountain gorilla inhabits the Albertine Rift "
      @"montane cloud forests of the Virunga Volcanoes, ranging in altitude "
      @"from 2,200–4,300 metres (7,200–14,100 ft). Lowland gorillas live in dense "
      @"forests and lowland swamps and marshes as low as sea level, with western "
      @"lowland gorillas living in Central West African countries and eastern "
      @"lowland gorillas living in the Democratic Republic of the Congo near its "
      @"border with Rwanda."];
  [_scrollView addSubview:_postambleLabel];

  // Build source attribution text view.
  NSString *sourceText = @"Source: ";
  NSMutableAttributedString *attributedText = [[NSMutableAttributedString alloc]
      initWithString:[sourceText stringByAppendingString:@"Wikipedia"]];
  [attributedText
      addAttribute:NSLinkAttributeName
             value:@"https://en.wikipedia.org/wiki/Gorilla"
             range:NSMakeRange(sourceText.length, attributedText.length - sourceText.length)];

  _attributionTextView = [[UITextView alloc] init];
  _attributionTextView.editable = NO;
  _attributionTextView.attributedText = attributedText;
  _attributionTextView.font = [UIFont systemFontOfSize:16];
  [_scrollView addSubview:_attributionTextView];

  _isPaused = NO;

  NSString *videoPath = [[NSBundle mainBundle] pathForResource:@"congo" ofType:@"mp4"];
  [_videoView loadFromUrl:[[NSURL alloc] initFileURLWithPath:videoPath]];
}

- (void)viewWillLayoutSubviews {
  [super viewWillLayoutSubviews];

  [self setFrameForView:_titleLabel belowView:nil margin:kMargin];
  [self setFrameForView:_subtitleLabel belowView:_titleLabel margin:kMargin];
  [self setFrameForView:_preambleLabel belowView:_subtitleLabel margin:kMargin];
  [self setFrameForView:_attributionTextView belowView:_postambleLabel margin:kMargin];

  _videoView.frame = CGRectMake(kMargin,
                                CGRectGetMaxY(_preambleLabel.frame) + kMargin,
                                CGRectGetWidth(self.view.bounds) - 2 * kMargin,
                                kVideoViewHeight);
  [self setFrameForView:_postambleLabel belowView:_videoView margin:kMargin];

  _scrollView.contentSize = CGSizeMake(CGRectGetWidth(self.view.bounds),
                                       CGRectGetMaxY(_attributionTextView.frame) + kMargin);
}

#pragma mark - GCSVideoViewDelegate

- (void)widgetViewDidTap:(GCSWidgetView *)widgetView {
  if (_isPaused) {
    [_videoView resume];
  } else {
    [_videoView pause];
  }
  _isPaused = !_isPaused;
}

- (void)videoView:(GCSVideoView*)videoView didUpdatePosition:(NSTimeInterval)position {
  // Rewind to beginning of the video when it reaches the end.
  if (position == videoView.duration) {
    _isPaused = YES;
    [_videoView seekTo:0];
  }
}

#pragma mark - Implementation

- (UILabel *)createLabelWithFontSize:(CGFloat)fontSize text:(NSString *)text {
  return [self createLabelWithFontSize:fontSize bold:NO text:text];
}

- (UILabel *)createLabelWithFontSize:(CGFloat)fontSize bold:(BOOL)bold text:(NSString *)text {
  UILabel *label = [[UILabel alloc] init];
  label.text = text;
  label.font = (bold ? [UIFont boldSystemFontOfSize:fontSize] : [UIFont systemFontOfSize:fontSize]);
  label.numberOfLines = 0;
  return label;
}

- (void)setFrameForView:(UIView *)view belowView:(UIView *)topView margin:(CGFloat)margin {
  CGSize size =
      [view sizeThatFits:CGSizeMake(CGRectGetWidth(self.view.bounds) - 2 * kMargin, CGFLOAT_MAX)];
  view.frame = CGRectMake(kMargin, CGRectGetMaxY(topView.frame) + margin, size.width, size.height);
}

@end
