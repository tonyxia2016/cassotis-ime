#import "EngineBridge.h"
#include "EngineClient.hpp"
#include "cassotis_core.h"
#include "replay.hpp"
#include <chrono>
#include <malloc/malloc.h>

using namespace cassotis;

@implementation CassotisKeyResult
@end

static NSString *ns(const std::string &text) {
    NSString *value = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
    return value ?: @"";
}
static CassotisKeyResult *wrap(const Result &r) {
    CassotisKeyResult *o = [CassotisKeyResult new];
    o.preedit = ns(r.preedit);
    o.commit = ns(r.commit);
    o.handled = r.handled;
    o.pending = r.pending;
    NSMutableArray<NSString *> *list = [NSMutableArray arrayWithCapacity:r.candidates.size()];
    for (const auto &c : r.candidates) [list addObject:ns(c.text)];
    o.candidates = list;
    o.debugContext = r.debugContextEnabled ? ns(r.debugContext) : @"";
    o.debugContextReported = r.debugContextEnabled && r.debugContextReported;
    return o;
}

@implementation EngineBridge {
    EngineClient _client;
    BOOL _composing;
    MemorySnapshot _beforeOpen, _afterOpen;
    double _openSeconds;
    int32_t _modelState;
    double _modelSeconds;
    std::string _modelError;
}
- (instancetype)init {
    if ((self = [super init])) _modelState = -2;
    return self;
}
+ (uint64_t)footprint { return memorySnapshot().footprint; }
+ (uint64_t)footprintPeak { return memorySnapshot().footprintPeak; }
+ (uint64_t)available { return memorySnapshot().available; }
+ (void)setOption:(NSString *)name value:(int32_t)value { cassotis_core_set_option(name.UTF8String, value); }
+ (void)interrupt { cassotis_core_interrupt(); }
+ (void)applyMemoryPolicy:(NSDictionary<NSString *, NSString *> *)options {
    int32_t (^number)(NSString *, int32_t) = ^int32_t(NSString *key, int32_t fallback) {
        NSString *value = options[key];
        return value ? value.intValue : fallback;
    };
    cassotis_core_set_option("cache_percent", number(@"cache", 6));
    cassotis_core_set_option("sqlite_cache_kib", number(@"sqlite", 2048));
    cassotis_core_set_option("sqlite_mmap_mib", number(@"mmap", 320));
    cassotis_core_set_option("query_path_on_demand", number(@"ondemand", 1));
    cassotis_core_set_option("prewarm_short_lookups", number(@"prewarm", 0));
    cassotis_core_set_option("char_lm", number(@"lm", 1));
    cassotis_core_set_option("char_lm_deferred", number(@"defer", 1));
    cassotis_core_set_option("deterministic_search", number(@"det", 0));
}

- (NSString *)openDictionary:(NSString *)dictionary userDictionary:(NSString *)userDictionary
                   resources:(NSString *)resources data:(NSString *)data {
    _beforeOpen = memorySnapshot();
    auto t0 = std::chrono::steady_clock::now();
    std::string error;
    bool ok = _client.connect(dictionary.UTF8String, userDictionary.UTF8String, resources.UTF8String, data.UTF8String, error);
    _openSeconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    _afterOpen = memorySnapshot();
    if (!ok) return ns(error);
    try { _client.active(true); } catch (const std::exception &e) { return ns(e.what()); }
    return nil;
}
- (BOOL)composing { return _composing; }
// Every key goes through here, so composing follows the engine. A failed
// transaction leaves nothing composed: EngineClient disconnects on errors.
- (CassotisKeyResult *)keyResult:(const Key &)k label:(const char *)label {
    try {
        Result r = _client.key(k);
        _composing = !r.preedit.empty();
        return wrap(r);
    } catch (const std::exception &e) {
        NSLog(@"%s: %s", label, e.what());
        _composing = NO;
        return [CassotisKeyResult new];
    }
}
- (CassotisKeyResult *)pressText:(NSString *)text {
    Key k; k.text = text.UTF8String;
    return [self keyResult:k label:"key"];
}
- (CassotisKeyResult *)pressSpecial:(uint16_t)special {
    Key k; k.special = special;
    return [self keyResult:k label:"key"];
}
- (CassotisKeyResult *)selectIndex:(int32_t)index {
    // The digit keys pick from the visible page, as on a hardware keyboard.
    Key k; k.text = std::to_string(index + 1);
    return [self keyResult:k label:"select"];
}
- (void)setLeftContext:(NSString *)text {
    // The cursor counts UTF-16 units, as Length does in the engine and as the
    // macOS client sends it.
    try {
        if (text) _client.surrounding(text.UTF8String, int32_t(text.length), true);
        else _client.surrounding("", 0, false);
    } catch (const std::exception &e) { NSLog(@"context: %s", e.what()); }
}
- (void)resetComposition {
    _composing = NO;
    try { _client.reset(); } catch (const std::exception &e) { NSLog(@"reset: %s", e.what()); }
}
- (CassotisKeyResult *)poll {
    try {
        Result r = _client.poll();
        if (r.handled) _composing = !r.preedit.empty();
        return wrap(r);
    } catch (const std::exception &e) { NSLog(@"poll: %s", e.what()); return [CassotisKeyResult new]; }
}
- (void)setDebugMode:(BOOL)on {
    try {
        State s = _client.state(false);
        s.flags = on ? (s.flags | 8) : (s.flags & ~8);  // c_state_flag_debug_mode
        _client.setState(s);
    } catch (const std::exception &e) { NSLog(@"debug mode: %s", e.what()); }
}
- (void)trim:(int32_t)level {
    cassotis_core_trim(level);
    malloc_zone_pressure_relief(nullptr, 0);  // hand the freed pages back at once
}
- (int32_t)waitForModel:(uint32_t)timeoutMs {
    auto t0 = std::chrono::steady_clock::now();
    _modelState = cassotis_core_model_state(int32_t(timeoutMs));
    _modelSeconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    _modelError.clear();
    if (_modelState < 0) {
        char text[1024] = {};
        cassotis_core_last_error(text, sizeof text);
        _modelError = text;
    }
    return _modelState;
}
- (NSString *)modelError { return ns(_modelError); }

- (NSString *)replayCorpus:(NSString *)corpus label:(NSString *)label maxKeys:(uint32_t)maxKeys
                maxSeconds:(uint64_t)maxSeconds paceMicros:(uint32_t)paceMicros sampleEvery:(uint32_t)sampleEvery
                useContext:(BOOL)useContext loop:(BOOL)loop poll:(BOOL)poll digestPath:(NSString *)digestPath
                     onKey:(void (^)(CassotisKeyResult *))onKey
                  onSample:(BOOL (^)(uint32_t, double, uint64_t, uint64_t))onSample {
    ReplayOptions options;
    options.maxKeys = maxKeys;
    options.maxSeconds = maxSeconds;
    options.paceMicros = paceMicros;
    options.sampleEvery = sampleEvery;
    options.useContext = useContext;
    options.loop = loop;
    options.poll = poll;
    if (digestPath) options.digestPath = digestPath.UTF8String;
    if (onKey) options.onKey = [onKey](const Result &r) { @autoreleasepool { onKey(wrap(r)); } };
    ReplayProgress progress;
    if (onSample) progress = [onSample](const ReplaySample &s) {
        @autoreleasepool { return (bool)onSample(s.keys, s.seconds, s.memory.footprint, s.memory.available); }
    };
    auto rows = loadCorpus(corpus.UTF8String);
    auto result = replay(_client, rows, options, progress);
    result.modelState = _modelState;
    result.modelSeconds = _modelSeconds;
    if (result.error.empty() && _modelState < 0 && _modelState != -2) result.error = "model: " + _modelError;
    return ns(toJSON(result, label.UTF8String, _beforeOpen, _afterOpen, _openSeconds));
}
@end
