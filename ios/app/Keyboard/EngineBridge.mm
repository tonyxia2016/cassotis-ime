#import "EngineBridge.h"
#include "EngineClient.hpp"
#include "cassotis_core.h"
#include "replay.hpp"
#include <algorithm>
#include <chrono>
#include <malloc/malloc.h>

using namespace cassotis;

@implementation CassotisKeyResult
@end

@implementation CassotisSettings
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
    o.page = r.page;
    o.pages = r.pages;
    o.selected = r.selected;
    o.query = ns(r.query);
    // As macOS previews it: a custom phrase may span lines.
    std::string completion = r.completion;
    std::replace_if(completion.begin(), completion.end(),
        [](char c) { return c == '\t' || c == '\r' || c == '\n'; }, ' ');
    o.completion = ns(completion);
    o.completionPredicted = r.completionSource != CompletionSource::None &&
        r.completionSource != CompletionSource::ExactTailFallback &&
        r.completionSource != CompletionSource::CustomPhrase;
    o.debugContext = r.debugContextEnabled ? ns(r.debugContext) : @"";
    o.debugContextReported = r.debugContextEnabled && r.debugContextReported;
    return o;
}

@implementation EngineBridge {
    EngineClient _client;
    BOOL _composing, _digitsSelect;
    // The scrolling list (engine thread only): the last result's page, then the
    // pages read after it. _first is that result's page, _read how many pages
    // _list holds, _size a full page (0 when there is one page).
    std::vector<std::string> _list;
    int32_t _first, _read, _pageCount, _size, _enginePage;
    uint64_t _revision;
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
    // The Tab completion's model work in the background: the longer continuation
    // and the rerank of the one shown, which polls bring in (acceptCompletion).
    cassotis_core_set_option("char_lm_async", number(@"async", 1));
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
- (BOOL)digitsSelect { return _digitsSelect; }
// A result the keyboard draws: what is composed, and a new scrolling list.
- (void)track:(const Result &)r {
    _composing = !r.preedit.empty();
    _digitsSelect = _composing && r.selectionKeys == "123456789";
    _list.clear();
    for (const auto &c : r.candidates) _list.push_back(c.text);
    _first = r.page;
    _read = 1;
    _pageCount = r.pages;
    _enginePage = r.page;
    _size = r.pages > r.page + 1 ? int32_t(r.candidates.size()) : 0;
    _revision = r.candidateRevision;
}
- (void)forget {
    _composing = _digitsSelect = NO;
    _list.clear();
    _first = _enginePage = _pageCount = _size = 0;
    _read = 1;
    _revision = 0;
}
// Every key goes through here, so composing follows the engine. A failed
// transaction leaves nothing composed: EngineClient disconnects on errors.
- (CassotisKeyResult *)keyResult:(const Key &)k label:(const char *)label {
    try {
        Result r = _client.key(k);
        [self track:r];
        return wrap(r);
    } catch (const std::exception &e) {
        NSLog(@"%s: %s", label, e.what());
        [self forget];
        return [CassotisKeyResult new];
    }
}
- (NSArray<NSString *> *)candidatesFrom:(int32_t)start count:(int32_t)count end:(BOOL *)end {
    while (_size > 0 && _revision && int32_t(_list.size()) < start + count &&
           _first + _read < _pageCount) {
        int32_t next = _first + _read;
        Result r;
        try { r = _client.candidatePages(_revision, next, std::min(3, _pageCount - next)); }
        catch (const std::exception &e) { NSLog(@"pages: %s", e.what()); [self forget]; break; }
        int32_t before = _read;
        for (const auto &page : r.candidatePages) {
            if (page.page != _first + _read) break;
            for (const auto &c : page.candidates) _list.push_back(c.text);
            ++_read;
        }
        // The list changed under us, or the engine has no copy of that page:
        // what is here is all there will be.
        if (!r.handled || _read == before) _pageCount = _first + _read;
    }
    if (end) *end = _first + _read >= _pageCount;
    NSMutableArray<NSString *> *more = [NSMutableArray array];
    for (size_t i = size_t(std::max(0, start)); i < _list.size(); ++i) [more addObject:ns(_list[i])];
    return more;
}
- (CassotisKeyResult *)selectCandidate:(int32_t)index {
    int32_t page = _first, slot = index;
    if (_size > 0) { page = _first + index / _size; slot = index % _size; }
    if (index < 0 || slot >= 9 || page >= std::max(_pageCount, 1)) return nil;
    try {
        // Picking from a later page is navigation, so the paging keys are right here.
        while (_enginePage != page) {
            Key k; k.special = _enginePage < page ? 14 : 13;  // page down : page up
            Result r = _client.key(k);
            if (r.page == _enginePage) return nil;
            _enginePage = r.page;
        }
    } catch (const std::exception &e) { NSLog(@"page: %s", e.what()); [self forget]; return nil; }
    Key k; k.text = std::to_string(slot + 1);
    return [self keyResult:k label:"select"];
}
- (CassotisKeyResult *)pressText:(NSString *)text {
    return [self pressText:text precedingDigit:0];
}
- (CassotisKeyResult *)pressText:(NSString *)text precedingDigit:(uint16_t)digit {
    Key k; k.text = text.UTF8String;
    if (digit >= '0' && digit <= '9') k.precedingDigit = digit;
    return [self keyResult:k label:"key"];
}
- (CassotisKeyResult *)commitComposition {
    if (!_composing) return nil;
    std::string committed, previous;
    Result r;
    try {
        for (int i = 0; i < 128; ++i) {
            Key k; k.special = 5;  // space takes the first candidate, segment by segment
            r = _client.key(k);
            committed += r.commit;
            [self track:r];
            if (r.preedit.empty() || r.preedit == previous) break;
            previous = r.preedit;
        }
    } catch (const std::exception &e) { NSLog(@"commit: %s", e.what()); [self forget]; r = Result(); }
    r.commit = committed;
    return wrap(r);
}
- (int32_t)inputMode {
    try { return _client.state(false).mode; }
    catch (const std::exception &e) { NSLog(@"mode: %s", e.what()); return -1; }
}
- (void)setInputMode:(int32_t)mode {
    try {
        State s = _client.state(false);
        if (s.mode != uint8_t(mode)) { s.mode = uint8_t(mode); _client.setState(s); }
    } catch (const std::exception &e) { NSLog(@"mode: %s", e.what()); }
    [self forget];
}
- (CassotisKeyResult *)pressSpecial:(uint16_t)special {
    Key k; k.special = special;
    return [self keyResult:k label:"key"];
}
- (CassotisKeyResult *)acceptCompletion {
    // As macOS: completionKey 0 is Tab (special 6), anything else `.
    Key k;
    try {
        if (_client.state(false).completionKey == 0) k.special = 6; else k.text = "`";
    } catch (const std::exception &e) {
        NSLog(@"completion key: %s", e.what());
        k.special = 6;
    }
    return [self keyResult:k label:"completion"];
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
    [self forget];
    try { _client.reset(); } catch (const std::exception &e) { NSLog(@"reset: %s", e.what()); }
}
- (CassotisKeyResult *)poll {
    try {
        Result r = _client.poll();
        if (r.handled) [self track:r];
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
- (CassotisSettings *)settings {
    try {
        State s = _client.state(false);
        CassotisSettings *o = [CassotisSettings new];
        o.inputMode = s.mode;
        o.fullWidth = (s.flags & 1) != 0;           // c_state_flag_full_width
        o.chinesePunctuation = (s.flags & 2) != 0;  // c_state_flag_punctuation_full_width
        o.autoEnglish = s.autoEnglish;
        o.scheme = s.scheme;
        o.fuzzyRules = (s.flags & 4) ? s.fuzzy : 0; // c_state_flag_fuzzy_pinyin_enabled
        return o;
    } catch (const std::exception &e) { NSLog(@"settings: %s", e.what()); return nil; }
}
- (BOOL)applySettings:(CassotisSettings *)o {
    try {
        State s = _client.state(false);
        s.mode = uint8_t(o.inputMode == 1 ? 1 : 0);
        s.flags =uint8_t((s.flags & ~7) | (o.fullWidth ? 1 : 0) | (o.chinesePunctuation ? 2 : 0) |
                          (o.fuzzyRules ? 4 : 0));
        s.fuzzy = o.fuzzyRules & 2047u;  // eleven rules
        s.autoEnglish = o.autoEnglish;
        s.scheme = uint8_t(std::clamp(o.scheme, 0, 6));
        _client.setState(s);
        [self forget];
        return YES;
    } catch (const std::exception &e) { NSLog(@"settings: %s", e.what()); return NO; }
}
- (BOOL)clearLearning {
    try { _client.clearLearning(); [self forget]; return YES; }
    catch (const std::exception &e) { NSLog(@"clear learning: %s", e.what()); return NO; }
}
- (int32_t)phraseCount {
    try { return int32_t(_client.state(true).customPhrases.size()); }
    catch (const std::exception &e) { NSLog(@"phrases: %s", e.what()); return -1; }
}
// The phrases in json as macOS's own parser takes them (cassotis_core_parse_phrases):
// false when it refuses them.
static bool parsePhrases(NSData *json, std::vector<CustomPhrase> &phrases) {
    try {
        Bytes out(64 * 1024);
        int32_t length = 0;
        for (int attempt = 0; attempt < 2; ++attempt) {
            length = cassotis_core_parse_phrases(static_cast<const char *>(json.bytes), uint32_t(json.length),
                                                 out.data(), uint32_t(out.size()));
            if (length < 0) return false;
            if (size_t(length) <= out.size()) break;
            out.resize(size_t(length));
        }
        if (size_t(length) > out.size()) return false;
        out.resize(size_t(length));
        Reader r(out);
        uint32_t count = r.u32();
        for (uint32_t i = 0; i < count; ++i) {
            CustomPhrase phrase;
            phrase.shortcut = r.string();
            phrase.text = r.string();
            phrases.push_back(std::move(phrase));
        }
        r.end();
        return true;
    } catch (const std::exception &e) {
        NSLog(@"parse phrases: %s", e.what());
        return false;
    }
}
// Why the parser refused json, for the user: the first thing wrong, found with the
// rules of nc_parse_custom_phrases (an abbreviation is trimmed and lowercased, then
// 1–32 letters a–z; a text is not blank, at most 4096 UTF-16 units, without control
// characters but tab and line breaks). What only a strict JSON reading refuses (a
// comma before a closing bracket, say) gets the general answer.
static NSString *phraseError(NSData *json) {
    id root = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![root isKindOfClass:NSArray.class])
        return @"剪贴板里不是 Mac 导出的短语：要 [[\"缩写\", \"内容\"], …] 这样的 JSON。";
    NSArray *rows = root;
    if (rows.count > 1024)
        return [NSString stringWithFormat:@"剪贴板里有 %lu 条，最多 1024 条。", (unsigned long)rows.count];
    for (NSUInteger i = 0; i < rows.count; ++i) {
        NSArray *row = [rows[i] isKindOfClass:NSArray.class] ? rows[i] : nil;
        if (row.count != 2 || ![row[0] isKindOfClass:NSString.class] || ![row[1] isKindOfClass:NSString.class])
            return [NSString stringWithFormat:@"第 %lu 条不是 [\"缩写\", \"内容\"]。", (unsigned long)(i + 1)];
        NSString *key = [row[0] stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithRange:NSMakeRange(0, 33)]];
        bool letters = key.length > 0 && key.length <= 32;
        for (NSUInteger j = 0; letters && j < key.length; ++j) {
            unichar c = [key characterAtIndex:j];  // ASCII letters of either case: LowerCase folds only those
            letters = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        }
        if (!letters)
            return [NSString stringWithFormat:@"第 %lu 条的缩写不对：要 1–32 个英文字母。", (unsigned long)(i + 1)];
        key = key.lowercaseString;
        NSString *text = row[1];
        bool blank = true, control = false;
        for (NSUInteger j = 0; j < text.length; ++j) {
            unichar c = [text characterAtIndex:j];
            if (c > ' ') blank = false;
            if (c < ' ' && c != '\t' && c != '\n' && c != '\r') control = true;
        }
        if (blank || control || text.length > 4096)
            return [NSString stringWithFormat:@"第 %lu 条（%@）的内容不对：不能空着，最多 4096 字，"
                    "除了制表符和换行不能有控制字符。", (unsigned long)(i + 1), key];
    }
    return @"剪贴板里的 JSON 格式不对，比如方括号前多了逗号。";
}
- (NSString *)importPhrases:(NSString *)json added:(int32_t *)added {
    if (added) *added = 0;
    // As the macOS settings read a file: at most 16 MB, then all of it or nothing.
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return @"剪贴板里的文字有无效字符，没有导入。";
    if (data.length > 16 * 1024 * 1024) return @"剪贴板里的内容超过 16 MB，没有导入。";
    std::vector<CustomPhrase> parsed;
    if (!parsePhrases(data, parsed)) return [phraseError(data) stringByAppendingString:@"没有导入。"];
    if (parsed.empty()) return @"剪贴板里没有短语。";
    try {
        State s = _client.state(true);
        size_t before = s.customPhrases.size();
        for (auto &phrase : parsed) {
            bool known = std::any_of(s.customPhrases.begin(), s.customPhrases.end(), [&](const CustomPhrase &p) {
                return p.shortcut == phrase.shortcut && p.text == phrase.text;
            });
            if (!known) s.customPhrases.push_back(std::move(phrase));
        }
        size_t fresh = s.customPhrases.size() - before;
        if (s.customPhrases.size() > 1024)
            return [NSString stringWithFormat:@"已有 %lu 条，再加 %lu 条新的就超过 1024 条了。没有导入。",
                    (unsigned long)before, (unsigned long)fresh];
        if (fresh > 0) {
            _client.setState(s);
            [self forget];
        }
        if (added) *added = int32_t(fresh);
        return nil;
    } catch (const std::exception &e) {
        NSLog(@"import phrases: %s", e.what());
        return @"引擎没有接受这些短语，没有导入。";
    }
}
- (BOOL)clearPhrases {
    try {
        State s = _client.state(true);
        if (s.customPhrases.empty()) return YES;
        s.customPhrases.clear();
        _client.setState(s);
        [self forget];
        return YES;
    } catch (const std::exception &e) { NSLog(@"clear phrases: %s", e.what()); return NO; }
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
