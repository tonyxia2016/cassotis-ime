// Replays typed pinyin through the engine and records what phase 0 asks for:
// phys_footprint, os_proc_available_memory, per-key latency, first-candidate
// hits, and a digest of the candidates so cache changes can be proven harmless.
// The same code runs in the macOS CLI and inside the iOS keyboard extension.
#pragma once
#include "EngineClient.hpp"
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace cassotis {
struct MemorySnapshot {
    uint64_t footprint = 0;      // task_vm_info.phys_footprint
    uint64_t footprintPeak = 0;  // task_vm_info.ledger_phys_footprint_peak
    uint64_t available = 0;      // os_proc_available_memory(), 0 off iOS
};
MemorySnapshot memorySnapshot();

struct Sentence { std::string target, keys; };
std::vector<Sentence> loadCorpus(const std::string &path);

struct ReplayOptions {
    uint32_t maxKeys = 10000;
    uint32_t sampleEvery = 500;   // keys between memory samples
    uint32_t paceMicros = 0;      // sleep between keys; 0 replays flat out
    uint64_t maxSeconds = 0;      // stop after this long; 0 is no limit
    bool useContext = false;      // feed the previous sentence as left context
    bool loop = false;            // restart the corpus when it runs out
    uint32_t trimEvery = 0;       // simulate a memory warning every so many keys
    std::string digestPath;       // one line per sentence
    std::string censusPath;       // entries per cache, at every memory sample
    // Called after each key on the replay thread, with the UI work of a real
    // keyboard. Its time is reported apart from the engine's (ui_* in the JSON).
    std::function<void(const Result &)> onKey;
};
struct ReplaySample { uint32_t keys; double seconds; MemorySnapshot memory; };
struct ReplayResult {
    uint32_t keys = 0, sentences = 0, firstHits = 0, deferred = 0;
    double seconds = 0, p50 = 0, p95 = 0, p99 = 0, worst = 0, mean = 0;
    double uiP50 = 0, uiP95 = 0, uiP99 = 0, uiWorst = 0;  // engine plus onKey
    uint64_t digest = 0;
    MemorySnapshot start, end;
    uint64_t minAvailable = 0;
    std::vector<ReplaySample> samples;
    std::string error;
};
using ReplayProgress = std::function<bool(const ReplaySample &)>;  // false stops
ReplayResult replay(EngineClient &client, const std::vector<Sentence> &corpus,
                    const ReplayOptions &options, const ReplayProgress &progress = {});
std::string toJSON(const ReplayResult &result, const std::string &label,
                   const MemorySnapshot &beforeOpen, const MemorySnapshot &afterOpen,
                   double openSeconds);
}
