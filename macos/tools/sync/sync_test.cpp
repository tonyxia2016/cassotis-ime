// Tests of the iCloud sync merge (src/sync/SyncStore.cpp) without iCloud: replicas are
// user dictionaries in a temporary directory and batches go from one to another
// directly. Build and run with tools/sync/run_sync_test.sh.
#include "SyncStore.hpp"

#include <sqlite3.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <map>
#include <string>
#include <vector>

using namespace cassotis_sync;

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { ++failures; fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #cond); } } while (0)

// The engine's user tables (macos/src/engine/nc_dictionary_sqlite.pas) and meta.
static const char *kSchema =
    "PRAGMA journal_mode=WAL;"
    "CREATE TABLE dict_user_bigram(left_text TEXT,text TEXT,commit_count INTEGER,last_used INTEGER,PRIMARY KEY(left_text,text));"
    "CREATE TABLE dict_user_trigram(prev_prev_text TEXT,prev_text TEXT,text TEXT,commit_count INTEGER,last_used INTEGER,"
    " PRIMARY KEY(prev_prev_text,prev_text,text));"
    "CREATE TABLE dict_user_query_path(query_pinyin TEXT,path_text TEXT,commit_count INTEGER,last_used INTEGER,"
    " PRIMARY KEY(query_pinyin,path_text));"
    "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
    "CREATE TABLE dict_user (id INTEGER PRIMARY KEY AUTOINCREMENT, pinyin TEXT NOT NULL, text TEXT NOT NULL, "
    "  weight INTEGER DEFAULT 0, last_used INTEGER DEFAULT 0, UNIQUE(pinyin, text));"
    "CREATE TABLE dict_user_literal (pinyin TEXT NOT NULL, jianpin TEXT NOT NULL, text TEXT NOT NULL, "
    "  created_at INTEGER DEFAULT 0, PRIMARY KEY(pinyin, text));"
    "CREATE TABLE dict_user_stats (pinyin TEXT NOT NULL, text TEXT NOT NULL, commit_count INTEGER DEFAULT 0, "
    "  last_used INTEGER DEFAULT 0, PRIMARY KEY(pinyin, text));"
    "CREATE TABLE dict_user_fuzzy_choice (pinyin TEXT NOT NULL, text TEXT NOT NULL, commit_count INTEGER DEFAULT 0, "
    "  last_used INTEGER DEFAULT 0, PRIMARY KEY(pinyin, text));"
    "CREATE TABLE dict_user_query_latest (query_pinyin TEXT NOT NULL PRIMARY KEY, text TEXT NOT NULL, "
    "  last_used INTEGER DEFAULT 0);"
    "CREATE TABLE dict_user_context_query_choice (context_suffix TEXT NOT NULL, query_pinyin TEXT NOT NULL, "
    "  text TEXT NOT NULL, commit_count INTEGER DEFAULT 0, last_used INTEGER DEFAULT 0, "
    "  PRIMARY KEY(context_suffix, query_pinyin, text));"
    "CREATE TABLE dict_user_completion_feedback (typed_prefix TEXT NOT NULL, full_pinyin TEXT NOT NULL, "
    "  text TEXT NOT NULL, accept_count INTEGER DEFAULT 0, reject_count INTEGER DEFAULT 0, last_used INTEGER DEFAULT 0, "
    "  PRIMARY KEY(typed_prefix, full_pinyin, text)) WITHOUT ROWID;"
    "CREATE TABLE dict_user_long_completion_feedback (anchor_path TEXT NOT NULL, suffix_text TEXT NOT NULL, "
    "  accept_count INTEGER DEFAULT 0, reject_count INTEGER DEFAULT 0, last_used INTEGER DEFAULT 0, "
    "  PRIMARY KEY(anchor_path, suffix_text)) WITHOUT ROWID;"
    "CREATE TABLE dict_user_penalty (pinyin TEXT NOT NULL, text TEXT NOT NULL, penalty INTEGER DEFAULT 0, "
    "  last_used INTEGER DEFAULT 0, PRIMARY KEY(pinyin, text));"
    "CREATE TABLE dict_user_query_path_penalty (query_pinyin TEXT NOT NULL, path_text TEXT NOT NULL, "
    "  penalty INTEGER DEFAULT 0, last_used INTEGER DEFAULT 0, PRIMARY KEY(query_pinyin, path_text));";

static std::string dir;

struct Replica {
    std::string name, path;
    sqlite3 *db = nullptr;     // what the engine would do
    Store *store = nullptr;
    Replica(const std::string &n) : name(n), path(dir + "/" + n + ".db") {
        remove(path.c_str());
        sqlite3_open(path.c_str(), &db);
        sqlite3_exec(db, kSchema, nullptr, nullptr, nullptr);
        store = new Store(path);
        std::string error;
        if (!store->open(error)) { fprintf(stderr, "open %s: %s\n", n.c_str(), error.c_str()); exit(2); }
        store->adoptDevice("device-" + n);
        store->adoptAccount("account");
    }
    ~Replica() { delete store; sqlite3_close(db); }
    void sql(const std::string &text) {
        char *error = nullptr;
        if (sqlite3_exec(db, text.c_str(), nullptr, nullptr, &error) != SQLITE_OK) {
            fprintf(stderr, "%s: %s\n  in %s\n", name.c_str(), error, text.c_str());
            sqlite3_free(error);
            ++failures;
        }
    }
    int64_t integer(const std::string &query) {
        sqlite3_stmt *st = nullptr;
        int64_t value = -1;
        if (sqlite3_prepare_v2(db, query.c_str(), -1, &st, nullptr) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW)
            value = sqlite3_column_type(st, 0) == SQLITE_NULL ? -1 : sqlite3_column_int64(st, 0);
        sqlite3_finalize(st);
        return value;
    }
    std::string text(const std::string &query) {
        sqlite3_stmt *st = nullptr;
        std::string value = "<none>";
        if (sqlite3_prepare_v2(db, query.c_str(), -1, &st, nullptr) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW)
            value = reinterpret_cast<const char *>(sqlite3_column_text(st, 0));
        sqlite3_finalize(st);
        return value;
    }
    // Learning as the engine records it.
    void commit(const std::string &pinyin, const std::string &word, int64_t ts, int times = 1) {
        for (int i = 0; i < times; ++i)
            sql("INSERT INTO dict_user_stats(pinyin, text, commit_count, last_used) VALUES ('" + pinyin + "', '" + word +
                "', 1, " + std::to_string(ts) + ") ON CONFLICT(pinyin, text) DO UPDATE SET commit_count = commit_count + 1, "
                "last_used = excluded.last_used;");
    }
    int64_t count(const std::string &pinyin, const std::string &word) {
        return integer("SELECT commit_count FROM dict_user_stats WHERE pinyin = '" + pinyin + "' AND text = '" + word + "'");
    }
    void phrases(const std::string &json) {
        sql("INSERT INTO meta(key, value) VALUES ('setting.custom_phrases', '" + json +
            "') ON CONFLICT(key) DO UPDATE SET value = excluded.value;");
    }
    std::string phrases() { return text("SELECT value FROM meta WHERE key = 'setting.custom_phrases'"); }
    /// What the keyboard or input method does with a merged phrase list.
    void takePhrases() {
        auto pending = store->pendingPhrases();
        if (!pending) return;
        phrases(pending->merged);
        store->confirmPhrases(pending->merged);
    }
};

/// The cloud: every uploaded batch, by replica.
struct Cloud {
    std::map<std::string, std::map<int64_t, std::string>> batches;
    void upload(Replica &r) {
        for (const auto &batch : r.store->outbox(true)) {
            batches[r.store->replica()][batch.seq] = batch.payload;
            r.store->markUploaded(batch.seq);
        }
    }
    ApplyResult download(Replica &r, int64_t now = 0) {
        for (const auto &entry : batches) {
            if (entry.first == r.store->replica()) continue;
            for (const auto &batch : entry.second) r.store->receive(entry.first, batch.first, 0, batch.second);
        }
        ApplyResult result;
        std::string error;
        if (!r.store->applyReceived(now, result, error)) { fprintf(stderr, "apply %s: %s\n", r.name.c_str(), error.c_str()); ++failures; }
        r.takePhrases();
        return result;
    }
    /// One sync as CloudSync.mm runs it: others' changes in, then local ones out.
    CollectResult sync(Replica &r, int64_t now) {
        download(r, now);
        CollectResult collected;
        std::string error;
        if (!r.store->collect(now, collected, error)) { fprintf(stderr, "collect %s: %s\n", r.name.c_str(), error.c_str()); ++failures; }
        upload(r);
        return collected;
    }
};

static void testCountsAndDoubleCounting() {
    Replica a("a"), b("b");
    Cloud cloud;
    a.commit("nihao", "你好", 1000, 3);
    b.commit("nihao", "你好", 1001, 2);
    b.commit("shijie", "世界", 1002);
    cloud.sync(a, 2000);
    cloud.sync(b, 2001);
    cloud.sync(a, 2002);
    CHECK(a.count("nihao", "你好") == 5);
    CHECK(b.count("nihao", "你好") == 5);
    CHECK(a.count("shijie", "世界") == 1);
    // Nothing new: no batch, and the counts stay.
    CHECK(cloud.sync(a, 2003).seq == 0);
    CHECK(cloud.sync(b, 2004).seq == 0);
    CHECK(a.count("nihao", "你好") == 5 && b.count("nihao", "你好") == 5);
    // Received batches again: applied once.
    for (const auto &entry : cloud.batches)
        for (const auto &batch : entry.second) {
            a.store->receive(entry.first, batch.first, 0, batch.second);
            b.store->receive(entry.first, batch.first, 0, batch.second);
        }
    cloud.download(a);
    cloud.download(b);
    CHECK(a.count("nihao", "你好") == 5 && b.count("nihao", "你好") == 5);
    // More use on both sides between syncs.
    a.commit("nihao", "你好", 3000);
    b.commit("nihao", "你好", 3001, 4);
    cloud.sync(a, 4000);
    cloud.sync(b, 4001);
    cloud.sync(a, 4002);
    CHECK(a.count("nihao", "你好") == 10);
    CHECK(b.count("nihao", "你好") == 10);
    CHECK(a.integer("SELECT last_used FROM dict_user_stats WHERE text = '你好'") == 3001);
}

static void testOrderAndGaps() {
    Replica a("oa"), b("ob");
    Cloud cloud;
    a.commit("yi", "一", 100);
    cloud.sync(a, 200);
    a.commit("er", "二", 300);
    cloud.sync(a, 400);
    // Batch 2 arrives first: it waits for batch 1.
    const std::string id = a.store->replica();
    b.store->receive(id, 2, 0, cloud.batches[id][2]);
    ApplyResult r;
    std::string error;
    b.store->applyReceived(500, r, error);
    CHECK(r.batches == 0 && r.waiting.count(id) && r.waiting[id] == 1);
    CHECK(b.count("er", "二") == -1);
    b.store->receive(id, 1, 0, cloud.batches[id][1]);
    ApplyResult r2;
    b.store->applyReceived(500, r2, error);
    CHECK(r2.batches == 2 && r2.waiting.empty());
    CHECK(b.count("yi", "一") == 1 && b.count("er", "二") == 1);
}

static void testDeletion() {
    Replica a("da"), b("db");
    Cloud cloud;
    a.commit("cuo", "错词", 100, 3);
    a.sql("INSERT INTO dict_user(pinyin, text, weight, last_used) VALUES ('cuoci', '错词', 3, 100);");
    cloud.sync(a, 200);
    cloud.sync(b, 210);
    CHECK(b.count("cuo", "错词") == 3);
    CHECK(b.integer("SELECT weight FROM dict_user WHERE text = '错词'") == 3);
    // Removed on a: gone on b at its next sync.
    a.sql("DELETE FROM dict_user_stats WHERE text = '错词'; DELETE FROM dict_user WHERE text = '错词';");
    cloud.sync(a, 300);
    cloud.sync(b, 310);
    CHECK(b.count("cuo", "错词") == -1);
    CHECK(b.integer("SELECT COUNT(*) FROM dict_user WHERE text = '错词'") == 0);
    // An increment from before the deletion that arrives later is dropped...
    Replica c("dc");
    c.commit("cuo", "错词", 250);
    cloud.sync(c, 260);   // c had not heard of the deletion yet when it learned
    cloud.sync(a, 320);
    CHECK(a.count("cuo", "错词") == -1);
    // ...but use after the deletion comes back.
    b.commit("cuo", "错词", 500);
    cloud.sync(b, 510);
    cloud.sync(a, 520);
    CHECK(a.count("cuo", "错词") == 1);
    CHECK(b.count("cuo", "错词") == 1);
}

static void testDeletionMeetsLaterUse() {
    Replica a("ea"), b("eb");
    Cloud cloud;
    a.commit("ci", "词", 100, 4);
    cloud.sync(a, 150);
    cloud.sync(b, 160);
    CHECK(b.count("ci", "词") == 4);
    // a deletes at 300 (its sync); b uses the word twice at 400, before hearing of it.
    a.sql("DELETE FROM dict_user_stats WHERE text = '词';");
    cloud.sync(a, 300);
    b.commit("ci", "词", 400, 2);
    cloud.sync(b, 410);    // the deletion is older than b's use: b keeps only its own 2
    CHECK(b.count("ci", "词") == 2);
    cloud.sync(a, 420);
    CHECK(a.count("ci", "词") == 2);
}

static void testLastWins() {
    Replica a("la"), b("lb");
    Cloud cloud;
    a.sql("INSERT INTO dict_user_query_latest VALUES ('nihao', '你好', 100);");
    b.sql("INSERT INTO dict_user_query_latest VALUES ('nihao', '拟好', 200);");
    cloud.sync(a, 300);
    cloud.sync(b, 310);
    cloud.sync(a, 320);
    CHECK(a.text("SELECT text FROM dict_user_query_latest WHERE query_pinyin = 'nihao'") == "拟好");
    CHECK(b.text("SELECT text FROM dict_user_query_latest WHERE query_pinyin = 'nihao'") == "拟好");
    a.sql("UPDATE dict_user_query_latest SET text = '你好', last_used = 400 WHERE query_pinyin = 'nihao';");
    cloud.sync(a, 410);
    cloud.sync(b, 420);
    CHECK(b.text("SELECT text FROM dict_user_query_latest WHERE query_pinyin = 'nihao'") == "你好");
    // Literal words: jianpin and created_at travel with the row.
    a.sql("INSERT INTO dict_user_literal VALUES ('xx', 'xx', '星星', 500);");
    cloud.sync(a, 510);
    cloud.sync(b, 520);
    CHECK(b.text("SELECT jianpin FROM dict_user_literal WHERE text = '星星'") == "xx");
}

static void testCapsAndSignedDeltas() {
    Replica a("ca"), b("cb");
    Cloud cloud;
    a.sql("INSERT INTO dict_user_context_query_choice VALUES ('我们', 'zou', '走', 200, 100);");
    b.sql("INSERT INTO dict_user_context_query_choice VALUES ('我们', 'zou', '走', 100, 101);");
    cloud.sync(a, 200);
    cloud.sync(b, 210);
    CHECK(b.integer("SELECT commit_count FROM dict_user_context_query_choice") == 255);
    // Accepting a completion lowers its reject count: a negative delta.
    a.sql("INSERT INTO dict_user_completion_feedback VALUES ('ni', 'nihao', '你好', 1, 3, 100);");
    cloud.sync(a, 300);
    cloud.sync(b, 310);
    CHECK(b.integer("SELECT reject_count FROM dict_user_completion_feedback") == 3);
    a.sql("UPDATE dict_user_completion_feedback SET accept_count = 2, reject_count = 2, last_used = 400;");
    cloud.sync(a, 410);
    cloud.sync(b, 420);
    CHECK(b.integer("SELECT accept_count FROM dict_user_completion_feedback") == 2);
    CHECK(b.integer("SELECT reject_count FROM dict_user_completion_feedback") == 2);
    // Pruned rows of a size-bounded table stay on the other side.
    a.sql("DELETE FROM dict_user_context_query_choice;");
    cloud.sync(a, 500);
    cloud.sync(b, 510);
    CHECK(b.integer("SELECT COUNT(*) FROM dict_user_context_query_choice") == 1);
}

static void testLocalClear() {
    Replica a("xa"), b("xb");
    Cloud cloud;
    a.commit("ni", "你", 100, 2);
    b.commit("ta", "他", 110, 3);
    cloud.sync(a, 200);
    cloud.sync(b, 210);
    cloud.sync(a, 220);
    CHECK(a.count("ta", "他") == 3 && b.count("ni", "你") == 2);
    // "Clear learning" on a: marked first, then the engine empties the tables.
    a.store->setClearPending(true);
    a.sql("DELETE FROM dict_user_stats;");
    b.commit("ta", "他", 250);   // before the clear: does not come back to a
    CollectResult cleared = cloud.sync(a, 300);
    CHECK(cleared.cleared);
    cloud.sync(b, 310);
    CHECK(b.count("ni", "你") == 2 && b.count("ta", "他") == 4);  // b keeps everything
    cloud.sync(a, 320);
    CHECK(a.count("ta", "他") == -1 && a.count("ni", "你") == -1);
    b.commit("ta", "他", 400);   // after the clear: comes over
    cloud.sync(b, 410);
    cloud.sync(a, 420);
    CHECK(a.count("ta", "他") == 1);
    CHECK(b.count("ta", "他") == 5);
}

static void testPhrases() {
    Replica a("pa"), b("pb");
    Cloud cloud;
    a.phrases("[[\"dz\", \"北京市海淀区\"], [\"yx\", \"me@example.com\"]]");
    b.phrases("[[\"sj\", \"138\"], [\"dz\", \"北京市海淀区\"]]");
    cloud.sync(a, 100);
    cloud.sync(b, 110);   // b edited last: its order first, a's new phrase after
    cloud.sync(a, 120);
    std::string expected = "[[\"sj\", \"138\"], [\"dz\", \"北京市海淀区\"], [\"yx\", \"me@example.com\"]]";
    CHECK(a.phrases() == expected);
    CHECK(b.phrases() == expected);
    // Removal and a reorder on a.
    a.phrases("[[\"yx\", \"me@example.com\"], [\"dz\", \"北京市海淀区\"]]");
    cloud.sync(a, 200);
    cloud.sync(b, 210);
    CHECK(b.phrases() == "[[\"yx\", \"me@example.com\"], [\"dz\", \"北京市海淀区\"]]");
    // Escapes and a tab inside a phrase survive the trip.
    a.phrases("[[\"qm\", \"第一行\\n\\t第二行 \\\"引号\\\"\"]]");
    cloud.sync(a, 300);
    cloud.sync(b, 310);
    CHECK(b.phrases() == "[[\"qm\", \"第一行\\n\\t第二行 \\\"引号\\\"\"]]");
    // An edit on b while the merged list waits: b's edit is not lost.
    a.phrases("[[\"qm\", \"第一行\\n\\t第二行 \\\"引号\\\"\"], [\"zz\", \"新\"]]");
    cloud.sync(a, 400);
    CollectResult collected;
    std::string error;
    b.store->collect(410, collected, error);
    cloud.download(b, 410);   // merged list pending, taken
    CHECK(b.phrases().find("zz") != std::string::npos);
}

static void testSnapshot() {
    Replica a("sa"), b("sb");
    Cloud cloud;
    a.commit("ni", "你", 100, 2);
    a.phrases("[[\"dz\", \"地址\"]]");
    b.commit("ta", "他", 110, 3);
    cloud.sync(a, 200);
    cloud.sync(b, 210);
    cloud.sync(a, 220);
    std::string snapshot, error;
    CHECK(a.store->exportSnapshot(230, snapshot, error));
    // A new replica with its own learning starts from the snapshot.
    Replica c("sc");
    c.commit("wo", "我", 120, 5);
    CollectResult collected;
    CHECK(c.store->collect(240, collected, error) && collected.seq == 1);
    ApplyResult result;
    CHECK(c.store->importSnapshot(snapshot, result, error));
    c.takePhrases();
    CHECK(c.count("ni", "你") == 2 && c.count("ta", "他") == 3 && c.count("wo", "我") == 5);
    CHECK(c.phrases() == "[[\"dz\", \"地址\"]]");
    cloud.upload(c);
    cloud.sync(a, 300);
    CHECK(a.count("wo", "我") == 5 && a.count("ni", "你") == 2);
    // A replica that applied less than the snapshot also rebases exactly.
    b.commit("ta", "他", 400);
    CHECK(b.store->collect(410, collected, error));
    ApplyResult rebased;
    CHECK(b.store->importSnapshot(snapshot, rebased, error));
    CHECK(b.count("ta", "他") == 4 && b.count("ni", "你") == 2);
    cloud.upload(b);
    cloud.sync(a, 420);
    CHECK(a.count("ta", "他") == 4);
}

static void testDeviceAndAccount() {
    Replica a("ia");
    std::string first = a.store->replica();
    CHECK(!a.store->adoptDevice("device-ia"));
    CHECK(a.store->replica() == first);
    CollectResult collected;
    std::string error;
    a.commit("old", "旧", 90, 3);
    CHECK(a.store->collect(95, collected, error));
    CHECK(a.store->adoptDevice("another device"));  // a restored copy with an unsent batch
    CHECK(a.store->replica() != first && a.store->applied()[first] == 1);
    auto inherited = a.store->forwarded();
    CHECK(inherited.size() == 1);
    if (!inherited.empty()) {
        CHECK(inherited[0].origin == first && inherited[0].seq == 1);
        CHECK(a.store->receive(first, 1, 95, inherited[0].payload));
        ApplyResult applied;
        CHECK(a.store->applyReceived(98, applied, error));
        CHECK(a.count("old", "旧") == 3 && applied.batches == 0);
        a.store->markForwarded(first, 1);
        CHECK(a.store->forwarded().empty());
    }
    a.commit("ni", "你", 100);
    CHECK(a.store->collect(200, collected, error) && collected.seq == 1);
    CHECK(!a.store->adoptAccount("other account"));
    CHECK(a.store->adoptAccount("account"));
    a.store->collect(300, collected, error);
    CHECK(collected.seq == 0 && a.store->outbox(true).size() == 1);
}

static void testBackgroundRelay() {
    Replica phone("relay-phone"), mac("relay-mac");
    std::string error, path = dir + "/host.sqlite";
    CollectResult collected;
    phone.commit("a", "甲", 10, 2);
    CHECK(phone.store->collect(100, collected, error));
    CHECK(phone.store->exchangeWithRelay(path, error));
    Store host(path);
    CHECK(host.open(error));
    CHECK(host.replica() == phone.store->replica() && host.adoptAccount("account"));
    CHECK(!host.adoptAccount("another"));
    const auto outgoing = host.outbox(true);
    CHECK(outgoing.size() == 1);
    for (const auto &batch : outgoing) {
        CHECK(mac.store->receive(host.replica(), batch.seq, 100, batch.payload));
        host.markUploaded(batch.seq);
    }
    mac.commit("b", "乙", 11);
    ApplyResult applied;
    CHECK(mac.store->applyReceived(101, applied, error));
    CHECK(mac.store->collect(101, collected, error));
    for (const auto &batch : mac.store->outbox(true))
        CHECK(host.receive(mac.store->replica(), batch.seq, 101, batch.payload));
    for (int repeat = 0; repeat < 2; ++repeat) {
        CHECK(phone.store->exchangeWithRelay(path, error));
        CHECK(phone.store->applyReceived(102, applied, error));
        CHECK(phone.store->collect(102, collected, error) && collected.seq == 0);
    }
    CHECK(phone.store->outbox(true).empty());
    CHECK(mac.count("a", "甲") == 2 && phone.count("a", "甲") == 2 && phone.count("b", "乙") == 1);
}

static void testLegacyMigration() {
    Replica old("legacy"), current("updated");
    old.commit("old", "旧", 10, 3);
    old.commit("both", "共", 12, 5);
    old.phrases(R"([["jj","旧短语"]])");
    current.commit("both", "共", 20, 2);
    current.commit("new", "新", 20);
    current.phrases(R"([["xx","新短语"]])");
    std::string error, snapshot = dir + "/sealed.sqlite", empty = dir + "/new-install.sqlite";
    CHECK(backupDictionary(old.path, snapshot, error));  // WAL changes included
    CHECK(importLegacyDictionary(snapshot, empty, "legacy.keyboard", error));
    Store installed(empty);
    CHECK(installed.open(error));
    CHECK(importLegacyDictionary(snapshot, current.path, "legacy.keyboard", error));
    CHECK(current.count("old", "旧") == 3 && current.count("new", "新") == 1 && current.count("both", "共") == 5);
    PhraseList phrases;
    CHECK(parsePhraseList(current.phrases(), phrases) && phrases.size() == 2 && phrases.front().first == "xx");
    current.sql("DELETE FROM dict_user_stats WHERE pinyin='old'");
    CHECK(importLegacyDictionary(snapshot, current.path, "legacy.keyboard", error));
    CHECK(current.count("old", "旧") == -1 && current.count("both", "共") == 5);
}

static void testConcurrentChoicesAndLocalDeletion() {
    Replica a("tie-a"), b("tie-b");
    Cloud cloud;
    a.sql("INSERT INTO dict_user_query_latest VALUES ('x','甲',100);"
          "INSERT INTO dict_user_bigram VALUES ('a','b',3,100);"
          "INSERT INTO dict_user_trigram VALUES ('a','b','c',2,100);"
          "INSERT INTO dict_user_query_path VALUES ('abc','a|b|c',7,100);");
    b.sql("INSERT INTO dict_user_query_latest VALUES ('x','乙',100)");
    a.commit("x", "词", 100);
    cloud.sync(a, 120);
    cloud.sync(b, 120);
    cloud.sync(a, 121);
    CHECK(a.text("SELECT text FROM dict_user_query_latest") == b.text("SELECT text FROM dict_user_query_latest"));
    CHECK(b.integer("SELECT commit_count FROM dict_user_bigram") == 3);
    CHECK(b.integer("SELECT commit_count FROM dict_user_trigram") == 2);
    CHECK(b.integer("SELECT commit_count FROM dict_user_query_path") == 7);
    a.sql("DELETE FROM dict_user_stats");
    b.commit("x", "词", 130);
    cloud.sync(b, 140);
    cloud.sync(a, 150);
    cloud.sync(b, 160);
    CHECK(a.count("x", "词") == -1 && b.count("x", "词") == -1);
}

static void testSnapshotDuringTyping() {
    Replica a("typing-a"), b("typing-b");
    Cloud cloud;
    a.commit("a", "甲", 10, 2);
    cloud.sync(a, 20);
    std::string snapshot, error;
    CHECK(a.store->exportSnapshot(30, snapshot, error));
    CollectResult collected;
    CHECK(b.store->collect(40, collected, error));
    b.commit("b", "乙", 50, 3);  // after collection, while the snapshot is being fetched
    ApplyResult applied;
    CHECK(b.store->importSnapshot(snapshot, applied, error));
    CHECK(b.count("b", "乙") == 3 && b.count("a", "甲") == 2);
}

static void testVolume() {
    Replica a("va"), b("vb");
    Cloud cloud;
    a.sql("BEGIN;");
    for (int i = 0; i < 20000; ++i)
        a.sql("INSERT INTO dict_user_stats VALUES ('py" + std::to_string(i) + "', '词" + std::to_string(i) + "', " +
            std::to_string(1 + i % 7) + ", " + std::to_string(1000 + i) + ");");
    a.sql("COMMIT;");
    auto t0 = std::chrono::steady_clock::now();
    CollectResult collected = cloud.sync(a, 50000);
    auto t1 = std::chrono::steady_clock::now();
    ApplyResult applied = cloud.download(b);
    auto t2 = std::chrono::steady_clock::now();
    CHECK(collected.ops == 20000 && applied.ops == 20000);
    CHECK(b.integer("SELECT SUM(commit_count) FROM dict_user_stats") == a.integer("SELECT SUM(commit_count) FROM dict_user_stats"));
    a.commit("py5", "词5", 60000);
    auto t3 = std::chrono::steady_clock::now();
    CollectResult small = cloud.sync(a, 60001);
    auto t4 = std::chrono::steady_clock::now();
    printf("volume: 20000 rows collect %.0f ms (%zu bytes), apply %.0f ms; 1 change collect %.0f ms (%zu bytes)\n",
        std::chrono::duration<double, std::milli>(t1 - t0).count(), collected.bytes,
        std::chrono::duration<double, std::milli>(t2 - t1).count(),
        std::chrono::duration<double, std::milli>(t4 - t3).count(), small.bytes);
}

/// A copy of a real user dictionary: the first sync's cost, and an empty replica
/// that takes the batch ends up with the same learning rows.
static void testRealCopy(const std::string &source) {
    auto copy = [&](const std::string &target) {
        sqlite3 *from = nullptr, *to = nullptr;
        sqlite3_open_v2(source.c_str(), &from, SQLITE_OPEN_READONLY, nullptr);
        remove(target.c_str());
        sqlite3_open(target.c_str(), &to);
        sqlite3_backup *backup = sqlite3_backup_init(to, "main", from, "main");
        if (backup) { sqlite3_backup_step(backup, -1); sqlite3_backup_finish(backup); }
        sqlite3_close(to);
        sqlite3_close(from);
    };
    const std::string a = dir + "/real-a.db", b = dir + "/real-b.db";
    copy(a);
    copy(b);
    const char *tables[] = {"dict_user", "dict_user_stats", "dict_user_query_latest", "dict_user_penalty",
        "dict_user_literal", "dict_user_fuzzy_choice", "dict_user_context_query_choice",
        "dict_user_completion_feedback", "dict_user_long_completion_feedback", "dict_user_query_path_penalty",
        "dict_user_bigram", "dict_user_trigram", "dict_user_query_path"};
    {
        sqlite3 *db = nullptr;
        sqlite3_open(b.c_str(), &db);
        for (const char *table : tables) sqlite3_exec(db, (std::string("DELETE FROM ") + table).c_str(), nullptr, nullptr, nullptr);
        sqlite3_close(db);
    }
    Store sa(a), sb(b);
    std::string error;
    CHECK(sa.open(error) && sb.open(error));
    sa.adoptDevice("real-a"); sb.adoptDevice("real-b");
    auto t0 = std::chrono::steady_clock::now();
    CollectResult collected;
    CHECK(sa.collect(1900000000, collected, error));
    auto t1 = std::chrono::steady_clock::now();
    for (const auto &batch : sa.outbox(true)) sb.receive(sa.replica(), batch.seq, 0, batch.payload);
    ApplyResult applied;
    CHECK(sb.applyReceived(1900000001, applied, error));
    auto t2 = std::chrono::steady_clock::now();
    CollectResult again;
    CHECK(sa.collect(1900000002, again, error) && again.seq == 0);
    auto t3 = std::chrono::steady_clock::now();
    printf("real copy: %s\n  first collect %.0f ms, %zu ops, %zu bytes; apply %.0f ms; no-change collect %.0f ms\n",
        sa.census().c_str(), std::chrono::duration<double, std::milli>(t1 - t0).count(), collected.ops, collected.bytes,
        std::chrono::duration<double, std::milli>(t2 - t1).count(), std::chrono::duration<double, std::milli>(t3 - t2).count());
    sqlite3 *db = nullptr;
    sqlite3_open(a.c_str(), &db);
    sqlite3_exec(db, ("ATTACH '" + b + "' AS other").c_str(), nullptr, nullptr, nullptr);
    for (const char *table : tables) {
        std::string t = table;
        std::string columns = t == "dict_user" ? "pinyin, text, weight, last_used" : "*";
        std::string query = "SELECT COUNT(*) FROM (SELECT " + columns + " FROM main." + t + " EXCEPT SELECT " + columns +
            " FROM other." + t + ") ";
        sqlite3_stmt *st = nullptr;
        int64_t differ = -1, differBack = -1;
        if (sqlite3_prepare_v2(db, query.c_str(), -1, &st, nullptr) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW)
            differ = sqlite3_column_int64(st, 0);
        sqlite3_finalize(st);
        query = "SELECT COUNT(*) FROM (SELECT " + columns + " FROM other." + t + " EXCEPT SELECT " + columns + " FROM main." + t + ")";
        if (sqlite3_prepare_v2(db, query.c_str(), -1, &st, nullptr) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW)
            differBack = sqlite3_column_int64(st, 0);
        sqlite3_finalize(st);
        if (differ != 0 || differBack != 0) printf("  %s differs: %lld / %lld rows\n", table, (long long)differ, (long long)differBack);
        CHECK(differ == 0 && differBack == 0);
    }
    sqlite3_close(db);
}

int main(int argc, char **argv) {
    dir = argc > 1 ? argv[1] : "/tmp";
    if (argc > 2) {
        testRealCopy(argv[2]);
        printf(failures ? "%d failure(s)\n" : "all passed\n", failures);
        return failures ? 1 : 0;
    }
    struct { const char *name; std::function<void()> run; } tests[] = {
        {"counts", testCountsAndDoubleCounting}, {"order", testOrderAndGaps}, {"deletion", testDeletion},
        {"deletion-later-use", testDeletionMeetsLaterUse}, {"last-wins", testLastWins},
        {"caps", testCapsAndSignedDeltas}, {"local-clear", testLocalClear}, {"phrases", testPhrases},
        {"snapshot", testSnapshot}, {"device-account", testDeviceAndAccount}, {"volume", testVolume},
        {"background-relay", testBackgroundRelay}, {"legacy-migration", testLegacyMigration},
        {"concurrent-choice", testConcurrentChoicesAndLocalDeletion}, {"snapshot-typing", testSnapshotDuringTyping},
    };
    for (auto &test : tests) {
        int before = failures;
        test.run();
        printf("%-20s %s\n", test.name, failures == before ? "ok" : "FAILED");
    }
    printf(failures ? "%d failure(s)\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
