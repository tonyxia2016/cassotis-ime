#include "replay.hpp"
#include "cassotis_core.h"
#include <TargetConditionals.h>
#include <algorithm>
#include <chrono>
#include <cinttypes>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <fstream>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <memory>
#include <sstream>
#include <thread>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif

namespace cassotis {
MemorySnapshot memorySnapshot() {
    MemorySnapshot s;
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS) {
        s.footprint = info.phys_footprint;
        s.footprintPeak = info.ledger_phys_footprint_peak;
    }
#if TARGET_OS_IPHONE
    s.available = os_proc_available_memory();
#endif
    return s;
}

std::vector<Sentence> loadCorpus(const std::string &path) {
    std::vector<Sentence> rows;
    std::ifstream in(path);
    std::string line;
    while (std::getline(in, line)) {
        auto tab = line.find('\t');
        if (tab != std::string::npos) rows.push_back({line.substr(0, tab), line.substr(tab + 1)});
    }
    return rows;
}

static uint64_t fnv(uint64_t h, const std::string &text) {
    for (unsigned char c : text) { h ^= c; h *= 1099511628211ull; }
    h ^= 0xff; h *= 1099511628211ull;
    return h;
}
static uint64_t absorb(uint64_t h, const Result &r) {
    h = fnv(h, r.preedit);
    h = fnv(h, r.commit);
    h = fnv(h, r.completion);
    for (const auto &c : r.candidates) { h = fnv(h, c.text); h = fnv(h, c.comment); }
    return h;
}
static double quantile(const std::vector<float> &sorted, double q) {
    if (sorted.empty()) return 0;
    return sorted[size_t(q * double(sorted.size() - 1))];
}

// Calls cassotis_core_interrupt at a deadline unless disarmed first: the user
// pressing the next key while a poll still runs.
class Interrupter {
public:
    Interrupter() : thread_([this] { run(); }) {}
    ~Interrupter() {
        { std::lock_guard<std::mutex> lock(mutex_); quit_ = true; }
        changed_.notify_all();
        thread_.join();
    }
    void arm(std::chrono::steady_clock::time_point deadline) {
        std::lock_guard<std::mutex> lock(mutex_);
        deadline_ = deadline;
        armed_ = true;
        fired_ = false;
        changed_.notify_all();
    }
    // True when it fired.
    bool disarm() {
        std::lock_guard<std::mutex> lock(mutex_);
        armed_ = false;
        changed_.notify_all();
        return fired_;
    }
private:
    void run() {
        std::unique_lock<std::mutex> lock(mutex_);
        while (!quit_) {
            if (!armed_) { changed_.wait(lock); continue; }
            if (changed_.wait_until(lock, deadline_, [this] { return quit_ || !armed_; })) continue;
            cassotis_core_interrupt();
            fired_ = true;
            armed_ = false;
        }
    }
    std::mutex mutex_;
    std::condition_variable changed_;
    bool armed_ = false, fired_ = false, quit_ = false;
    std::chrono::steady_clock::time_point deadline_{};
    std::thread thread_;
};

ReplayResult replay(EngineClient &client, const std::vector<Sentence> &corpus,
                    const ReplayOptions &options, const ReplayProgress &progress) {
    using clock = std::chrono::steady_clock;
    ReplayResult out;
    out.start = memorySnapshot();
    out.minAvailable = out.start.available;
    out.digest = 14695981039346656037ull;
    std::vector<float> latency, uiLatency;
    latency.reserve(options.maxKeys + 64);
    if (options.onKey) uiLatency.reserve(options.maxKeys + 64);
    std::FILE *digests = options.digestPath.empty() ? nullptr : std::fopen(options.digestPath.c_str(), "w");
    const auto began = clock::now();
    auto seconds = [&] { return std::chrono::duration<double>(clock::now() - began).count(); };
    bool stop = corpus.empty();
    uint32_t nextSample = options.sampleEvery;
    uint32_t nextTrim = options.trimEvery ? options.trimEvery : UINT32_MAX;
    std::string previous;
    std::FILE *census = options.censusPath.empty() ? nullptr : std::fopen(options.censusPath.c_str(), "w");
    auto sample = [&] {
        ReplaySample s{out.keys, seconds(), memorySnapshot()};
        out.samples.push_back(s);
        if (census) {
            std::string text(32 * 1024, '\0');
            uint32_t n = cassotis_core_cache_census(text.data(), uint32_t(text.size()));
            text.resize(std::min<size_t>(n, text.size() - 1));
            std::fprintf(census, "# %u\n%s", out.keys, text.c_str());
        }
        if (s.memory.available && s.memory.available < out.minAvailable) out.minAvailable = s.memory.available;
        if (progress && !progress(s)) stop = true;
    };
    std::vector<float> pollLatency;
    std::unique_ptr<Interrupter> interrupter;
    if (options.poll && options.paceMicros) interrupter = std::make_unique<Interrupter>();
    bool pollDue = false;               // the last key returned pending
    auto due = clock::now();            // when the user presses the next key
    const auto pace = std::chrono::microseconds(options.paceMicros);
    // A poll that changes the candidates goes into the sentence's digest h.
    auto pollBefore = [&](bool interrupts, uint64_t &h) {
        if (!pollDue) return;
        pollDue = false;
        if (interrupter && interrupts) interrupter->arm(due);
        auto p0 = clock::now();
        Result p = client.poll();
        pollLatency.push_back(std::chrono::duration<float, std::milli>(clock::now() - p0).count());
        ++out.polls;
        if (interrupter && interrupter->disarm()) { ++out.pollsInterrupted; return; }
        if (!p.handled) return;
        ++out.pollsApplied;
        if (options.onKey) options.onKey(p);
        h = absorb(h, p);
    };
    // interrupts: a key that edits the composition may cut a poll short; one
    // that commits waits for it.
    auto press = [&](const Key &key, bool interrupts, uint64_t &h) {
        if (options.poll) pollBefore(interrupts, h);
        if (options.paceMicros) std::this_thread::sleep_until(due);
        auto t0 = clock::now();
        if (options.poll && options.paceMicros && due < t0) t0 = due;  // pressed while a poll ran
        Result r = client.key(key);
        latency.push_back(std::chrono::duration<float, std::milli>(clock::now() - t0).count());
        if (options.onKey) {
            options.onKey(r);
            uiLatency.push_back(std::chrono::duration<float, std::milli>(clock::now() - t0).count());
        }
        ++out.keys;
        if (r.pending) ++out.deferred;
        pollDue = options.poll && r.pending;
        if (out.keys >= nextSample) { nextSample += options.sampleEvery; sample(); }
        if (options.paceMicros) due = clock::now() + pace;
        return r;
    };
    try {
        client.active(true);
        sample();
        for (size_t i = 0; !stop; ++i) {
            if (i == corpus.size()) { if (!options.loop) break; i = 0; }
            const Sentence &s = corpus[i];
            client.reset();
            if (options.useContext && !previous.empty())
                client.surrounding(previous, int32_t(previous.size()), true);
            uint64_t h = 14695981039346656037ull;
            pollDue = false;
            for (char c : s.keys) {
                Key k; k.text = std::string(1, c);
                Result r = press(k, true, h);
                h = absorb(h, r);
                if (stop) break;
            }
            if (stop) break;
            Key space; space.special = 5;
            Result r = press(space, false, h);
            h = absorb(h, r);
            bool hit = r.commit == s.target;
            out.firstHits += hit;
            ++out.sentences;
            out.digest ^= h; out.digest *= 1099511628211ull;
            if (digests) std::fprintf(digests, "%016" PRIx64 "\t%d\t%s\t%s\n", h, hit ? 1 : 0, s.target.c_str(), r.commit.c_str());
            previous = r.commit;
            if (out.keys >= nextTrim) {
                nextTrim += options.trimEvery;
                cassotis_core_trim(1);
                malloc_zone_pressure_relief(nullptr, 0);
            }
            if (out.keys >= options.maxKeys) break;
            if (options.maxSeconds && seconds() >= double(options.maxSeconds)) break;
        }
        sample();
    } catch (const std::exception &e) {
        out.error = e.what();
    }
    if (digests) std::fclose(digests);
    if (census) std::fclose(census);
    out.seconds = seconds();
    out.end = memorySnapshot();
    if (!latency.empty()) {
        double sum = 0; for (float v : latency) sum += v;
        out.mean = sum / double(latency.size());
        std::sort(latency.begin(), latency.end());
        out.p50 = quantile(latency, 0.50);
        out.p95 = quantile(latency, 0.95);
        out.p99 = quantile(latency, 0.99);
        out.worst = latency.back();
    }
    if (!pollLatency.empty()) {
        std::sort(pollLatency.begin(), pollLatency.end());
        out.pollP50 = quantile(pollLatency, 0.50);
        out.pollP95 = quantile(pollLatency, 0.95);
        out.pollWorst = pollLatency.back();
    }
    if (!uiLatency.empty()) {
        std::sort(uiLatency.begin(), uiLatency.end());
        out.uiP50 = quantile(uiLatency, 0.50);
        out.uiP95 = quantile(uiLatency, 0.95);
        out.uiP99 = quantile(uiLatency, 0.99);
        out.uiWorst = uiLatency.back();
    }
    return out;
}

static double mb(uint64_t v) { return double(v) / (1024.0 * 1024.0); }
static std::string escaped(const std::string &v) {
    std::string o;
    for (char c : v) { if (c == '"' || c == '\\') o.push_back('\\'); if (c == '\n') { o += "\\n"; continue; } o.push_back(c); }
    return o;
}
std::string toJSON(const ReplayResult &r, const std::string &label, const MemorySnapshot &beforeOpen,
                   const MemorySnapshot &afterOpen, double openSeconds) {
    char line[1024];
    std::ostringstream o;
    o << "{\n  \"label\": \"" << escaped(label) << "\",\n";
    std::snprintf(line, sizeof line,
        "  \"before_open_mb\": %.1f, \"after_open_mb\": %.1f, \"open_seconds\": %.3f,\n"
        "  \"keys\": %u, \"sentences\": %u, \"first_hits\": %u, \"first_rate\": %.4f, \"deferred\": %u,\n"
        "  \"seconds\": %.1f, \"p50_ms\": %.2f, \"p95_ms\": %.2f, \"p99_ms\": %.2f, \"worst_ms\": %.1f, \"mean_ms\": %.2f,\n"
        "  \"ui_p50_ms\": %.2f, \"ui_p95_ms\": %.2f, \"ui_p99_ms\": %.2f, \"ui_worst_ms\": %.1f,\n"
        "  \"end_mb\": %.1f, \"peak_mb\": %.1f, \"available_end_mb\": %.1f, \"available_min_mb\": %.1f,\n"
        "  \"model_state\": %d, \"model_seconds\": %.2f,\n"
        "  \"polls\": %u, \"polls_applied\": %u, \"polls_interrupted\": %u, \"poll_p50_ms\": %.2f, \"poll_p95_ms\": %.2f, \"poll_worst_ms\": %.1f,\n"
        "  \"digest\": \"%016" PRIx64 "\",\n",
        mb(beforeOpen.footprint), mb(afterOpen.footprint), openSeconds,
        r.keys, r.sentences, r.firstHits, r.sentences ? double(r.firstHits) / r.sentences : 0.0, r.deferred,
        r.seconds, r.p50, r.p95, r.p99, r.worst, r.mean, r.uiP50, r.uiP95, r.uiP99, r.uiWorst,
        mb(r.end.footprint), mb(r.end.footprintPeak), mb(r.end.available), mb(r.minAvailable),
        r.modelState, r.modelSeconds, r.polls, r.pollsApplied, r.pollsInterrupted, r.pollP50, r.pollP95,
        r.pollWorst, r.digest);
    o << line;
    o << "  \"error\": \"" << escaped(r.error) << "\",\n  \"samples\": [";
    for (size_t i = 0; i < r.samples.size(); ++i) {
        const auto &s = r.samples[i];
        std::snprintf(line, sizeof line, "%s\n    [%u, %.1f, %.1f, %.1f, %.1f]", i ? "," : "",
                      s.keys, s.seconds, mb(s.memory.footprint), mb(s.memory.footprintPeak), mb(s.memory.available));
        o << line;
    }
    o << "\n  ]\n}\n";
    return o.str();
}
}
