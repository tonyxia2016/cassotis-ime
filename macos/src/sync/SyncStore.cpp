#include "SyncStore.hpp"

#include <CommonCrypto/CommonDigest.h>
#include <compression.h>
#include <sqlite3.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <unistd.h>
#include <set>
#include <unordered_map>

namespace cassotis_sync {

// ---------------------------------------------------------------------------
// What is synced. Counters merge as sums of every replica's deltas, clamped as the
// engine clamps them; ts is the column of the row's time (latest wins); reg is a
// value column where the latest wins. Deletions travel as tombstones unless the
// engine only deletes rows of the table to stay within a size (tombs = false).

struct Store::Spec {
    const char *code;   // in payloads
    const char *table;  // in user_dict.db
    std::vector<const char *> keys;
    const char *c1;
    const char *c2;
    int64_t cap1;
    int64_t cap2;
    const char *ts;
    const char *reg;
    bool tombs;
};

static const std::vector<Store::Spec> &specs() {
    static const std::vector<Store::Spec> list = {
        {"user", "dict_user", {"pinyin", "text"}, "weight", nullptr, 0, 0, "last_used", nullptr, true},
        {"stats", "dict_user_stats", {"pinyin", "text"}, "commit_count", nullptr, 0, 0, "last_used", nullptr, true},
        {"latest", "dict_user_query_latest", {"query_pinyin"}, nullptr, nullptr, 0, 0, "last_used", "text", true},
        // 120 when declined as a candidate, 360 after a removal: the larger bound.
        {"penalty", "dict_user_penalty", {"pinyin", "text"}, "penalty", nullptr, 360, 0, "last_used", nullptr, true},
        {"literal", "dict_user_literal", {"pinyin", "text"}, nullptr, nullptr, 0, 0, "created_at", "jianpin", true},
        {"fuzzy", "dict_user_fuzzy_choice", {"pinyin", "text"}, "commit_count", nullptr, 1000000, 0, "last_used", nullptr, true},
        // Pruned to 3584 rows past 4096 (oldest first): local only.
        {"context", "dict_user_context_query_choice", {"context_suffix", "query_pinyin", "text"}, "commit_count", nullptr, 255, 0, "last_used", nullptr, false},
        {"completion", "dict_user_completion_feedback", {"typed_prefix", "full_pinyin", "text"}, "accept_count", "reject_count", 1000000, 1000000, "last_used", nullptr, true},
        {"long", "dict_user_long_completion_feedback", {"anchor_path", "suffix_text"}, "accept_count", "reject_count", 1000000, 1000000, "last_used", nullptr, true},
        // Pruned past 60000 rows: local only.
        {"pathpenalty", "dict_user_query_path_penalty", {"query_pinyin", "path_text"}, "penalty", nullptr, 480, 0, "last_used", nullptr, false},
        {"bigram", "dict_user_bigram", {"left_text", "text"}, "commit_count", nullptr, 0, 0, "last_used", nullptr, false},
        {"trigram", "dict_user_trigram", {"prev_prev_text", "prev_text", "text"}, "commit_count", nullptr, 0, 0, "last_used", nullptr, false},
        {"path", "dict_user_query_path", {"query_pinyin", "path_text"}, "commit_count", nullptr, 0, 0, "last_used", nullptr, false},
    };
    return list;
}

static const char *const kPhraseCode = "phrase";
static const int kPhraseTable = -1;
static const size_t kMaxPhrases = 1024;
static const int64_t kTombDays = 180;
static const size_t kMaxBatchBytes = 600 * 1024;

struct Store::Op {
    char kind = 0;    // U upsert (delta), D delete, O phrase order, S snapshot row, T tomb, A applied
    int table = 0;    // index in specs(), kPhraseTable for phrases, -2 for A
    std::vector<std::string> key;
    int64_t c1 = 0, c2 = 0, ts = 0;
    std::string reg;
};

// ---------------------------------------------------------------------------
// Small helpers

namespace {

std::vector<std::string> splitStaged(const std::string &text) {
    std::vector<std::string> lines;
    size_t start = 0;
    while (start < text.size()) {
        size_t end = text.find('\n', start);
        if (end == std::string::npos) end = text.size();
        if (end > start) lines.push_back(text.substr(start, end - start));
        start = end + 1;
    }
    return lines;
}

struct Statement {
    sqlite3_stmt *stmt = nullptr;
    bool owned = true;
    Statement(sqlite3 *db, const std::string &sql) {
        if (sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) stmt = nullptr;
    }
    /// A statement of the store's cache: reset for the next use, never finalized here.
    explicit Statement(sqlite3_stmt *cached) : stmt(cached), owned(false) {}
    ~Statement() {
        if (!stmt) return;
        if (owned) sqlite3_finalize(stmt);
        else { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt); }
    }
    Statement(const Statement &) = delete;
    Statement &operator=(const Statement &) = delete;
    bool ok() const { return stmt != nullptr; }
    void bind(int index, const std::string &value) {
        sqlite3_bind_text(stmt, index, value.data(), int(value.size()), SQLITE_TRANSIENT);
    }
    void bind(int index, int64_t value) { sqlite3_bind_int64(stmt, index, value); }
    void bindBlob(int index, const std::string &value) {
        sqlite3_bind_blob(stmt, index, value.data(), int(value.size()), SQLITE_TRANSIENT);
    }
    void bindNull(int index) { sqlite3_bind_null(stmt, index); }
    int step() { return sqlite3_step(stmt); }
    void reset() { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt); }
    std::string text(int column) {
        const unsigned char *value = sqlite3_column_text(stmt, column);
        return value ? std::string(reinterpret_cast<const char *>(value), size_t(sqlite3_column_bytes(stmt, column))) : std::string();
    }
    std::string blob(int column) {
        const void *value = sqlite3_column_blob(stmt, column);
        return value ? std::string(static_cast<const char *>(value), size_t(sqlite3_column_bytes(stmt, column))) : std::string();
    }
    int64_t integer(int column) { return sqlite3_column_int64(stmt, column); }
    bool isNull(int column) { return sqlite3_column_type(stmt, column) == SQLITE_NULL; }
};

std::string hexOf(const unsigned char *bytes, size_t count) {
    static const char digits[] = "0123456789abcdef";
    std::string out;
    out.reserve(count * 2);
    for (size_t i = 0; i < count; ++i) {
        out.push_back(digits[bytes[i] >> 4]);
        out.push_back(digits[bytes[i] & 15]);
    }
    return out;
}

std::string sha256Hex(const std::string &text) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(text.data(), CC_LONG(text.size()), digest);
    return hexOf(digest, sizeof(digest));
}

std::string randomId() {
    unsigned char bytes[16];
    arc4random_buf(bytes, sizeof(bytes));
    return hexOf(bytes, sizeof(bytes));
}

std::string escapeField(const std::string &value) {
    std::string out;
    out.reserve(value.size());
    for (char ch : value) {
        switch (ch) {
        case '\\': out += "\\\\"; break;
        case '\t': out += "\\t"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        default: out.push_back(ch);
        }
    }
    return out;
}

std::vector<std::string> splitLine(const std::string &line) {
    std::vector<std::string> fields(1);
    for (size_t i = 0; i < line.size(); ++i) {
        char ch = line[i];
        if (ch == '\t') { fields.emplace_back(); continue; }
        if (ch == '\\' && i + 1 < line.size()) {
            char next = line[++i];
            fields.back().push_back(next == 't' ? '\t' : next == 'n' ? '\n' : next == 'r' ? '\r' : next);
            continue;
        }
        fields.back().push_back(ch);
    }
    return fields;
}

bool parseInt(const std::string &text, int64_t &value) {
    if (text.empty()) return false;
    char *end = nullptr;
    long long parsed = strtoll(text.c_str(), &end, 10);
    if (!end || *end) return false;
    value = parsed;
    return true;
}

int64_t clampCounter(int64_t value, int64_t cap) {
    if (value < 0) return 0;
    return cap > 0 && value > cap ? cap : value;
}

std::string joinKey(const std::vector<std::string> &key) {
    std::string out;
    for (size_t i = 0; i < key.size(); ++i) {
        if (i) out.push_back('\x1f');
        out += key[i];
    }
    return out;
}

// --- Custom phrases: the engine's JSON, [["shortcut","text"], ...] -----------

using Phrase = std::pair<std::string, std::string>;

void appendUtf8(std::string &out, uint32_t cp) {
    if (cp < 0x80) out.push_back(char(cp));
    else if (cp < 0x800) { out.push_back(char(0xC0 | (cp >> 6))); out.push_back(char(0x80 | (cp & 0x3F))); }
    else if (cp < 0x10000) {
        out.push_back(char(0xE0 | (cp >> 12))); out.push_back(char(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(char(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(char(0xF0 | (cp >> 18))); out.push_back(char(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(char(0x80 | ((cp >> 6) & 0x3F))); out.push_back(char(0x80 | (cp & 0x3F)));
    }
}

struct JsonReader {
    const std::string &s;
    size_t i = 0;
    explicit JsonReader(const std::string &text) : s(text) {}
    void space() { while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) ++i; }
    bool eat(char ch) { space(); if (i < s.size() && s[i] == ch) { ++i; return true; } return false; }
    bool hex4(uint32_t &value) {
        if (i + 4 > s.size()) return false;
        value = 0;
        for (int k = 0; k < 4; ++k) {
            char ch = s[i++];
            value <<= 4;
            if (ch >= '0' && ch <= '9') value |= uint32_t(ch - '0');
            else if (ch >= 'a' && ch <= 'f') value |= uint32_t(ch - 'a' + 10);
            else if (ch >= 'A' && ch <= 'F') value |= uint32_t(ch - 'A' + 10);
            else return false;
        }
        return true;
    }
    bool string(std::string &out) {
        out.clear();
        if (!eat('"')) return false;
        while (i < s.size()) {
            char ch = s[i++];
            if (ch == '"') return true;
            if (ch != '\\') { out.push_back(ch); continue; }
            if (i >= s.size()) return false;
            char esc = s[i++];
            switch (esc) {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case '/': out.push_back('/'); break;
            case 'b': out.push_back('\b'); break;
            case 'f': out.push_back('\f'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            case 'u': {
                uint32_t cp;
                if (!hex4(cp)) return false;
                if (cp >= 0xD800 && cp < 0xDC00 && i + 1 < s.size() && s[i] == '\\' && s[i + 1] == 'u') {
                    i += 2;
                    uint32_t low;
                    if (!hex4(low)) return false;
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                }
                appendUtf8(out, cp);
                break;
            }
            default: return false;
            }
        }
        return false;
    }
};

/// The engine wrote this list, so only its own shape is accepted.
bool parsePhrases(const std::string &json, std::vector<Phrase> &out) {
    out.clear();
    JsonReader reader(json);
    reader.space();
    if (reader.i >= json.size()) return true;  // absent: no phrases
    if (!reader.eat('[')) return false;
    if (reader.eat(']')) return true;
    do {
        Phrase phrase;
        if (!reader.eat('[') || !reader.string(phrase.first) || !reader.eat(',') ||
            !reader.string(phrase.second) || !reader.eat(']'))
            return false;
        out.push_back(std::move(phrase));
    } while (reader.eat(','));
    return reader.eat(']');
}

void appendJsonString(std::string &out, const std::string &value) {
    out.push_back('"');
    for (unsigned char ch : value) {
        switch (ch) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (ch < 0x20) {
                char buffer[8];
                snprintf(buffer, sizeof(buffer), "\\u%04x", ch);
                out += buffer;
            } else {
                out.push_back(char(ch));
            }
        }
    }
    out.push_back('"');
}

std::string phrasesJson(const std::vector<Phrase> &list) {
    std::string out = "[";
    for (size_t i = 0; i < list.size(); ++i) {
        if (i) out += ", ";
        out.push_back('[');
        appendJsonString(out, list[i].first);
        out += ", ";
        appendJsonString(out, list[i].second);
        out.push_back(']');
    }
    return out + "]";
}

/// 64-bit FNV-1a of shortcut and text, as 16 hex digits: names a phrase in an order.
std::string phraseHash(const Phrase &phrase) {
    uint64_t hash = 1469598103934665603ULL;
    auto mix = [&hash](const std::string &text) {
        for (unsigned char ch : text) { hash ^= ch; hash *= 1099511628211ULL; }
    };
    mix(phrase.first);
    hash ^= 0x1f; hash *= 1099511628211ULL;
    mix(phrase.second);
    char buffer[17];
    snprintf(buffer, sizeof(buffer), "%016llx", static_cast<unsigned long long>(hash));
    return buffer;
}

std::string orderOf(const std::vector<Phrase> &list) {
    std::string out;
    for (const auto &phrase : list) {
        if (!out.empty()) out.push_back(',');
        out += phraseHash(phrase);
    }
    return out;
}

}  // namespace

// ---------------------------------------------------------------------------
// Payload codec: "Z" + 4-byte little-endian length + zlib (raw deflate), or "N" +
// length + the text when it does not shrink.

std::string compressText(const std::string &text) {
    auto header = [&text](char kind) {
        std::string out(5, '\0');
        out[0] = kind;
        uint32_t length = uint32_t(text.size());
        for (int i = 0; i < 4; ++i) out[size_t(1 + i)] = char((length >> (8 * i)) & 0xFF);
        return out;
    };
    std::string out = header('Z');
    size_t capacity = text.size() + 1024;
    std::string buffer(capacity, '\0');
    size_t written = text.empty() ? 0 : compression_encode_buffer(
        reinterpret_cast<uint8_t *>(&buffer[0]), capacity,
        reinterpret_cast<const uint8_t *>(text.data()), text.size(), nullptr, COMPRESSION_ZLIB);
    if (written == 0 || written >= text.size()) return header('N') + text;
    out.append(buffer.data(), written);
    return out;
}

bool decompressText(const std::string &data, std::string &text) {
    text.clear();
    if (data.size() < 5) return false;
    uint32_t length = 0;
    for (int i = 0; i < 4; ++i) length |= uint32_t(uint8_t(data[size_t(1 + i)])) << (8 * i);
    if (length > (256u << 20)) return false;
    if (data[0] == 'N') {
        if (data.size() - 5 != length) return false;
        text = data.substr(5);
        return true;
    }
    if (data[0] != 'Z') return false;
    if (length == 0) return true;
    text.resize(length);
    size_t read = compression_decode_buffer(reinterpret_cast<uint8_t *>(&text[0]), length,
        reinterpret_cast<const uint8_t *>(data.data() + 5), data.size() - 5, nullptr, COMPRESSION_ZLIB);
    if (read != length) { text.clear(); return false; }
    return true;
}

// ---------------------------------------------------------------------------

Store::Store(std::string path) : path_(std::move(path)) {}
Store::~Store() { close(); }

void Store::close() {
    for (auto &entry : cache_) sqlite3_finalize(entry.second);
    cache_.clear();
    if (db_) sqlite3_close_v2(db_);
    db_ = nullptr;
}

sqlite3_stmt *Store::cached(const std::string &sql) {
    auto found = cache_.find(sql);
    if (found != cache_.end()) return found->second;
    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) return nullptr;
    cache_.emplace(sql, stmt);
    return stmt;
}

bool Store::exec(const char *sql) {
    return sqlite3_exec(db_, sql, nullptr, nullptr, nullptr) == SQLITE_OK;
}

bool Store::tableExists(const char *name) {
    Statement st(db_, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1");
    if (!st.ok()) return false;
    st.bind(1, std::string(name));
    return st.step() == SQLITE_ROW;
}

bool Store::open(std::string &error, bool create) {
    if (db_) return true;
    if (sqlite3_open_v2(path_.c_str(), &db_, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0), nullptr) != SQLITE_OK) {
        error = db_ ? sqlite3_errmsg(db_) : "cannot open the user dictionary";
        close();
        return false;
    }
    // The engine writes in short transactions and waits up to a second for others;
    // ours are short too.
    sqlite3_busy_timeout(db_, 3000);
    exec("PRAGMA temp_store=MEMORY;");
    if (!ensureSchema(error)) {
        close();
        return false;
    }
    refreshTables();
    return true;
}

void Store::refreshTables() {
    present_.clear();
    for (const auto &spec : specs()) present_.push_back(tableExists(spec.table));
}

bool Store::ensureSchema(std::string &error) {
    std::string sql =
        "CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, value BLOB);"
        "CREATE TABLE IF NOT EXISTS sync_outbox (seq INTEGER PRIMARY KEY, created INTEGER NOT NULL, "
        "payload BLOB NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);"
        "CREATE TABLE IF NOT EXISTS sync_inbox (replica TEXT NOT NULL, seq INTEGER NOT NULL, "
        "created INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(replica, seq)) WITHOUT ROWID;"
        "CREATE TABLE IF NOT EXISTS sync_forward (replica TEXT NOT NULL, seq INTEGER NOT NULL, "
        "created INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(replica,seq)) WITHOUT ROWID;"
        "CREATE TABLE IF NOT EXISTS sync_applied (replica TEXT PRIMARY KEY, seq INTEGER NOT NULL);"
        "CREATE TABLE IF NOT EXISTS sync_tomb (tbl TEXT NOT NULL, key TEXT NOT NULL, ts INTEGER NOT NULL, "
        "PRIMARY KEY(tbl, key)) WITHOUT ROWID;"
        "CREATE TABLE IF NOT EXISTS sync_phrase (shortcut TEXT NOT NULL, text TEXT NOT NULL, "
        "added INTEGER NOT NULL, PRIMARY KEY(shortcut, text)) WITHOUT ROWID;"
        "CREATE TABLE IF NOT EXISTS sync_replica (replica TEXT PRIMARY KEY, platform TEXT, label TEXT, "
        "last_seq INTEGER, min_seq INTEGER, last_sync INTEGER, applied TEXT);"
        "CREATE TABLE IF NOT EXISTS sync_snapshot (replica TEXT PRIMARY KEY, generation INTEGER, "
        "parts INTEGER, created INTEGER, applied TEXT);";
    for (const auto &spec : specs()) {
        sql += "CREATE TABLE IF NOT EXISTS sync_shadow_" + std::string(spec.code) + " (";
        std::string primary;
        for (const char *key : spec.keys) {
            sql += std::string(key) + " TEXT NOT NULL, ";
            primary += (primary.empty() ? "" : ", ") + std::string(key);
        }
        sql += "c1 INTEGER NOT NULL DEFAULT 0, c2 INTEGER NOT NULL DEFAULT 0, ts INTEGER NOT NULL DEFAULT 0, "
               "reg TEXT, PRIMARY KEY(" + primary + ")) WITHOUT ROWID;";
    }
    if (sqlite3_exec(db_, sql.c_str(), nullptr, nullptr, nullptr) != SQLITE_OK) {
        error = sqlite3_errmsg(db_);
        return false;
    }
    return true;
}

std::string Store::value(const std::string &key) {
    Statement st(db_, "SELECT value FROM sync_state WHERE key = ?1");
    if (!st.ok()) return std::string();
    st.bind(1, key);
    return st.step() == SQLITE_ROW ? st.blob(0) : std::string();
}

bool Store::setValue(const std::string &key, const std::string &value) {
    Statement st(db_, "INSERT INTO sync_state(key, value) VALUES (?1, ?2) "
                      "ON CONFLICT(key) DO UPDATE SET value = excluded.value");
    if (!st.ok()) return false;
    st.bind(1, key);
    st.bindBlob(2, value);
    return st.step() == SQLITE_DONE;
}

int64_t Store::number(const std::string &key, int64_t fallback) {
    int64_t parsed;
    return parseInt(value(key), parsed) ? parsed : fallback;
}

void Store::setNumber(const std::string &key, int64_t value) { setValue(key, std::to_string(value)); }

std::string Store::replica() {
    std::string id = value("replica");
    if (!id.empty()) return id;
    Statement create(db_, "INSERT OR IGNORE INTO sync_state(key,value) VALUES('replica',?1)");
    if (!create.ok()) return {};
    create.bindBlob(1, randomId());
    return create.step() == SQLITE_DONE ? value("replica") : std::string();
}

bool Store::adoptDevice(const std::string &deviceToken) {
    std::string mark = sha256Hex("cassotis-device:" + deviceToken);
    if (!exec("BEGIN IMMEDIATE;")) return false;
    std::string stored = value("device");
    if (stored == mark) { exec("ROLLBACK;"); return false; }
    bool moved = !stored.empty();
    if (moved) {
        // A copy of another device's file (a restored backup): its batches belong
        // to that device, which may still upload them. Continue as a new replica.
        // The backup already includes the old replica's contributions. Remember
        // its position so re-downloading those batches never adds them twice.
        const auto previous = replica();
        Statement seen(db_, "INSERT OR REPLACE INTO sync_applied VALUES (?1, ?2)");
        Statement keep(db_, "INSERT OR IGNORE INTO sync_forward "
                            "SELECT ?1,seq,created,payload FROM sync_outbox WHERE uploaded=0");
        if (!seen.ok() || !keep.ok()) { exec("ROLLBACK;"); return false; }
        seen.bind(1, previous); seen.bind(2, lastOwnSeq()); keep.bind(1, previous);
        if (seen.step() != SQLITE_DONE || keep.step() != SQLITE_DONE ||
            !exec("DELETE FROM sync_outbox; DELETE FROM sync_state WHERE key IN "
                  "('token','last_snapshot','snapshot_parts','snapshot_gen','last_attempt');") ||
            !setValue("replica", randomId()) || !setValue("next_seq", "1")) {
            exec("ROLLBACK;");
            return false;
        }
    }
    if (setValue("device", mark) && exec("COMMIT;")) return moved;
    exec("ROLLBACK;");
    return false;
}

bool Store::adoptAccount(const std::string &accountName) {
    if (accountName.empty() || !exec("BEGIN IMMEDIATE;")) return false;
    const auto mark = sha256Hex("cassotis-account:" + accountName);
    const auto stored = value("account");
    if ((stored == mark || (stored.empty() && setValue("account", mark))) && exec("COMMIT;")) return true;
    exec("ROLLBACK;");
    return false;
}

void Store::setClearPending(bool pending) {
    if (pending) setValue("clear_pending", "1");
    else exec("DELETE FROM sync_state WHERE key = 'clear_pending';");
}

// ---------------------------------------------------------------------------
// Local changes

bool Store::diffTable(const Spec &spec, int64_t now, std::vector<Op> &ops) {
    const std::string shadow = "sync_shadow_" + std::string(spec.code);
    const std::string c1 = spec.c1 ? "IFNULL(l." + std::string(spec.c1) + ", 0)" : "0";
    const std::string c2 = spec.c2 ? "IFNULL(l." + std::string(spec.c2) + ", 0)" : "0";
    const std::string ts = "IFNULL(l." + std::string(spec.ts) + ", 0)";
    const std::string reg = spec.reg ? "l." + std::string(spec.reg) : "NULL";
    std::string keys, join, exists, where;
    for (size_t i = 0; i < spec.keys.size(); ++i) {
        std::string k = spec.keys[i];
        keys += (i ? ", l." : "l.") + k;
        join += (i ? " AND s." : "s.") + k + " = l." + k;
    }
    const std::string first = spec.keys[0];
    std::string sql = "SELECT " + keys + ", " + c1 + ", " + c2 + ", " + ts + ", " + reg +
        ", s." + first + " IS NOT NULL, IFNULL(s.c1, 0), IFNULL(s.c2, 0) FROM " + spec.table +
        " l LEFT JOIN " + shadow + " s ON " + join + " WHERE s." + first + " IS NULL OR " + c1 +
        " <> s.c1 OR " + c2 + " <> s.c2 OR " + ts + " <> s.ts OR " + reg + " IS NOT s.reg";
    const int n = int(spec.keys.size());
    struct Row { std::vector<std::string> key; int64_t c1, c2, ts; std::string reg; bool hasReg; };
    std::vector<Row> changed;
    {
        Statement st(db_, sql);
        if (!st.ok()) return false;
        int rc;
        while ((rc = st.step()) == SQLITE_ROW) {
            Row row;
            for (int i = 0; i < n; ++i) row.key.push_back(st.text(i));
            row.c1 = st.integer(n);
            row.c2 = st.integer(n + 1);
            row.ts = st.integer(n + 2);
            row.hasReg = !st.isNull(n + 3);
            row.reg = st.text(n + 3);
            bool known = st.integer(n + 4) != 0;
            Op op;
            op.kind = 'U';
            op.table = int(&spec - &specs()[0]);
            op.key = row.key;
            op.c1 = row.c1 - (known ? st.integer(n + 5) : 0);
            op.c2 = row.c2 - (known ? st.integer(n + 6) : 0);
            op.ts = row.ts;
            op.reg = row.reg;
            ops.push_back(op);
            changed.push_back(std::move(row));
        }
        if (rc != SQLITE_DONE) return false;
    }
    std::vector<std::vector<std::string>> deleted;
    {
        std::string match;
        for (size_t i = 0; i < spec.keys.size(); ++i)
            match += std::string(i ? " AND l." : "l.") + spec.keys[i] + " = s." + spec.keys[i];
        std::string skeys;
        for (size_t i = 0; i < spec.keys.size(); ++i) skeys += std::string(i ? ", s." : "s.") + spec.keys[i];
        Statement st(db_, "SELECT " + skeys + " FROM " + shadow + " s WHERE NOT EXISTS (SELECT 1 FROM " +
            spec.table + " l WHERE " + match + ")");
        if (!st.ok()) return false;
        int rc;
        while ((rc = st.step()) == SQLITE_ROW) {
            std::vector<std::string> key;
            for (int i = 0; i < n; ++i) key.push_back(st.text(i));
            if (spec.tombs) {
                Op op;
                op.kind = 'D';
                op.table = int(&spec - &specs()[0]);
                op.key = key;
                op.ts = now;
                ops.push_back(op);
            }
            deleted.push_back(std::move(key));
        }
        if (rc != SQLITE_DONE) return false;
    }
    // A deletion here also stops older increments of other replicas that arrive later.
    if (spec.tombs && !deleted.empty()) {
        Statement tomb(cached("INSERT INTO sync_tomb(tbl, key, ts) VALUES (?1, ?2, ?3) "
                              "ON CONFLICT(tbl, key) DO UPDATE SET ts = MAX(ts, excluded.ts)"));
        if (!tomb.ok()) return false;
        for (const auto &key : deleted) {
            tomb.reset();
            tomb.bind(1, std::string(spec.code)); tomb.bind(2, joinKey(key)); tomb.bind(3, now);
            if (tomb.step() != SQLITE_DONE) return false;
        }
    }
    // The shadow now matches the live rows.
    std::string columns, marks;
    for (size_t i = 0; i < spec.keys.size(); ++i) {
        columns += std::string(spec.keys[i]) + ", ";
        marks += "?" + std::to_string(i + 1) + ", ";
    }
    Statement put(db_, "INSERT OR REPLACE INTO " + shadow + " (" + columns + "c1, c2, ts, reg) VALUES (" + marks +
        "?" + std::to_string(n + 1) + ", ?" + std::to_string(n + 2) + ", ?" + std::to_string(n + 3) + ", ?" +
        std::to_string(n + 4) + ")");
    if (!put.ok()) return false;
    for (const auto &row : changed) {
        put.reset();
        for (int i = 0; i < n; ++i) put.bind(i + 1, row.key[size_t(i)]);
        put.bind(n + 1, row.c1);
        put.bind(n + 2, row.c2);
        put.bind(n + 3, row.ts);
        if (row.hasReg) put.bind(n + 4, row.reg); else put.bindNull(n + 4);
        if (put.step() != SQLITE_DONE) return false;
    }
    std::string where_keys;
    for (size_t i = 0; i < spec.keys.size(); ++i)
        where_keys += std::string(i ? " AND " : "") + spec.keys[i] + " = ?" + std::to_string(i + 1);
    Statement drop(db_, "DELETE FROM " + shadow + " WHERE " + where_keys);
    if (!drop.ok()) return false;
    for (const auto &key : deleted) {
        drop.reset();
        for (int i = 0; i < n; ++i) drop.bind(i + 1, key[size_t(i)]);
        if (drop.step() != SQLITE_DONE) return false;
    }
    return true;
}

bool Store::diffPhrases(int64_t now, std::vector<Op> &ops) {
    std::string live;
    bool hasMeta = tableExists("meta");
    if (hasMeta) {
        Statement st(db_, "SELECT value FROM meta WHERE key = 'setting.custom_phrases'");
        if (st.ok() && st.step() == SQLITE_ROW) live = st.text(0);
    }
    std::vector<Phrase> current, base;
    if (!parsePhrases(live, current)) return true;  // not the engine's shape: leave alone
    std::string pendingBase = value("phrases_pending_base");
    bool editedDuringMerge = false;
    if (!value("phrases_pending").empty()) {
        std::vector<Phrase> pending;
        // The engine has not taken the merged list yet, and nobody edited meanwhile.
        if (parsePhrases(pendingBase, pending) && pending == current) return true;
        std::vector<Phrase> merged;
        if (parsePhrases(value("phrases_pending"), merged) && merged == current) {
            // The engine wrote the merge and exited before acknowledging it.
            return setValue("phrases_applied", live) &&
                exec("DELETE FROM sync_state WHERE key IN ('phrases_pending', 'phrases_pending_base');");
        }
        editedDuringMerge = true;
        exec("DELETE FROM sync_state WHERE key IN ('phrases_pending', 'phrases_pending_base');");
    }
    if (!parsePhrases(value("phrases_applied"), base)) base.clear();
    if (current == base) return true;
    std::set<Phrase> now_set(current.begin(), current.end()), base_set(base.begin(), base.end());
    Statement add(db_, "INSERT OR IGNORE INTO sync_phrase(shortcut, text, added) VALUES (?1, ?2, ?3)");
    Statement remove(db_, "DELETE FROM sync_phrase WHERE shortcut = ?1 AND text = ?2");
    Statement tomb(db_, "INSERT INTO sync_tomb(tbl, key, ts) VALUES ('phrase', ?1, ?2) "
                        "ON CONFLICT(tbl, key) DO UPDATE SET ts = MAX(ts, excluded.ts)");
    if (!add.ok() || !remove.ok() || !tomb.ok()) return false;
    for (const auto &phrase : now_set) {
        if (base_set.count(phrase)) continue;
        Op op;
        op.kind = 'U'; op.table = kPhraseTable; op.key = {phrase.first, phrase.second}; op.ts = now;
        ops.push_back(op);
        add.reset(); add.bind(1, phrase.first); add.bind(2, phrase.second); add.bind(3, now); add.step();
    }
    for (const auto &phrase : base_set) {
        if (now_set.count(phrase)) continue;
        Op op;
        op.kind = 'D'; op.table = kPhraseTable; op.key = {phrase.first, phrase.second}; op.ts = now;
        ops.push_back(op);
        remove.reset(); remove.bind(1, phrase.first); remove.bind(2, phrase.second); remove.step();
        tomb.reset(); tomb.bind(1, joinKey(op.key)); tomb.bind(2, now); tomb.step();
    }
    Op order;
    order.kind = 'O'; order.table = kPhraseTable; order.ts = now; order.reg = orderOf(current);
    ops.push_back(order);
    setValue("phrase_order", order.reg);
    setNumber("phrase_order_ts", now);
    setValue("phrases_applied", live.empty() ? "[]" : live);
    if (editedDuringMerge) { ApplyResult merged; return recomputePhrases(merged); }
    return true;
}

static std::string encodeOps(const char *header, const std::vector<std::string> &extra,
    const std::vector<Store::Spec> &list, const std::vector<std::string> &lines) {
    (void)list;
    std::string text = header;
    text.push_back('\n');
    for (const auto &line : extra) { text += line; text.push_back('\n'); }
    for (const auto &line : lines) { text += line; text.push_back('\n'); }
    return text;
}

static std::string opLine(const Store::Op &op, const std::vector<Store::Spec> &list) {
    std::string line(1, op.kind);
    line += '\t';
    line += op.table == kPhraseTable ? kPhraseCode : list[size_t(op.table)].code;
    if (op.kind == 'O') return line + "\t" + std::to_string(op.ts) + "\t" + escapeField(op.reg);
    for (const auto &part : op.key) line += "\t" + escapeField(part);
    if (op.kind == 'D' || op.kind == 'T') return line + "\t" + std::to_string(op.ts);
    if (op.table == kPhraseTable) return line + "\t" + std::to_string(op.ts);
    const auto &spec = list[size_t(op.table)];
    line += "\t" + std::to_string(op.c1) + "\t" + std::to_string(op.c2) + "\t" + std::to_string(op.ts);
    if (spec.reg) line += "\t" + escapeField(op.reg);
    return line;
}

bool Store::collect(int64_t now, CollectResult &result, std::string &error) {
    result = CollectResult();
    refreshTables();
    if (!exec("BEGIN IMMEDIATE;")) { error = sqlite3_errmsg(db_); return false; }
    if (collectChanges(now, result) && exec("COMMIT;")) return true;
    error = sqlite3_errmsg(db_);
    exec("ROLLBACK;");
    result = CollectResult();
    return false;
}

bool Store::observeLocalClear(int64_t now) {
    std::string marker;
    Statement read(db_, "SELECT value FROM meta WHERE key = 'sync.local_clear'");
    if (read.ok() && read.step() == SQLITE_ROW) marker = read.text(0);
    if (value("clear_pending") != "1" && marker == value("clear_marker")) return true;
    int64_t when = now;
    if (!marker.empty()) parseInt(marker.substr(0, marker.find(':')), when);
    for (const auto &spec : specs())
        if (!exec(("DELETE FROM sync_shadow_" + std::string(spec.code)).c_str())) return false;
    return setValue("cleared_at", std::to_string(when)) && setValue("clear_marker", marker) &&
        setValue("clear_pending", "") && setValue("clear_observed", "1");
}

bool Store::collectChanges(int64_t now, CollectResult &result) {
    bool ok = !replica().empty() && observeLocalClear(now);
    result.cleared = value("clear_observed") == "1";
    if (result.cleared) ok = ok && setValue("clear_observed", "");
    std::vector<Op> ops;
    for (size_t i = 0; ok && i < specs().size(); ++i)
        if (present_[i]) ok = diffTable(specs()[i], now, ops);
    if (ok) ok = diffPhrases(now, ops);
    std::vector<std::string> lines;
    for (const auto &line : splitStaged(value("phrase_ops"))) lines.push_back(line);
    if (ok && !(ops.empty() && lines.empty())) {
        if (!exec("DELETE FROM sync_state WHERE key = 'phrase_ops';")) return false;
        lines.reserve(lines.size() + ops.size());
        for (const auto &op : ops) lines.push_back(opLine(op, specs()));
        // A record holds at most 1 MB: a big first sync goes as several batches.
        std::vector<std::string> payloads;
        std::string part = "CSY1\n";
        for (const auto &line : lines) {
            if (line.size() + 11 > kMaxBatchBytes) return false;
            if (part.size() + line.size() + 6 > kMaxBatchBytes) {
                payloads.push_back(compressText(part));
                part = "CSY1\n";
            }
            part += line;
            part += '\n';
        }
        payloads.push_back(compressText(part));
        int64_t seq = number("next_seq", 1);
        Statement st(db_, "INSERT INTO sync_outbox(seq, created, payload, uploaded) VALUES (?1, ?2, ?3, 0)");
        ok = st.ok();
        for (size_t i = 0; ok && i < payloads.size(); ++i) {
            st.reset();
            st.bind(1, seq + int64_t(i)); st.bind(2, now); st.bindBlob(3, payloads[i]);
            ok = st.step() == SQLITE_DONE;
            result.bytes += payloads[i].size();
        }
        if (ok) {
            if (!setValue("next_seq", std::to_string(seq + int64_t(payloads.size())))) return false;
            result.seq = seq + int64_t(payloads.size()) - 1;
            result.ops = lines.size();
        }
    }
    return ok;
}

std::vector<OutboxBatch> Store::outbox(bool pendingOnly) {
    std::vector<OutboxBatch> list;
    Statement st(db_, std::string("SELECT seq, created, payload, uploaded FROM sync_outbox ") +
        (pendingOnly ? "WHERE uploaded = 0 " : "") + "ORDER BY seq");
    if (!st.ok()) return list;
    while (st.step() == SQLITE_ROW) {
        OutboxBatch batch;
        batch.seq = st.integer(0);
        batch.created = st.integer(1);
        batch.payload = st.blob(2);
        batch.uploaded = st.integer(3) != 0;
        list.push_back(std::move(batch));
    }
    return list;
}

void Store::markUploaded(int64_t seq) {
    Statement st(db_, "UPDATE sync_outbox SET uploaded = 1 WHERE seq = ?1");
    if (st.ok()) { st.bind(1, seq); st.step(); }
}

std::vector<OutboxBatch> Store::forwarded() {
    std::vector<OutboxBatch> batches;
    Statement st(db_, "SELECT replica,seq,created,payload FROM sync_forward ORDER BY replica,seq");
    if (!st.ok()) return batches;
    while (st.step() == SQLITE_ROW) {
        OutboxBatch batch;
        batch.origin = st.text(0); batch.seq = st.integer(1);
        batch.created = st.integer(2); batch.payload = st.blob(3);
        batches.push_back(std::move(batch));
    }
    return batches;
}

void Store::markForwarded(const std::string &origin, int64_t seq) {
    Statement st(db_, "DELETE FROM sync_forward WHERE replica=?1 AND seq=?2");
    if (st.ok()) { st.bind(1, origin); st.bind(2, seq); st.step(); }
}

void Store::dropOutbox(int64_t throughSeq) {
    Statement st(db_, "DELETE FROM sync_outbox WHERE seq <= ?1 AND uploaded = 1");
    if (st.ok()) { st.bind(1, throughSeq); st.step(); }
}

int64_t Store::firstOwnSeq() {
    Statement st(db_, "SELECT MIN(seq) FROM sync_outbox");
    return st.ok() && st.step() == SQLITE_ROW && !st.isNull(0) ? st.integer(0) : lastOwnSeq() + 1;
}

int64_t Store::lastOwnSeq() { return number("next_seq", 1) - 1; }

// ---------------------------------------------------------------------------
// Other replicas' changes

bool Store::receive(const std::string &replica, int64_t seq, int64_t created, const std::string &payload) {
    if (replica.empty() || seq <= 0) return false;
    if (replica == this->replica()) return true;  // its own changes are in place already
    Statement known(db_, "SELECT seq FROM sync_applied WHERE replica = ?1");
    if (!known.ok()) return false;
    known.bind(1, replica);
    if (known.step() == SQLITE_ROW && known.integer(0) >= seq) return true;  // applied before
    Statement st(db_, "INSERT OR REPLACE INTO sync_inbox(replica, seq, created, payload) VALUES (?1, ?2, ?3, ?4)");
    if (!st.ok()) return false;
    st.bind(1, replica); st.bind(2, seq); st.bind(3, created); st.bindBlob(4, payload);
    return st.step() == SQLITE_DONE;
}

// The host can transport immutable batches while the keyboard is suspended. It
// never opens the keyboard dictionary, applies counters, or advertises progress.
// A crash between these transactions merely redelivers the same (replica, seq).
bool Store::exchangeWithRelay(const std::string &path, std::string &error) {
    const auto account = value("account");
    if (account.empty()) return true; // the keyboard must bind its own dictionary first
    Store relay(path);
    if (!relay.open(error, true)) return false;
    if (!relay.exec("BEGIN IMMEDIATE;")) { error = sqlite3_errmsg(relay.db_); return false; }
    const auto me = replica();
    const auto owner = relay.value("replica");
    if (!relay.value("account").empty() && relay.value("account") != account) {
        error = "background queue belongs to another account";
        return false;
    }
    if (!owner.empty() && owner != me) {
        // A restored App Group still has the old replica's transport cursor.
        // Preserve immutable outgoing work under its original CloudKit IDs.
        Statement keep(relay.db_, "INSERT OR IGNORE INTO sync_forward SELECT ?1,seq,created,payload "
                                  "FROM sync_outbox WHERE uploaded=0");
        if (!keep.ok()) return false;
        keep.bind(1, owner);
        if (keep.step() != SQLITE_DONE || !relay.exec("DELETE FROM sync_outbox; DELETE FROM sync_applied; "
            "DELETE FROM sync_state WHERE key IN ('token','last_attempt');")) return false;
    }
    if (!relay.setValue("replica", me) || !relay.setValue("account", account) || !relay.exec("COMMIT;")) {
        error = sqlite3_errmsg(relay.db_);
        return false;
    }
    relay.close();
    {
        Statement attach(db_, "ATTACH DATABASE ? AS relay");
        if (!attach.ok()) return false;
        attach.bind(1, path);
        if (attach.step() != SQLITE_DONE) { error = sqlite3_errmsg(db_); return false; }
    }
    bool ok = exec("BEGIN IMMEDIATE;") &&
        exec("INSERT OR IGNORE INTO main.sync_inbox SELECT i.* FROM relay.sync_inbox i "
             "WHERE i.seq > COALESCE((SELECT seq FROM main.sync_applied WHERE replica=i.replica),0);"
             "UPDATE main.sync_outbox SET uploaded=1 WHERE uploaded=0 AND seq IN "
             "(SELECT seq FROM relay.sync_outbox WHERE uploaded=1);") && exec("COMMIT;");
    if (ok) ok = exec("BEGIN IMMEDIATE;") &&
        exec("INSERT OR IGNORE INTO relay.sync_outbox SELECT * FROM main.sync_outbox WHERE uploaded=0;"
             "DELETE FROM relay.sync_outbox WHERE seq NOT IN (SELECT seq FROM main.sync_outbox WHERE uploaded=0);"
             "INSERT OR REPLACE INTO relay.sync_applied SELECT * FROM main.sync_applied;"
             "DELETE FROM relay.sync_inbox AS i WHERE EXISTS "
             "(SELECT 1 FROM main.sync_inbox WHERE replica=i.replica AND seq=i.seq) "
             "OR i.seq <= COALESCE((SELECT seq FROM main.sync_applied WHERE replica=i.replica),0);") &&
        exec("COMMIT;");
    if (!ok) { error = sqlite3_errmsg(db_); exec("ROLLBACK;"); }
    return exec("DETACH DATABASE relay;") && ok;
}

std::map<std::string, int64_t> Store::applied() {
    std::map<std::string, int64_t> out;
    Statement st(db_, "SELECT replica, seq FROM sync_applied");
    if (!st.ok()) return out;
    while (st.step() == SQLITE_ROW) out[st.text(0)] = st.integer(1);
    return out;
}

static bool parseOpLine(const std::string &line, const std::vector<Store::Spec> &list, Store::Op &op) {
    std::vector<std::string> f = splitLine(line);
    if (f.size() < 3 || f[0].size() != 1) return false;
    op = Store::Op();
    op.kind = f[0][0];
    if (op.kind == 'A') {  // A replica seq
        op.table = -2;
        op.key = {f[1]};
        return f.size() == 3 && parseInt(f[2], op.ts);
    }
    if (f[1] == kPhraseCode) {
        op.table = kPhraseTable;
        if (op.kind == 'O') {
            if (f.size() != 4 || !parseInt(f[2], op.ts)) return false;
            op.reg = f[3];
            return true;
        }
        if (f.size() != 5) return false;
        op.key = {f[2], f[3]};
        return parseInt(f[4], op.ts);
    }
    int index = -1;
    for (size_t i = 0; i < list.size(); ++i)
        if (f[1] == list[i].code) { index = int(i); break; }
    if (index < 0) return false;  // a table from a newer version: ignore the line
    const auto &spec = list[size_t(index)];
    op.table = index;
    const size_t n = spec.keys.size();
    if (op.kind == 'D' || op.kind == 'T') {
        if (f.size() != 2 + n + 1) return false;
        op.key.assign(f.begin() + 2, f.begin() + 2 + long(n));
        return parseInt(f[2 + n], op.ts);
    }
    if (op.kind != 'U' && op.kind != 'S') return false;
    if (f.size() != 2 + n + 3 + (spec.reg ? 1 : 0)) return false;
    op.key.assign(f.begin() + 2, f.begin() + 2 + long(n));
    if (!parseInt(f[2 + n], op.c1) || !parseInt(f[3 + n], op.c2) || !parseInt(f[4 + n], op.ts)) return false;
    if (spec.reg) op.reg = f[5 + n];
    return true;
}

bool Store::applyRowUpsert(const Spec &spec, const Op &op, bool live) {
    // Live table or shadow: the same merge, so their difference stays this replica's.
    const std::string table = live ? spec.table : "sync_shadow_" + std::string(spec.code);
    const std::string c1 = live ? (spec.c1 ? spec.c1 : "") : "c1";
    const std::string c2 = live ? (spec.c2 ? spec.c2 : "") : "c2";
    const std::string ts = live ? spec.ts : "ts";
    const std::string reg = live ? (spec.reg ? spec.reg : "") : "reg";
    const bool hasC1 = spec.c1 != nullptr, hasC2 = spec.c2 != nullptr, hasReg = spec.reg != nullptr;
    const int n = int(spec.keys.size());
    std::string where;
    for (int i = 0; i < n; ++i) where += std::string(i ? " AND " : "") + spec.keys[size_t(i)] + " = ?" + std::to_string(i + 1);
    std::string select = "SELECT " + std::string(hasC1 ? "IFNULL(" + c1 + ", 0)" : "0") + ", " +
        (hasC2 ? "IFNULL(" + c2 + ", 0)" : "0") + ", IFNULL(" + ts + ", 0), " + (hasReg ? reg : "NULL") +
        " FROM " + table + " WHERE " + where;
    Statement find(cached(select));
    if (!find.ok()) return false;
    for (int i = 0; i < n; ++i) find.bind(i + 1, op.key[size_t(i)]);
    int rc = find.step();
    int64_t oldC1 = 0, oldC2 = 0, oldTs = 0;
    std::string oldReg;
    if (rc == SQLITE_ROW) {
        oldC1 = find.integer(0); oldC2 = find.integer(1); oldTs = find.integer(2); oldReg = find.text(3);
    }
    find.reset();
    if (rc == SQLITE_ROW) {
        int64_t newC1 = clampCounter(oldC1 + op.c1, spec.cap1);
        int64_t newC2 = clampCounter(oldC2 + op.c2, spec.cap2);
        std::string newReg = op.ts == oldTs ? std::max(oldReg, op.reg) : (op.ts > oldTs ? op.reg : oldReg);
        std::string set = ts + " = ?" + std::to_string(n + 1);
        if (hasC1) set += ", " + c1 + " = ?" + std::to_string(n + 2);
        if (hasC2) set += ", " + c2 + " = ?" + std::to_string(n + 3);
        if (hasReg) set += ", " + reg + " = ?" + std::to_string(n + 4);
        Statement update(cached("UPDATE " + table + " SET " + set + " WHERE " + where));
        if (!update.ok()) return false;
        for (int i = 0; i < n; ++i) update.bind(i + 1, op.key[size_t(i)]);
        update.bind(n + 1, std::max(oldTs, op.ts));
        if (hasC1) update.bind(n + 2, newC1);
        if (hasC2) update.bind(n + 3, newC2);
        if (hasReg) update.bind(n + 4, newReg);
        return update.step() == SQLITE_DONE;
    }
    if (rc != SQLITE_DONE) return false;
    if (live && spec.tombs && op.kind == 'U') {
        Statement shadow(cached("SELECT 1 FROM sync_shadow_" + std::string(spec.code) + " WHERE " + where));
        if (!shadow.ok()) return false;
        for (int i = 0; i < n; ++i) shadow.bind(i + 1, op.key[size_t(i)]);
        if (shadow.step() == SQLITE_ROW) return true; // unsent local deletion; collect its tombstone
    }
    int64_t newC1 = clampCounter(op.c1, spec.cap1), newC2 = clampCounter(op.c2, spec.cap2);
    // A counter row with nothing left to count stays absent.
    if ((hasC1 || hasC2) && newC1 == 0 && newC2 == 0) return true;
    std::string columns, marks;
    for (int i = 0; i < n; ++i) {
        columns += std::string(spec.keys[size_t(i)]) + ", ";
        marks += "?" + std::to_string(i + 1) + ", ";
    }
    columns += ts;
    marks += "?" + std::to_string(n + 1);
    if (hasC1) { columns += ", " + c1; marks += ", ?" + std::to_string(n + 2); }
    if (hasC2) { columns += ", " + c2; marks += ", ?" + std::to_string(n + 3); }
    if (hasReg) { columns += ", " + reg; marks += ", ?" + std::to_string(n + 4); }
    Statement insert(cached("INSERT INTO " + table + " (" + columns + ") VALUES (" + marks + ")"));
    if (!insert.ok()) return false;
    for (int i = 0; i < n; ++i) insert.bind(i + 1, op.key[size_t(i)]);
    insert.bind(n + 1, op.ts);
    if (hasC1) insert.bind(n + 2, newC1);
    if (hasC2) insert.bind(n + 3, newC2);
    if (hasReg) insert.bind(n + 4, op.reg);
    return insert.step() == SQLITE_DONE;
}

bool Store::applyRowDelete(const Spec &spec, const Op &op) {
    const int n = int(spec.keys.size());
    std::string where;
    for (int i = 0; i < n; ++i) where += std::string(i ? " AND " : "") + spec.keys[size_t(i)] + " = ?" + std::to_string(i + 1);
    const std::string shadow = "sync_shadow_" + std::string(spec.code);
    auto bindKey = [&](Statement &st) { for (int i = 0; i < n; ++i) st.bind(i + 1, op.key[size_t(i)]); };
    Statement known(cached("SELECT c1, c2, ts FROM " + shadow + " WHERE " + where));
    if (!known.ok()) return false;
    bindKey(known);
    int rc = known.step();
    int64_t syncedC1 = 0, syncedC2 = 0, syncedTs = 0;
    if (rc == SQLITE_ROW) { syncedC1 = known.integer(0); syncedC2 = known.integer(1); syncedTs = known.integer(2); }
    known.reset();
    if (rc == SQLITE_ROW) {
        // What this replica knew is newer than the deletion: it does not apply.
        if (syncedTs > op.ts) return true;
        Statement drop(cached("DELETE FROM " + shadow + " WHERE " + where));
        if (!drop.ok()) return false;
        bindKey(drop);
        if (drop.step() != SQLITE_DONE) return false;
    } else if (rc != SQLITE_DONE) {
        return false;
    }
    const bool counters = spec.c1 || spec.c2;
    std::string select = "SELECT IFNULL(" + std::string(spec.ts) + ", 0), " +
        (spec.c1 ? "IFNULL(" + std::string(spec.c1) + ", 0)" : std::string("0")) + ", " +
        (spec.c2 ? "IFNULL(" + std::string(spec.c2) + ", 0)" : std::string("0")) + " FROM " + spec.table + " WHERE " + where;
    Statement live(cached(select));
    if (!live.ok()) return false;
    bindKey(live);
    rc = live.step();
    if (rc == SQLITE_DONE) return true;
    if (rc != SQLITE_ROW) return false;
    int64_t liveTs = live.integer(0);
    int64_t restC1 = live.integer(1) - syncedC1, restC2 = live.integer(2) - syncedC2;
    live.reset();
    if (liveTs <= op.ts || (counters && restC1 <= 0 && restC2 <= 0)) {
        Statement drop(cached("DELETE FROM " + std::string(spec.table) + " WHERE " + where));
        if (!drop.ok()) return false;
        bindKey(drop);
        return drop.step() == SQLITE_DONE;
    }
    if (!counters) return true;  // used here after the deletion: keep the newer value
    // Used here after the deletion: keep only what this replica has not sent yet.
    std::string set;
    if (spec.c1) set += std::string(spec.c1) + " = ?" + std::to_string(n + 1);
    if (spec.c2) set += std::string(set.empty() ? "" : ", ") + spec.c2 + " = ?" + std::to_string(n + 2);
    Statement update(cached("UPDATE " + std::string(spec.table) + " SET " + set + " WHERE " + where));
    if (!update.ok()) return false;
    bindKey(update);
    if (spec.c1) update.bind(n + 1, std::max<int64_t>(restC1, 0));
    if (spec.c2) update.bind(n + 2, std::max<int64_t>(restC2, 0));
    return update.step() == SQLITE_DONE;
}

bool Store::applyOp(const Op &op, int64_t clearedAt, ApplyResult &result, bool shadowOnlyRows) {
    result.ops++;
    Statement tombOf(cached("SELECT ts FROM sync_tomb WHERE tbl = ?1 AND key = ?2"));
    if (!tombOf.ok()) return false;
    const std::string code = op.table == kPhraseTable ? kPhraseCode : specs()[size_t(op.table)].code;
    if (op.table == kPhraseTable) {
        if (op.kind == 'O') {
            int64_t current = number("phrase_order_ts", 0);
            if (op.ts > current || (op.ts == current && op.reg > value("phrase_order"))) {
                setValue("phrase_order", op.reg);
                setNumber("phrase_order_ts", op.ts);
                result.phrasesChanged = true;
            }
            return true;
        }
        const std::string key = joinKey(op.key);
        if (op.kind == 'U' || op.kind == 'S') {
            tombOf.bind(1, code); tombOf.bind(2, key);
            if (tombOf.step() == SQLITE_ROW && tombOf.integer(0) >= op.ts) { result.skipped++; return true; }
            // Added on two replicas: the earlier time, the same everywhere.
            Statement known(db_, "SELECT added FROM sync_phrase WHERE shortcut = ?1 AND text = ?2");
            if (!known.ok()) return false;
            known.bind(1, op.key[0]); known.bind(2, op.key[1]);
            if (known.step() == SQLITE_ROW) {
                if (known.integer(0) <= op.ts) return true;
                Statement earlier(db_, "UPDATE sync_phrase SET added = ?3 WHERE shortcut = ?1 AND text = ?2");
                if (!earlier.ok()) return false;
                earlier.bind(1, op.key[0]); earlier.bind(2, op.key[1]); earlier.bind(3, op.ts);
                if (earlier.step() != SQLITE_DONE) return false;
                result.phrasesChanged = true;
                return true;
            }
            Statement add(db_, "INSERT INTO sync_phrase(shortcut, text, added) VALUES (?1, ?2, ?3)");
            if (!add.ok()) return false;
            add.bind(1, op.key[0]); add.bind(2, op.key[1]); add.bind(3, op.ts);
            if (add.step() != SQLITE_DONE) return false;
            result.phrasesChanged = true;
            return true;
        }
        Statement tomb(db_, "INSERT INTO sync_tomb(tbl, key, ts) VALUES (?1, ?2, ?3) "
                            "ON CONFLICT(tbl, key) DO UPDATE SET ts = MAX(ts, excluded.ts)");
        Statement remove(db_, "DELETE FROM sync_phrase WHERE shortcut = ?1 AND text = ?2 AND added <= ?3");
        if (!tomb.ok() || !remove.ok()) return false;
        tomb.bind(1, code); tomb.bind(2, key); tomb.bind(3, op.ts);
        if (tomb.step() != SQLITE_DONE) return false;
        if (op.kind == 'T') return true;
        remove.bind(1, op.key[0]); remove.bind(2, op.key[1]); remove.bind(3, op.ts);
        if (remove.step() != SQLITE_DONE) return false;
        if (sqlite3_changes(db_) > 0) result.phrasesChanged = true;
        return true;
    }
    const auto &spec = specs()[size_t(op.table)];
    if (!present_[size_t(op.table)]) return false; // retry after the engine initializes its schema
    if (op.key.size() != spec.keys.size()) return false;
    const std::string key = joinKey(op.key);
    if (op.kind == 'T') {
        Statement tomb(cached("INSERT INTO sync_tomb(tbl, key, ts) VALUES (?1, ?2, ?3) "
                              "ON CONFLICT(tbl, key) DO UPDATE SET ts = MAX(ts, excluded.ts)"));
        if (!tomb.ok()) return false;
        tomb.bind(1, code); tomb.bind(2, key); tomb.bind(3, op.ts);
        return tomb.step() == SQLITE_DONE;
    }
    if (op.kind == 'U' || op.kind == 'S') {
        if (clearedAt > 0 && op.ts <= clearedAt) { result.skipped++; return true; }
        tombOf.bind(1, code); tombOf.bind(2, key);
        bool older = tombOf.step() == SQLITE_ROW && tombOf.integer(0) >= op.ts;
        tombOf.reset();
        if (older) { result.skipped++; return true; }
        result.learningChanged = true;
        return (shadowOnlyRows || applyRowUpsert(spec, op, true)) && applyRowUpsert(spec, op, false);
    }
    if (op.kind == 'D') {
        Statement tomb(cached("INSERT INTO sync_tomb(tbl, key, ts) VALUES (?1, ?2, ?3) "
                              "ON CONFLICT(tbl, key) DO UPDATE SET ts = MAX(ts, excluded.ts)"));
        if (!tomb.ok()) return false;
        tomb.bind(1, code); tomb.bind(2, key); tomb.bind(3, op.ts);
        if (tomb.step() != SQLITE_DONE) return false;
        result.learningChanged = true;
        return applyRowDelete(spec, op);
    }
    return false;
}

bool Store::applyPayload(const std::string &payload, ApplyResult &result, std::string &error) {
    std::string text;
    if (!decompressText(payload, text)) { error = "batch does not decompress"; return false; }
    size_t start = 0, end = text.find('\n');
    if (end == std::string::npos || text.compare(0, end, "CSY1") != 0) { error = "not a sync batch"; return false; }
    int64_t clearedAt = number("cleared_at", 0);
    start = end + 1;
    while (start < text.size()) {
        end = text.find('\n', start);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(start, end - start);
        start = end + 1;
        if (line.empty()) continue;
        Op op;
        if (!parseOpLine(line, specs(), op)) { result.skipped++; continue; }
        if (op.kind != 'U' && op.kind != 'D' && op.kind != 'O') { result.skipped++; continue; }
        if (!applyOp(op, clearedAt, result, false)) { error = sqlite3_errmsg(db_); return false; }
    }
    return true;
}

bool Store::stagePhrases(int64_t now) {
    std::vector<Op> ops;
    bool ok = observeLocalClear(now) && diffPhrases(now, ops);
    if (ok && !ops.empty()) {
        std::string staged = value("phrase_ops");
        for (const auto &op : ops) staged += opLine(op, specs()) + "\n";
        setValue("phrase_ops", staged);
    }
    if (ok && !value("phrases_pending").empty()) {
        ApplyResult pending;
        ok = recomputePhrases(pending);
    }
    return ok;
}

bool Store::applyReceived(int64_t now, ApplyResult &result, std::string &error) {
    refreshTables();

    std::vector<std::string> replicas;
    {
        Statement st(db_, "SELECT DISTINCT replica FROM sync_inbox");
        if (!st.ok()) { error = sqlite3_errmsg(db_); return false; }
        while (st.step() == SQLITE_ROW) replicas.push_back(st.text(0));
    }
    for (const auto &replica : replicas) {
        while (true) {
            int64_t next = 1;
            {
                Statement st(db_, "SELECT seq FROM sync_applied WHERE replica = ?1");
                st.bind(1, replica);
                if (st.step() == SQLITE_ROW) next = st.integer(0) + 1;
            }
            std::string payload;
            {
                Statement st(db_, "SELECT payload FROM sync_inbox WHERE replica = ?1 AND seq = ?2");
                st.bind(1, replica); st.bind(2, next);
                if (st.step() != SQLITE_ROW) {
                    Statement later(db_, "SELECT MIN(seq) FROM sync_inbox WHERE replica = ?1 AND seq > ?2");
                    later.bind(1, replica); later.bind(2, next);
                    if (later.step() == SQLITE_ROW && !later.isNull(0)) result.waiting[replica] = next;
                    // Batches already applied (a snapshot covered them) are dropped.
                    Statement stale(db_, "DELETE FROM sync_inbox WHERE replica = ?1 AND seq < ?2");
                    stale.bind(1, replica); stale.bind(2, next); stale.step();
                    break;
                }
                payload = st.blob(0);
            }
            if (!exec("BEGIN IMMEDIATE;")) { error = sqlite3_errmsg(db_); return false; }
            Statement stillPending(cached("SELECT 1 FROM sync_inbox WHERE replica=?1 AND seq=?2"));
            if (!stillPending.ok()) { error = sqlite3_errmsg(db_); exec("ROLLBACK;"); return false; }
            stillPending.bind(1, replica); stillPending.bind(2, next);
            int rc = stillPending.step();
            if (rc == SQLITE_DONE) { exec("ROLLBACK;"); continue; }
            if (rc != SQLITE_ROW) { error = sqlite3_errmsg(db_); exec("ROLLBACK;"); return false; }
            stillPending.reset();
            ApplyResult batch;
            bool ok = stagePhrases(now) && applyPayload(payload, batch, error);
            if (ok) {
                Statement mark(db_, "INSERT INTO sync_applied(replica, seq) VALUES (?1, ?2) "
                                    "ON CONFLICT(replica) DO UPDATE SET seq = excluded.seq");
                Statement drop(db_, "DELETE FROM sync_inbox WHERE replica = ?1 AND seq = ?2");
                ok = mark.ok() && drop.ok();
                if (ok) {
                    mark.bind(1, replica); mark.bind(2, next);
                    drop.bind(1, replica); drop.bind(2, next);
                    ok = mark.step() == SQLITE_DONE && drop.step() == SQLITE_DONE;
                }
            }
            if (ok && batch.phrasesChanged) ok = recomputePhrases(batch);
            if (ok && (batch.learningChanged || batch.phrasesChanged))
                ok = setValue("engine_revision", std::to_string(number("engine_revision") + 1));
            if (!ok || !exec("COMMIT;")) {
                if (error.empty()) error = sqlite3_errmsg(db_);
                exec("ROLLBACK;");
                return false;
            }
            result.batches++;
            result.ops += batch.ops;
            result.skipped += batch.skipped;
            result.learningChanged = result.learningChanged || batch.learningChanged;
            result.phrasesChanged = result.phrasesChanged || batch.phrasesChanged;
        }
    }
    // Old tombstones go: a replica that has been away this long rebases on a snapshot.
    Statement purge(db_, "DELETE FROM sync_tomb WHERE ts < ?1");
    if (purge.ok()) { purge.bind(1, now - kTombDays * 86400); purge.step(); }
    return true;
}

// ---------------------------------------------------------------------------
// Phrases: merge the known set in the latest order, for the engine.

bool Store::recomputePhrases(ApplyResult &result) {
    std::vector<std::tuple<std::string, std::string, int64_t>> known;
    {
        Statement st(db_, "SELECT shortcut, text, added FROM sync_phrase");
        if (!st.ok()) return false;
        while (st.step() == SQLITE_ROW) known.emplace_back(st.text(0), st.text(1), st.integer(2));
    }
    std::unordered_map<std::string, size_t> rank;
    {
        std::string order = value("phrase_order");
        size_t index = 0, start = 0;
        while (start < order.size()) {
            size_t comma = order.find(',', start);
            if (comma == std::string::npos) comma = order.size();
            rank.emplace(order.substr(start, comma - start), index++);
            start = comma + 1;
        }
    }
    std::vector<std::pair<std::tuple<size_t, int64_t, std::string, std::string>, Phrase>> sorted;
    for (const auto &item : known) {
        Phrase phrase(std::get<0>(item), std::get<1>(item));
        auto found = rank.find(phraseHash(phrase));
        size_t position = found == rank.end() ? SIZE_MAX : found->second;
        sorted.push_back({{position, std::get<2>(item), phrase.first, phrase.second}, phrase});
    }
    std::sort(sorted.begin(), sorted.end(), [](const auto &a, const auto &b) { return a.first < b.first; });
    std::vector<Phrase> merged;
    for (const auto &item : sorted) {
        if (merged.size() >= kMaxPhrases) break;
        merged.push_back(item.second);
    }
    std::vector<Phrase> current;
    std::string live;
    if (tableExists("meta")) {
        Statement st(db_, "SELECT value FROM meta WHERE key = 'setting.custom_phrases'");
        if (st.ok() && st.step() == SQLITE_ROW) live = st.text(0);
    }
    if (!parsePhrases(live, current)) return false;
    if (merged == current) {
        exec("DELETE FROM sync_state WHERE key IN ('phrases_pending', 'phrases_pending_base');");
        setValue("phrases_applied", live.empty() ? "[]" : live);
        result.phrasesChanged = false;
        return true;
    }
    // Called inside the batch transaction after staging local edits. Publish the
    // phrases with the learning rows and their applied sequence, even if the
    // process is suspended before it can notify the engine.
    const auto json = phrasesJson(merged);
    Statement save(db_, "INSERT INTO meta(key,value) VALUES ('setting.custom_phrases',?1) "
                        "ON CONFLICT(key) DO UPDATE SET value=excluded.value");
    if (!save.ok()) return false;
    save.bind(1, json);
    result.phrasesChanged = true;
    return save.step() == SQLITE_DONE && setValue("phrases_applied", json) &&
        exec("DELETE FROM sync_state WHERE key IN ('phrases_pending', 'phrases_pending_base');");
}

std::optional<PendingPhrases> Store::pendingPhrases() {
    std::string merged = value("phrases_pending");
    if (merged.empty()) return std::nullopt;
    return PendingPhrases{value("phrases_pending_base"), merged};
}

bool Store::confirmPhrases(const std::string &json) {
    if (!exec("BEGIN IMMEDIATE;")) return false;
    // A newer merge replaced the one the engine took: that one is still to apply.
    bool current = value("phrases_pending") == json;
    if (current) {
        setValue("phrases_applied", json);
        exec("DELETE FROM sync_state WHERE key IN ('phrases_pending', 'phrases_pending_base');");
    }
    if (!exec("COMMIT;")) { exec("ROLLBACK;"); return false; }
    return current;
}

// ---------------------------------------------------------------------------
// Snapshots

bool Store::exportSnapshot(int64_t now, std::string &payload, std::string &error) {
    std::vector<std::string> head, lines;
    // A read transaction: one consistent state.
    if (!exec("BEGIN;")) { error = sqlite3_errmsg(db_); return false; }
    head.push_back("A\t" + escapeField(replica()) + "\t" + std::to_string(lastOwnSeq()));
    for (const auto &entry : applied())
        head.push_back("A\t" + escapeField(entry.first) + "\t" + std::to_string(entry.second));
    for (size_t t = 0; t < specs().size(); ++t) {
        const auto &spec = specs()[t];
        std::string keys;
        for (size_t i = 0; i < spec.keys.size(); ++i) keys += std::string(i ? ", " : "") + spec.keys[i];
        Statement st(db_, "SELECT " + keys + ", c1, c2, ts, reg FROM sync_shadow_" + spec.code);
        if (!st.ok()) { exec("ROLLBACK;"); error = sqlite3_errmsg(db_); return false; }
        const int n = int(spec.keys.size());
        while (st.step() == SQLITE_ROW) {
            Op op;
            op.kind = 'S';
            op.table = int(t);
            for (int i = 0; i < n; ++i) op.key.push_back(st.text(i));
            op.c1 = st.integer(n); op.c2 = st.integer(n + 1); op.ts = st.integer(n + 2); op.reg = st.text(n + 3);
            lines.push_back(opLine(op, specs()));
        }
    }
    {
        Statement st(db_, "SELECT tbl, key, ts FROM sync_tomb WHERE ts >= ?1");
        st.bind(1, now - kTombDays * 86400);
        while (st.step() == SQLITE_ROW) {
            std::string code = st.text(0), key = st.text(1);
            std::string line = "T\t" + escapeField(code);
            size_t start = 0;
            while (true) {
                size_t sep = key.find('\x1f', start);
                line += "\t" + escapeField(key.substr(start, sep == std::string::npos ? std::string::npos : sep - start));
                if (sep == std::string::npos) break;
                start = sep + 1;
            }
            lines.push_back(line + "\t" + std::to_string(st.integer(2)));
        }
    }
    {
        Statement st(db_, "SELECT shortcut, text, added FROM sync_phrase");
        while (st.step() == SQLITE_ROW)
            lines.push_back("S\tphrase\t" + escapeField(st.text(0)) + "\t" + escapeField(st.text(1)) + "\t" +
                std::to_string(st.integer(2)));
    }
    std::string order = value("phrase_order");
    if (!order.empty() || number("phrase_order_ts", 0) > 0)
        lines.push_back("O\tphrase\t" + std::to_string(number("phrase_order_ts", 0)) + "\t" + order);
    exec("COMMIT;");
    payload = compressText(encodeOps("CSS1", head, specs(), lines));
    return true;
}

bool Store::importSnapshot(const std::string &payload, ApplyResult &result, std::string &error) {
    std::string text;
    if (!decompressText(payload, text)) { error = "snapshot does not decompress"; return false; }
    size_t start = 0, end = text.find('\n');
    if (end == std::string::npos || text.compare(0, end, "CSS1") != 0) { error = "not a snapshot"; return false; }
    std::vector<Op> ops;
    std::map<std::string, int64_t> vector;
    start = end + 1;
    while (start < text.size()) {
        end = text.find('\n', start);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(start, end - start);
        start = end + 1;
        if (line.empty()) continue;
        Op op;
        if (!parseOpLine(line, specs(), op)) continue;
        if (op.kind == 'A') vector[op.key[0]] = op.ts;
        else ops.push_back(std::move(op));
    }
    const std::string self = replica();
    const int64_t mine = vector.count(self) ? vector[self] : 0;
    if (!exec("BEGIN IMMEDIATE;")) { error = sqlite3_errmsg(db_); return false; }
    // Capture keystrokes inside the same write transaction that replaces live rows.
    CollectResult collected;
    bool ok = collectChanges(int64_t(time(nullptr)), collected);
    std::vector<OutboxBatch> own = outbox(false);
    for (size_t t = 0; ok && t < specs().size(); ++t) {
        ok = exec(("DELETE FROM sync_shadow_" + std::string(specs()[t].code) + ";").c_str());
        if (ok && present_[t]) ok = exec(("DELETE FROM " + std::string(specs()[t].table) + ";").c_str());
    }
    ok = ok && exec("DELETE FROM sync_phrase; DELETE FROM sync_applied;");
    int64_t clearedAt = number("cleared_at", 0);
    ApplyResult loaded;
    for (size_t i = 0; ok && i < ops.size(); ++i) {
        const Op &op = ops[i];
        if (op.kind == 'O' && op.table == kPhraseTable) {
            setValue("phrase_order", op.reg);
            setNumber("phrase_order_ts", op.ts);
            continue;
        }
        ok = applyOp(op, clearedAt, loaded, false);
    }
    for (const auto &entry : vector) {
        if (!ok || entry.first == self) continue;
        Statement mark(db_, "INSERT INTO sync_applied(replica, seq) VALUES (?1, ?2)");
        ok = mark.ok();
        if (ok) { mark.bind(1, entry.first); mark.bind(2, entry.second); ok = mark.step() == SQLITE_DONE; }
    }
    // This replica's batches the snapshot does not contain go on top, as it sent them.
    for (const auto &batch : own) {
        if (!ok || batch.seq <= mine) continue;
        ok = applyPayload(batch.payload, loaded, error);
    }
    if (ok) {
        ApplyResult phrases;
        phrases.phrasesChanged = true;
        ok = recomputePhrases(phrases);
        result.phrasesChanged = phrases.phrasesChanged;
    }
    // The snapshot may predate remote batches already removed from our inbox.
    // Replay retained cloud history even if the process stops after the import.
    if (!ok || !setValue("token", "") || !setValue("engine_revision", std::to_string(number("engine_revision") + 1)) || !exec("COMMIT;")) {
        if (error.empty()) error = sqlite3_errmsg(db_);
        exec("ROLLBACK;");
        return false;
    }
    result.learningChanged = true;
    result.ops += loaded.ops;
    return applyReceived(int64_t(time(nullptr)), result, error);
}

std::string formatApplied(const std::map<std::string, int64_t> &applied) {
    std::string out;
    for (const auto &entry : applied) {
        if (!out.empty()) out.push_back(',');
        out += entry.first + ":" + std::to_string(entry.second);
    }
    return out;
}

std::map<std::string, int64_t> parseApplied(const std::string &text) {
    std::map<std::string, int64_t> out;
    size_t start = 0;
    while (start < text.size()) {
        size_t comma = text.find(',', start);
        if (comma == std::string::npos) comma = text.size();
        std::string item = text.substr(start, comma - start);
        size_t colon = item.rfind(':');
        int64_t seq;
        if (colon != std::string::npos && parseInt(item.substr(colon + 1), seq)) out[item.substr(0, colon)] = seq;
        start = comma + 1;
    }
    return out;
}

bool parsePhraseList(const std::string &json, PhraseList &out) { return parsePhrases(json, out); }
std::string phraseListJson(const PhraseList &list) { return phrasesJson(list); }

bool Store::noteReplica(const ReplicaInfo &info) {
    Statement st(db_, "INSERT OR REPLACE INTO sync_replica(replica, platform, label, last_seq, min_seq, "
                      "last_sync, applied) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)");
    if (!st.ok()) return false;
    st.bind(1, info.replica); st.bind(2, info.platform); st.bind(3, info.label); st.bind(4, info.lastSeq);
    st.bind(5, info.minSeq); st.bind(6, info.lastSync); st.bind(7, formatApplied(info.applied));
    return st.step() == SQLITE_DONE;
}

bool Store::noteSnapshot(const SnapshotInfo &info) {
    Statement st(db_, "INSERT OR REPLACE INTO sync_snapshot(replica, generation, parts, created, applied) "
                      "VALUES (?1, ?2, ?3, ?4, ?5)");
    if (!st.ok()) return false;
    st.bind(1, info.replica); st.bind(2, info.generation); st.bind(3, info.parts); st.bind(4, info.created);
    st.bind(5, formatApplied(info.applied));
    return st.step() == SQLITE_DONE;
}

bool Store::forgetReplica(const std::string &replica) {
    Statement st(db_, "DELETE FROM sync_replica WHERE replica = ?1");
    if (!st.ok()) return false;
    st.bind(1, replica);
    return st.step() == SQLITE_DONE;
}

bool Store::forgetSnapshot(const std::string &replica) {
    Statement st(db_, "DELETE FROM sync_snapshot WHERE replica = ?1");
    if (!st.ok()) return false;
    st.bind(1, replica);
    return st.step() == SQLITE_DONE;
}

std::vector<ReplicaInfo> Store::replicas() {
    std::vector<ReplicaInfo> list;
    Statement st(db_, "SELECT replica, platform, label, last_seq, min_seq, last_sync, applied FROM sync_replica");
    if (!st.ok()) return list;
    while (st.step() == SQLITE_ROW) {
        ReplicaInfo info;
        info.replica = st.text(0); info.platform = st.text(1); info.label = st.text(2);
        info.lastSeq = st.integer(3); info.minSeq = st.integer(4); info.lastSync = st.integer(5);
        info.applied = parseApplied(st.text(6));
        list.push_back(std::move(info));
    }
    return list;
}

std::vector<SnapshotInfo> Store::snapshots() {
    std::vector<SnapshotInfo> list;
    Statement st(db_, "SELECT replica, generation, parts, created, applied FROM sync_snapshot");
    if (!st.ok()) return list;
    while (st.step() == SQLITE_ROW) {
        SnapshotInfo info;
        info.replica = st.text(0); info.generation = st.integer(1); info.parts = st.integer(2);
        info.created = st.integer(3); info.applied = parseApplied(st.text(4));
        list.push_back(std::move(info));
    }
    return list;
}

int64_t Store::ownSeqSafeToDelete(int64_t now, int64_t liveWindow, int64_t olderThan) {
    const std::string self = replica();
    // Without a snapshot holding them, a new replica would need every batch.
    std::vector<SnapshotInfo> held = snapshots();
    if (held.empty()) return 0;
    int64_t safe = lastOwnSeq();
    for (const auto &snapshot : held) {
        auto found = snapshot.applied.find(self);
        safe = std::min(safe, found == snapshot.applied.end() ? 0 : found->second);
    }
    for (const auto &other : replicas()) {
        if (other.replica == self || other.lastSync < now - liveWindow) continue;
        auto found = other.applied.find(self);
        safe = std::min(safe, found == other.applied.end() ? 0 : found->second);
    }
    Statement st(db_, "SELECT MAX(seq) FROM sync_outbox WHERE seq <= ?1 AND uploaded = 1 AND created <= ?2");
    if (!st.ok()) return 0;
    st.bind(1, safe); st.bind(2, olderThan);
    return st.step() == SQLITE_ROW && !st.isNull(0) ? st.integer(0) : 0;
}

void Store::markAllUnuploaded() { exec("UPDATE sync_outbox SET uploaded = 0;"); }

// Publish a consistent SQLite snapshot (including committed WAL pages) atomically.
bool backupDictionary(const std::string &source, const std::string &destination, std::string &error) {
    std::string temp = destination + ".XXXXXX";
    int fd = mkstemp(temp.data());
    if (fd < 0) { error = strerror(errno); return false; }
    close(fd);
    sqlite3 *from = nullptr, *to = nullptr;
    bool ok = sqlite3_open_v2(source.c_str(), &from, SQLITE_OPEN_READONLY, nullptr) == SQLITE_OK &&
        sqlite3_open_v2(temp.c_str(), &to, SQLITE_OPEN_READWRITE, nullptr) == SQLITE_OK;
    if (ok) {
        sqlite3_backup *backup = sqlite3_backup_init(to, "main", from, "main");
        ok = backup != nullptr;
        if (backup) {
            int rc = sqlite3_backup_step(backup, -1);
            ok = sqlite3_backup_finish(backup) == SQLITE_OK && rc == SQLITE_DONE;
        }
    }
    if (ok) {
        Statement schema(to, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('meta','dict_user')");
        ok = schema.ok() && schema.step() == SQLITE_ROW && schema.integer(0) == 2;
    }
    if (ok) {
        Statement check(to, "PRAGMA quick_check");
        ok = check.ok() && check.step() == SQLITE_ROW && check.text(0) == "ok";
    }
    if (ok) ok = sqlite3_exec(to, "PRAGMA journal_mode=DELETE", nullptr, nullptr, nullptr) == SQLITE_OK;
    if (!ok) error = to ? sqlite3_errmsg(to) : "cannot open legacy dictionary";
    sqlite3_close(to);
    sqlite3_close(from);
    if (ok && rename(temp.c_str(), destination.c_str()) != 0) { error = strerror(errno); ok = false; }
    unlink(temp.c_str());
    return ok;
}

bool importLegacyDictionary(const std::string &source, const std::string &destination,
    const std::string &sourceID, std::string &error) {
    // When there is no dictionary yet the whole backup preserves settings and any
    // older schema. Publish without replacing a dictionary initialized concurrently.
    if (access(destination.c_str(), F_OK) != 0) {
        std::string fresh = destination + ".import.XXXXXX";
        int fd = mkstemp(fresh.data());
        if (fd < 0) { error = strerror(errno); return false; }
        close(fd);
        bool copied = backupDictionary(source, fresh, error);
        if (copied && link(fresh.c_str(), destination.c_str()) != 0 && errno != EEXIST) {
            error = strerror(errno);
            copied = false;
        }
        unlink(fresh.c_str());
        if (!copied) return false;
    }
    sqlite3 *db = nullptr;
    int rc = sqlite3_open_v2(destination.c_str(), &db, SQLITE_OPEN_READWRITE, nullptr);
    auto run = [&](const std::string &sql) { return sqlite3_exec(db, sql.c_str(), nullptr, nullptr, nullptr) == SQLITE_OK; };
    auto merge = [&]() {
        Statement attach(db, "ATTACH DATABASE ? AS legacy");
        if (!attach.ok()) return false;
        attach.bind(1, source);
        if (attach.step() != SQLITE_DONE || !run("BEGIN IMMEDIATE")) return false;
        const auto marker = "migration." + sourceID;
        Statement imported(db, "SELECT 1 FROM main.meta WHERE key=?");
        if (!imported.ok()) return false;
        imported.bind(1, marker);
        if (imported.step() == SQLITE_ROW) return run("COMMIT");
        Statement check(db, "PRAGMA legacy.quick_check");
        if (!check.ok() || check.step() != SQLITE_ROW || check.text(0) != "ok") return false;
        check.reset();
        // An earlier developer install may already have copied some (or all) of
        // these rows. With no common operation log, take the stronger counter.
        for (const auto &spec : specs()) {
            Statement exists(db, "SELECT 1 FROM legacy.sqlite_master WHERE type='table' AND name=?");
            if (!exists.ok()) return false;
            exists.bind(1, std::string(spec.table));
            if (exists.step() != SQLITE_ROW) continue;
            std::string keys, updates;
            for (const char *key : spec.keys) keys += (keys.empty() ? "" : ",") + std::string(key);
            std::string cols = keys;
            for (const char *counter : {spec.c1, spec.c2}) {
                if (!counter) continue;
                cols += "," + std::string(counter);
                updates += std::string(counter) + "=max(ifnull(" + counter + ",0),ifnull(excluded." + counter + ",0)),";
            }
            if (spec.reg) {
                cols += "," + std::string(spec.reg);
                updates += std::string(spec.reg) + "=CASE WHEN excluded." + spec.ts + ">" + spec.ts +
                    " THEN excluded." + spec.reg + " ELSE " + spec.reg + " END,";
            }
            cols += "," + std::string(spec.ts);
            updates += std::string(spec.ts) + "=max(ifnull(" + spec.ts + ",0),ifnull(excluded." + spec.ts + ",0))";
            if (!run("INSERT INTO main." + std::string(spec.table) + "(" + cols + ") SELECT " + cols +
                " FROM legacy." + spec.table + " WHERE true ON CONFLICT(" + keys + ") DO UPDATE SET " + updates)) return false;
        }
        if (!run("INSERT OR IGNORE INTO main.meta SELECT key,value FROM legacy.meta WHERE key LIKE 'setting.%'")) return false;
        PhraseList phrases, old;
        for (auto pair : {std::make_pair("main", &phrases), std::make_pair("legacy", &old)}) {
            Statement get(db, std::string("SELECT value FROM ") + pair.first + ".meta WHERE key='setting.custom_phrases'");
            if (!get.ok() || (get.step() == SQLITE_ROW && !parsePhraseList(get.text(0), *pair.second))) return false;
        }
        std::set<Phrase> included(phrases.begin(), phrases.end());
        for (const auto &phrase : old)
            if (included.insert(phrase).second) phrases.push_back(phrase);
        if (phrases.size() > kMaxPhrases) { error = "custom phrase limit exceeded"; return false; }
        Statement save(db, "INSERT OR REPLACE INTO main.meta(key,value) VALUES ('setting.custom_phrases',?1),(?2,'1')");
        if (!save.ok()) return false;
        save.bind(1, phraseListJson(phrases)); save.bind(2, marker);
        return save.step() == SQLITE_DONE && run("COMMIT");
    };
    sqlite3_busy_timeout(db, 3000);
    bool ok = rc == SQLITE_OK && merge();
    if (!ok && error.empty()) error = sqlite3_errmsg(db);
    sqlite3_close(db); // rolls back on any failure
    return ok;
}

std::string Store::census() {
    std::string out;
    for (size_t t = 0; t < specs().size(); ++t) {
        if (!present_[t]) continue;
        Statement st(db_, "SELECT COUNT(*) FROM " + std::string(specs()[t].table));
        if (st.ok() && st.step() == SQLITE_ROW)
            out += (out.empty() ? "" : " ") + std::string(specs()[t].code) + "=" + std::to_string(st.integer(0));
    }
    return out;
}

}  // namespace cassotis_sync
