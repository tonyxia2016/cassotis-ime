#pragma once
#import <AppKit/AppKit.h>
#include "EngineClient.hpp"

NSString *CassotisCustomPhrasePreview(NSString *text);
BOOL CassotisParseCustomPhrases(NSData *data, std::vector<cassotis::CustomPhrase> &phrases, NSString **error);
NSData *CassotisCustomPhraseJSON(const std::vector<cassotis::CustomPhrase> &phrases);

@interface CassotisCustomPhraseEditor : NSView
@property(nonatomic, copy) BOOL (^savePhrases)(const std::vector<cassotis::CustomPhrase> &);
@property(nonatomic) BOOL enabled;
- (void)setPhrases:(const std::vector<cassotis::CustomPhrase> &)phrases;
- (BOOL)submitDraft;
- (void)cancelDraft;
@end
