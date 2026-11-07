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
@end

@interface EngineBridge : NSObject
+ (uint64_t)footprint;
+ (uint64_t)footprintPeak;
+ (uint64_t)available;
// Before the engine opens; see cassotis_core_set_option.
+ (void)setOption:(NSString *)name value:(int32_t)value;
// Applies the keyboard's memory policy, then any cache=/sqlite=/mmap=/ondemand=/
// prewarm= overrides from a run's options.
+ (void)applyMemoryPolicy:(NSDictionary<NSString *, NSString *> *)options;
// Returns nil on success, otherwise the error text.
- (nullable NSString *)openDictionary:(NSString *)dictionary
                       userDictionary:(NSString *)userDictionary
                            resources:(NSString *)resources
                                 data:(NSString *)data;
- (CassotisKeyResult *)pressText:(NSString *)text;
- (CassotisKeyResult *)pressSpecial:(uint16_t)special;
- (CassotisKeyResult *)selectIndex:(int32_t)index;
- (void)setLeftContext:(NSString *)text;
- (void)resetComposition;
- (void)trim:(int32_t)level;
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
                 digestPath:(nullable NSString *)digestPath
                     onKey:(void (^_Nullable)(CassotisKeyResult *result))onKey
                  onSample:(BOOL (^_Nullable)(uint32_t keys, double seconds, uint64_t footprint, uint64_t available))onSample;
@end

NS_ASSUME_NONNULL_END
