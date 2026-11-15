#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// The native responder is also the input and checking client. Declaring this
// conformance in Objective-C lets NSView's candidateListTouchBarItem getter
// satisfy the protocol without a conflicting Swift method declaration.
// Abstract: the document subclass supplies every method below.
@interface YabTextCheckingView : NSView <NSTextCheckingClient>
- (void)insertText:(id)value replacementRange:(NSRange)range NS_SWIFT_NAME(insertText(_:replacementRange:));
- (void)setMarkedText:(id)value selectedRange:(NSRange)selection replacementRange:(NSRange)range NS_SWIFT_NAME(setMarkedText(_:selectedRange:replacementRange:));
- (void)unmarkText NS_SWIFT_NAME(unmarkText());
- (NSRange)selectedRange NS_SWIFT_NAME(selectedRange());
- (NSRange)markedRange NS_SWIFT_NAME(markedRange());
- (BOOL)hasMarkedText NS_SWIFT_NAME(hasMarkedText());
- (nullable NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(nullable NSRangePointer)actual NS_SWIFT_NAME(attributedSubstring(forProposedRange:actualRange:));
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText NS_SWIFT_NAME(validAttributesForMarkedText());
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(nullable NSRangePointer)actual NS_SWIFT_NAME(firstRect(forCharacterRange:actualRange:));
- (NSUInteger)characterIndexForPoint:(NSPoint)point NS_SWIFT_NAME(characterIndex(for:));
- (nullable NSAttributedString *)annotatedSubstringForProposedRange:(NSRange)range actualRange:(nullable NSRangePointer)actual NS_SWIFT_NAME(annotatedSubstring(forProposedRange:actualRange:));
- (void)setAnnotations:(NSDictionary<NSAttributedStringKey, NSString *> *)annotations range:(NSRange)range NS_SWIFT_NAME(setAnnotations(_:range:));
- (void)addAnnotations:(NSDictionary<NSAttributedStringKey, NSString *> *)annotations range:(NSRange)range NS_SWIFT_NAME(addAnnotations(_:range:));
- (void)removeAnnotation:(NSAttributedStringKey)name range:(NSRange)range NS_SWIFT_NAME(removeAnnotation(_:range:));
- (void)replaceCharactersInRange:(NSRange)range withAnnotatedString:(NSAttributedString *)text NS_SWIFT_NAME(replaceCharacters(in:withAnnotatedString:));
- (void)selectAndShowRange:(NSRange)range NS_SWIFT_NAME(selectAndShow(_:));
- (nullable NSView *)viewForRange:(NSRange)range firstRect:(nullable NSRectPointer)rect actualRange:(nullable NSRangePointer)actual NS_SWIFT_NAME(view(for:firstRect:actualRange:));
@end

NS_ASSUME_NONNULL_END
