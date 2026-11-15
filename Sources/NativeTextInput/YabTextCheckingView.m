#import "YabTextCheckingView.h"

// An omitted document override is an implementation error, never an empty
// document or an accepted edit. NSResponder already supplies doCommandBySelector:
// and NSView supplies candidateListTouchBarItem.
@implementation YabTextCheckingView
- (void)insertText:(id)value replacementRange:(NSRange)range { [self doesNotRecognizeSelector:_cmd]; }
- (void)setMarkedText:(id)value selectedRange:(NSRange)selection replacementRange:(NSRange)range { [self doesNotRecognizeSelector:_cmd]; }
- (void)unmarkText { [self doesNotRecognizeSelector:_cmd]; }
- (NSRange)selectedRange { [self doesNotRecognizeSelector:_cmd]; return NSMakeRange(NSNotFound, 0); }
- (NSRange)markedRange { [self doesNotRecognizeSelector:_cmd]; return NSMakeRange(NSNotFound, 0); }
- (BOOL)hasMarkedText { [self doesNotRecognizeSelector:_cmd]; return NO; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual { [self doesNotRecognizeSelector:_cmd]; return nil; }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { [self doesNotRecognizeSelector:_cmd]; return @[]; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual { [self doesNotRecognizeSelector:_cmd]; return NSZeroRect; }
- (NSUInteger)characterIndexForPoint:(NSPoint)point { [self doesNotRecognizeSelector:_cmd]; return NSNotFound; }
- (NSAttributedString *)annotatedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual { [self doesNotRecognizeSelector:_cmd]; return nil; }
- (void)setAnnotations:(NSDictionary<NSAttributedStringKey, NSString *> *)annotations range:(NSRange)range { [self doesNotRecognizeSelector:_cmd]; }
- (void)addAnnotations:(NSDictionary<NSAttributedStringKey, NSString *> *)annotations range:(NSRange)range { [self doesNotRecognizeSelector:_cmd]; }
- (void)removeAnnotation:(NSAttributedStringKey)name range:(NSRange)range { [self doesNotRecognizeSelector:_cmd]; }
- (void)replaceCharactersInRange:(NSRange)range withAnnotatedString:(NSAttributedString *)text { [self doesNotRecognizeSelector:_cmd]; }
- (void)selectAndShowRange:(NSRange)range { [self doesNotRecognizeSelector:_cmd]; }
- (NSView *)viewForRange:(NSRange)range firstRect:(NSRectPointer)rect actualRange:(NSRangePointer)actual { [self doesNotRecognizeSelector:_cmd]; return nil; }
@end
