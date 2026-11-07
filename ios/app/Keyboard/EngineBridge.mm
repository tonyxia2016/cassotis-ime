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
    NSMutableArray<NSString *> *list = [NSMutableArray arrayWithCapacity:r.candidates.size()];
    for (const auto &c : r.candidates) [list addObject:ns(c.text)];
    o.candidates = list;
    return o;
}

@implementation EngineBridge {
    EngineClient _client;
    MemorySnapshot _beforeOpen, _afterOpen;
    double _openSeconds;
}
+ (uint64_t)footprint { return memorySnapshot().footprint; }
+ (uint64_t)footprintPeak { return memorySnapshot().footprintPeak; }
+ (uint64_t)available { return memorySnapshot().available; }
+ (void)setOption:(NSString *)name value:(int32_t)value { cassotis_core_set_option(name.UTF8String, value); }
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
- (CassotisKeyResult *)pressText:(NSString *)text {
    Key k; k.text = text.UTF8String;
    try { return wrap(_client.key(k)); } catch (const std::exception &e) { NSLog(@"key: %s", e.what()); return [CassotisKeyResult new]; }
}
- (CassotisKeyResult *)pressSpecial:(uint16_t)special {
    Key k; k.special = special;
    try { return wrap(_client.key(k)); } catch (const std::exception &e) { NSLog(@"key: %s", e.what()); return [CassotisKeyResult new]; }
}
- (CassotisKeyResult *)selectIndex:(int32_t)index {
    // The digit keys pick from the visible page, as on a hardware keyboard.
    Key k; k.text = std::to_string(index + 1);
    try { return wrap(_client.key(k)); } catch (const std::exception &e) { NSLog(@"select: %s", e.what()); return [CassotisKeyResult new]; }
}
- (void)setLeftContext:(NSString *)text {
    std::string value = text.UTF8String;
    try { _client.surrounding(value, int32_t(value.size()), true); } catch (const std::exception &e) { NSLog(@"context: %s", e.what()); }
}
- (void)resetComposition {
    try { _client.reset(); } catch (const std::exception &e) { NSLog(@"reset: %s", e.what()); }
}
- (void)trim:(int32_t)level {
    cassotis_core_trim(level);
    malloc_zone_pressure_relief(nullptr, 0);  // hand the freed pages back at once
}

- (NSString *)replayCorpus:(NSString *)corpus label:(NSString *)label maxKeys:(uint32_t)maxKeys
                maxSeconds:(uint64_t)maxSeconds paceMicros:(uint32_t)paceMicros sampleEvery:(uint32_t)sampleEvery
                useContext:(BOOL)useContext loop:(BOOL)loop digestPath:(NSString *)digestPath
                     onKey:(void (^)(CassotisKeyResult *))onKey
                  onSample:(BOOL (^)(uint32_t, double, uint64_t, uint64_t))onSample {
    ReplayOptions options;
    options.maxKeys = maxKeys;
    options.maxSeconds = maxSeconds;
    options.paceMicros = paceMicros;
    options.sampleEvery = sampleEvery;
    options.useContext = useContext;
    options.loop = loop;
    if (digestPath) options.digestPath = digestPath.UTF8String;
    if (onKey) options.onKey = [onKey](const Result &r) { @autoreleasepool { onKey(wrap(r)); } };
    ReplayProgress progress;
    if (onSample) progress = [onSample](const ReplaySample &s) {
        @autoreleasepool { return (bool)onSample(s.keys, s.seconds, s.memory.footprint, s.memory.available); }
    };
    auto rows = loadCorpus(corpus.UTF8String);
    auto result = replay(_client, rows, options, progress);
    return ns(toJSON(result, label.UTF8String, _beforeOpen, _afterOpen, _openSeconds));
}
@end
