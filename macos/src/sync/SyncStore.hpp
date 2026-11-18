// The local half of iCloud sync: what changed in the user dictionary since the last
// sync, and how other devices' changes merge into it. Plain C++ on sqlite3, shared by
// the macOS input method and the iOS keyboard; CloudSync.mm moves the batches.
//
// Each device (replica) keeps, in sync_* tables of user_dict.db, a shadow of every
// learning table as of its last sync. Rows that differ from the shadow are this
// replica's own changes; they leave as one batch: counters as signed deltas, the rest
// as the latest value, deletions as tombstones. Batches of other replicas are applied
// once each (replica, seq), to the live tables and the shadow alike, so nothing is
// counted twice and nothing received is sent back. The engine never reads sync_*.
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

struct sqlite3;
struct sqlite3_stmt;

namespace cassotis_sync {

/// One batch of this replica's changes. It stays after the upload, for a rebase.
struct OutboxBatch {
    int64_t seq = 0;
    int64_t created = 0;
    std::string payload;
    bool uploaded = false;
    std::string origin; // populated for pending batches inherited from a restored backup
};

struct CollectResult {
    int64_t seq = 0;      // the last new batch (a big one is split), 0 when nothing changed
    size_t ops = 0;
    size_t bytes = 0;     // compressed
    bool cleared = false; // a local "clear learning" was taken in
};

struct ApplyResult {
    size_t batches = 0;
    size_t ops = 0;
    size_t skipped = 0;            // older than a deletion or the local clear
    bool learningChanged = false;  // the engine has to drop its caches
    bool phrasesChanged = false;   // the merged list was committed for the engine
    std::map<std::string, int64_t> waiting;  // replica -> first missing seq
};

/// What another replica says about itself (its Replica record), for cleaning up.
struct ReplicaInfo {
    std::string replica, platform, label;
    int64_t lastSeq = 0, minSeq = 0, lastSync = 0;
    std::map<std::string, int64_t> applied;
};

/// A snapshot in the cloud: replica, generation, parts, and the batches it holds.
struct SnapshotInfo {
    std::string replica;
    int64_t generation = 0, parts = 0, created = 0;
    std::map<std::string, int64_t> applied;
};

/// Custom phrases merged from all replicas, for the engine to take.
struct PendingPhrases {
    std::string base;    // the engine's list (JSON) the merge started from
    std::string merged;  // the list (JSON) to set when the engine still has base
};

class Store {
public:
    explicit Store(std::string path);
    ~Store();
    Store(const Store &) = delete;
    Store &operator=(const Store &) = delete;

    /// Opens user_dict.db (never creates it: the engine does) and the sync tables.
    bool open(std::string &error, bool create = false);
    void close();
    bool isOpen() const { return db_ != nullptr; }

    /// This replica's id: random, created on first use.
    std::string replica();
    /// deviceToken identifies the device (a hash of it is kept). A file that moved to
    /// another device (a restored backup) continues under a new replica id.
    bool adoptDevice(const std::string &deviceToken);
    /// Bind on first use. A different account may never receive this dictionary.
    bool adoptAccount(const std::string &accountName);

    /// Hand immutable batches to/from the iOS host's App Group database. The
    /// keyboard remains the only owner of the live dictionary and merge state.
    bool exchangeWithRelay(const std::string &path, std::string &error);

    std::string value(const std::string &key);
    bool setValue(const std::string &key, const std::string &value);
    int64_t number(const std::string &key, int64_t fallback = 0);
    void setNumber(const std::string &key, int64_t value);

    /// This replica's changes since the last call become an outbox batch.
    bool collect(int64_t now, CollectResult &result, std::string &error);
    std::vector<OutboxBatch> outbox(bool pendingOnly);
    void markUploaded(int64_t seq);
    std::vector<OutboxBatch> forwarded();
    void markForwarded(const std::string &origin, int64_t seq);
    /// Forgets own batches up to seq (deleted from the cloud).
    void dropOutbox(int64_t throughSeq);

    /// Another replica's batch, kept until its predecessors have been applied.
    bool receive(const std::string &replica, int64_t seq, int64_t created,
        const std::string &payload);
    /// Applies received batches in order, one transaction each. Local phrase edits
    /// are taken in first (now: their time), for the next collect() to send.
    bool applyReceived(int64_t now, ApplyResult &result, std::string &error);
    /// replica -> highest seq applied, others only.
    std::map<std::string, int64_t> applied();
    int64_t lastOwnSeq();
    int64_t firstOwnSeq();

    /// The synced state (the shadow) with the batches it contains: a new or long
    /// absent replica starts from it. Only meaningful with every batch uploaded.
    bool exportSnapshot(int64_t now, std::string &payload, std::string &error);
    /// Replaces the synced state with a snapshot, keeping this replica's batches the
    /// snapshot does not contain, including concurrent local edits.
    bool importSnapshot(const std::string &payload, ApplyResult &result, std::string &error);

    std::optional<PendingPhrases> pendingPhrases();
    /// The engine now has this list (JSON, the pending merge); it is the base of the
    /// next diff. False when a newer merge is pending: that one is still to apply.
    bool confirmPhrases(const std::string &json);

    /// Set before asking the engine to clear learning, reset if that failed: the next
    /// collect() takes the empty tables as a local clear, not as deletions to send.
    void setClearPending(bool pending);

    /// Rows per synced table, for reports: "user=68 stats=1264 ...".
    std::string census();

    // What the cloud holds besides batches, mirrored for cleaning up and rebasing.
    bool noteReplica(const ReplicaInfo &info);
    bool noteSnapshot(const SnapshotInfo &info);
    bool forgetReplica(const std::string &replica);
    bool forgetSnapshot(const std::string &replica);
    std::vector<ReplicaInfo> replicas();
    std::vector<SnapshotInfo> snapshots();
    /// Own batches that every replica seen within maxAgeSeconds has applied and every
    /// snapshot holds, created before olderThan: they can go from the cloud.
    int64_t ownSeqSafeToDelete(int64_t now, int64_t liveWindow, int64_t olderThan);
    /// Every own batch is to be uploaded again (the zone was recreated).
    void markAllUnuploaded();

    /// One change in a payload, and the description of a synced table (SyncStore.cpp).
    struct Op;
    struct Spec;

private:
    bool exec(const char *sql);
    bool tableExists(const char *name);
    void refreshTables();
    bool ensureSchema(std::string &error);
    bool observeLocalClear(int64_t now);
    bool collectChanges(int64_t now, CollectResult &result);
    bool diffTable(const Spec &spec, int64_t now, std::vector<Op> &ops);
    bool diffPhrases(int64_t now, std::vector<Op> &ops);
    bool stagePhrases(int64_t now);
    bool applyOp(const Op &op, int64_t clearedAt, ApplyResult &result, bool shadowOnlyRows);
    bool applyRowUpsert(const Spec &spec, const Op &op, bool live);
    bool applyRowDelete(const Spec &spec, const Op &op);
    bool recomputePhrases(ApplyResult &result);
    bool applyPayload(const std::string &payload, ApplyResult &result, std::string &error);

    sqlite3_stmt *cached(const std::string &sql);

    std::string path_;
    sqlite3 *db_ = nullptr;
    std::map<std::string, sqlite3_stmt *> cache_;
    std::vector<bool> present_;  // which live tables exist in this file
};

// Import a self-contained legacy dictionary on the same device. Repeated imports
// of an already adopted source preserve new edits, including subsequent deletions.
bool importLegacyDictionary(const std::string &source, const std::string &destination,
    const std::string &sourceID, std::string &error);
bool backupDictionary(const std::string &source, const std::string &destination, std::string &error);

// The payload codec, exposed for tests.
std::string compressText(const std::string &text);
bool decompressText(const std::string &data, std::string &text);

// "replica:seq,replica:seq" (the applied vector in records).
std::string formatApplied(const std::map<std::string, int64_t> &applied);
std::map<std::string, int64_t> parseApplied(const std::string &text);

// The engine's custom phrase list as JSON, [["shortcut","text"], ...].
using PhraseList = std::vector<std::pair<std::string, std::string>>;
bool parsePhraseList(const std::string &json, PhraseList &out);
std::string phraseListJson(const PhraseList &list);

}  // namespace cassotis_sync
