#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Objective-C face of EngineClient + replay.cpp for the Swift keyboard. Every
// instance method must run on the one engine thread (see cassotis_core.h);
// the class methods are safe anywhere.
@interface CassotisKeyResult : NSObject
@property(nonatomic, copy) NSString *preedit;
@property(nonatomic, copy) NSString *commit;
@property(nonatomic, copy) NSArray<NSString *> *candidates;
@property(nonatomic) BOOL handled;
// The engine has more for this key: poll when idle (char_lm_deferred).
@property(nonatomic) BOOL pending;
// The engine's candidate page and page count: more pages follow when
// pages > page + 1 (candidatesFrom:count:end: reads them).
@property(nonatomic) int32_t page;
@property(nonatomic) int32_t pages;
// With the engine's debug mode on: the left context it ranked with, and whether
// the host reported any. Test runs read these; typing never turns debug on.
@property(nonatomic, copy) NSString *debugContext;
@property(nonatomic) BOOL debugContextReported;
@end

@interface EngineBridge : NSObject
+ (uint64_t)footprint;
+ (uint64_t)footprintPeak;
+ (uint64_t)available;
// Before the engine opens; see cassotis_core_set_option.
+ (void)setOption:(NSString *)name value:(int32_t)value;
// cassotis_core_interrupt: safe on any thread while the engine thread polls.
+ (void)interrupt;
// Applies the keyboard's memory policy, then any cache=/sqlite=/mmap=/ondemand=/
// prewarm= overrides from a run's options; lm=0 opens the engine without the
// character LM, defer=0 ranks with it inside every key instead of on the next
// poll (char_lm_deferred), det=1 sets deterministic_search.
+ (void)applyMemoryPolicy:(NSDictionary<NSString *, NSString *> *)options;
// Returns nil on success, otherwise the error text.
- (nullable NSString *)openDictionary:(NSString *)dictionary
                       userDictionary:(NSString *)userDictionary
                            resources:(NSString *)resources
                                 data:(NSString *)data;
- (CassotisKeyResult *)pressText:(NSString *)text;
- (CassotisKeyResult *)pressSpecial:(uint16_t)special;
// The candidates of the last result, then the pages after it, as one list that
// scrolls: candidates start..start+count, reading pages from the engine as
// needed (read-only, so space still takes the first one and the deferred
// model ranking still applies). end: nothing after these.
- (NSArray<NSString *> *)candidatesFrom:(int32_t)start count:(int32_t)count end:(BOOL *)end;
// Picks the index-th candidate of that list: pages the engine there if it is
// past the first page, then presses its digit. nil when the engine could not
// reach that page, so nothing changed.
- (nullable CassotisKeyResult *)selectCandidate:(int32_t)index;
// The text before the caret, for context ranking and learning; nil when the
// host does not report it (a secure field, say), which clears the old one.
- (void)setLeftContext:(nullable NSString *)text;
// Whether the last result left a composition open, as the engine sees it. The
// main thread's copy lags while keys are queued.
@property(nonatomic, readonly) BOOL composing;
// Whether a digit would pick a candidate now (composing, 1–9 select). A digit on
// the screen is meant as a digit, so the keyboard commits the composition first;
// quick input that reads digits (selection keys abcd or none) keeps them.
@property(nonatomic, readonly) BOOL digitsSelect;
// precedingDigit: the ASCII digit before the caret, or 0, so that '.' after a
// digit stays a decimal point (decimal_period_after_digit).
- (CassotisKeyResult *)pressText:(NSString *)text precedingDigit:(uint16_t)digit;
// Commits what is composed, as macOS does when focus moves: space until nothing
// is left. The result's commit holds all of it; nil when nothing was composed.
- (nullable CassotisKeyResult *)commitComposition;
// The engine's input mode: 0 Chinese, 1 English; -1 when it cannot say.
- (int32_t)inputMode;
// Switches it; the engine drops the composition, so commit that first.
- (void)setInputMode:(int32_t)mode;
- (void)resetComposition;
// The candidates of the last key, ranked with the character LM; handled is NO
// when there is nothing new (a newer key, or nothing was pending).
- (CassotisKeyResult *)poll;
- (void)trim:(int32_t)level;
// The engine's debug mode (a saved setting): results then carry debugContext.
- (void)setDebugMode:(BOOL)on;
// cassotis_core_model_state: starts the character LM's load and waits up to
// timeoutMs; 1 ready, 0 loading, -1 none (modelError says why). The next
// replay reports the answer and the wait.
- (int32_t)waitForModel:(uint32_t)timeoutMs;
- (NSString *)modelError;
// Runs replay.cpp and returns its JSON. onKey runs on the engine thread after
// every key with the result; onSample lets the caller stop the run.
- (NSString *)replayCorpus:(NSString *)corpus
                     label:(NSString *)label
                   maxKeys:(uint32_t)maxKeys
                maxSeconds:(uint64_t)maxSeconds
                 paceMicros:(uint32_t)paceMicros
                sampleEvery:(uint32_t)sampleEvery
                useContext:(BOOL)useContext
                      loop:(BOOL)loop
                      poll:(BOOL)poll
                 digestPath:(nullable NSString *)digestPath
                     onKey:(void (^_Nullable)(CassotisKeyResult *result))onKey
                  onSample:(BOOL (^_Nullable)(uint32_t keys, double seconds, uint64_t footprint, uint64_t available))onSample;
@end

NS_ASSUME_NONNULL_END
