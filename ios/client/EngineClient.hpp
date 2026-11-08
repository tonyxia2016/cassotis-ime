#pragma once
#include <cstdint>
#include <string>
#include <vector>
#include <stdexcept>

namespace cassotis {
using Bytes = std::vector<uint8_t>;
struct Writer {
    Bytes data;
    void u8(uint8_t v) { data.push_back(v); }
    void u16(uint16_t v);
    void u32(uint32_t v);
    void u64(uint64_t v);
    void string(const std::string &v);
    void schema(uint16_t version = 1) { u16(version); u16(0); }
};
struct Reader {
    const Bytes &data;
    size_t offset = 0;
    explicit Reader(const Bytes &v) : data(v) {}
    uint8_t u8();
    uint16_t u16();
    uint32_t u32();
    uint64_t u64();
    std::string string();
    uint16_t schema();
    void end();
};
struct Candidate {
    std::string text, comment;
    uint8_t source = 0, kind = 0;
    bool deletable = false;
};
struct CandidatePage {
    int32_t page = 0;
    std::vector<Candidate> candidates;
};
struct PreeditWarning { uint32_t start = 0, length = 0; uint8_t kind = 0; };
enum class CompletionSource : uint8_t { None, UserExact, BaseExact, Transition, LongTransition, LongNeural, DocumentCopy, ExactTailFallback, CustomPhrase };
enum class LeftContextSource : uint8_t { None, Segment, Document, Session };
struct Result {
    bool handled = false, pending = false;
    int32_t selected = -1, page = 0, pages = 0;
    std::string commit, preedit, query, completion;
    std::string selectionKeys = "123456789", rawInput;
    bool rawSelected = false;
    CompletionSource completionSource = CompletionSource::None;
    bool debugContextEnabled = false, debugContextReported = false;
    std::string debugContext;
    LeftContextSource debugContextSource = LeftContextSource::None;
    std::vector<Candidate> candidates;
    std::vector<CandidatePage> candidatePages;
    uint64_t candidateRevision = 0;
    std::vector<PreeditWarning> warnings;
};
struct Key {
    uint16_t special = 0, precedingDigit = 0;
    uint32_t modifiers = 0, scan = 0;
    bool release = false, repeat = false;
    uint64_t timestamp = 0;
    std::string text;
};
struct Shortcut { uint16_t key = 0; uint8_t modifiers = 0; bool disabled = false; };
struct UserWordImportResult { uint32_t entries = 0, imported = 0; };
UserWordImportResult decodeUserWordImportResult(const Bytes &data);
struct CustomPhrase { std::string shortcut, text; };
struct State {
    uint8_t mode = 0, dictionary = 0, scheme = 0, flags = 34;
    uint32_t fuzzy = 0;
    std::string punctuationASCII = "-#*+_=`~[]<>|@";
    bool autoEnglish = true;
    bool includesCustomPhrases = true;
    std::vector<CustomPhrase> customPhrases;
    uint8_t pageKeys = 0, completionKey = 0, pageSize = 5;
    Shortcut shortcuts[5];
};
std::string normalizePunctuationASCII(const std::string &value);
Bytes encodeKey(const Key &key);
Result decodeResult(const Bytes &data);
// pagesOnly: an answer to candidatePages, whose rows need not include the visible page.
Result decodeResult(const Bytes &data, bool pagesOnly);
Bytes encodeState(const State &state);
State decodeState(const Bytes &data);

// One client owns one context. The macOS client talks to a helper over a Unix
// socket; here the engine is in-process, so a transaction is a function call.
class EngineClient {
    bool open_ = false;
    uint64_t request_ = 0, generation_ = 0;
    Bytes reply_ = Bytes(256 * 1024);
    Bytes transact(uint16_t type, const Bytes &payload);
public:
    ~EngineClient() { disconnect(); }
    EngineClient() = default;
    EngineClient(const EngineClient &) = delete;
    EngineClient &operator=(const EngineClient &) = delete;
    // Opens the engine and creates the context.
    bool connect(const std::string &dictionary, const std::string &userDictionary,
                 const std::string &resourceDirectory, const std::string &dataDirectory,
                 std::string &error);
    bool connected() const { return open_; }
    void disconnect();
    void active(bool value);
    void reset();
    void surrounding(const std::string &text, int32_t cursor, bool reported = true);
    Result key(const Key &value);
    Result poll();
    Result removeCandidate(int32_t index, const std::string &query, const Candidate &expected);
    Result candidateAction(uint64_t revision, int32_t page, int32_t index, bool remove,
        const std::string &query, const Candidate &expected);
    // Up to three pages from first, of the list with this candidateRevision, in
    // candidatePages; the engine's page and selection do not move. handled is
    // false once the list changed.
    Result candidatePages(uint64_t revision, int32_t first, int32_t count);
    State state(bool includeCustomPhrases = true);
    void setState(const State &state);
    void clearLearning();
    UserWordImportResult importUserWords(const std::string &path);
};
}
