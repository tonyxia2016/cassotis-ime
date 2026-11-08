// Replays a corpus against a running cassotis-engine over its socket, the way the
// macOS input method drives it: one key at a time, the next one a fixed pace after
// the previous result, and in between the input method's 25 ms tick, which sends a
// poll while a result is pending and takes its answer on a later tick
// (EngineClient::sendPoll / takePoll). Each key is timed from the moment it is due
// to its result, so a key held up behind a poll counts in full.
//
//   socket_replay --socket ./s/engine.sock --corpus ../../ios/bench/corpus.tsv \
//       [--keys 1519] [--pace-us 170000] [--label name] [--output result.json]
//
// Whole sentences are replayed, from the first and round again, until at least
// --keys keys: 1519 is ios/bench/corpus.tsv once. --pace-us 0 types continuously
// and times each key from when it is sent.
//
// Build: xcrun clang++ -std=c++20 -O2 tools/bench/socket_replay.cpp
//        src/macos/EngineClient.cpp -o build/socket_replay
#include "../../src/macos/EngineClient.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

using namespace cassotis;
using clock_type = std::chrono::steady_clock;

namespace {
struct Sentence {
    std::string target, keys;
};

std::vector<Sentence> load(const std::string &path) {
    std::vector<Sentence> rows;
    std::ifstream in(path);
    std::string line;
    while (std::getline(in, line)) {
        auto tab = line.find('\t');
        if (tab == std::string::npos) continue;
        rows.push_back({line.substr(0, tab), line.substr(tab + 1)});
    }
    return rows;
}

double percentile(std::vector<double> values, double q) {
    if (values.empty()) return 0;
    std::sort(values.begin(), values.end());
    return values[std::min(values.size() - 1, size_t(q * double(values.size())))];
}
}  // namespace

int main(int argc, char **argv) {
    std::string socket, corpus, label = "socket", output;
    unsigned maxKeys = 1519;
    long paceMicros = 170000;
    for (int i = 1; i + 1 < argc; i += 2) {
        std::string name = argv[i], value = argv[i + 1];
        if (name == "--socket") socket = value;
        else if (name == "--corpus") corpus = value;
        else if (name == "--keys") maxKeys = unsigned(std::stoul(value));
        else if (name == "--pace-us") paceMicros = std::stol(value);
        else if (name == "--label") label = value;
        else if (name == "--output") output = value;
        else { std::fprintf(stderr, "unknown option %s\n", name.c_str()); return 2; }
    }
    auto rows = load(corpus);
    if (socket.empty() || rows.empty()) { std::fprintf(stderr, "need --socket and --corpus\n"); return 2; }
    EngineClient client;
    if (!client.connect(socket)) { std::fprintf(stderr, "cannot connect to %s\n", socket.c_str()); return 1; }

    const auto pace = std::chrono::microseconds(paceMicros);
    const auto tick = std::chrono::milliseconds(25);
    std::vector<double> latency;
    unsigned keys = 0, sentences = 0, firstHits = 0, pendingKeys = 0;
    unsigned pollsSent = 0, pollsAnswered = 0, pollsApplied = 0, pollsDropped = 0;
    bool pending = false;
    auto ready = clock_type::now();

    // The input method's tick until the next key is due: poll while pending.
    auto waitUntil = [&](clock_type::time_point due) {
        while (clock_type::now() < due) {
            if (pending) {
                Result answer;
                if (client.takePoll(answer)) {
                    ++pollsAnswered;
                    if (answer.handled) { ++pollsApplied; pending = answer.pending; }
                } else if (!client.pollOutstanding()) {
                    client.sendPoll();
                    ++pollsSent;
                }
            }
            std::this_thread::sleep_until(std::min(due, clock_type::now() + tick));
        }
    };
    auto press = [&](const Key &key) {
        auto due = ready + pace;
        waitUntil(due);
        bool outstanding = client.pollOutstanding();
        auto start = paceMicros ? due : clock_type::now();
        Result r = client.key(key);  // an outstanding poll's answer is read and dropped first
        if (outstanding) ++pollsDropped;
        latency.push_back(std::chrono::duration<double, std::milli>(clock_type::now() - start).count());
        ready = clock_type::now();
        ++keys;
        pending = r.pending;
        if (r.pending) ++pendingKeys;
        // As the input method: a pending result starts its poll at once.
        if (r.pending && !client.pollOutstanding()) { client.sendPoll(); ++pollsSent; }
        return r;
    };

    client.active(true);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfor-loop-analysis"
    for (size_t i = 0; keys < maxKeys; i = (i + 1) % rows.size()) {  // press() counts keys
        const Sentence &s = rows[i];
        client.reset();
        pending = false;
        for (char c : s.keys) {
            Key k; k.text = std::string(1, c);
            press(k);
        }
        Key space; space.special = 5;
        Result r = press(space);
        firstHits += r.commit == s.target;
        ++sentences;
    }
#pragma clang diagnostic pop

    char json[1024];
    std::snprintf(json, sizeof json,
        "{\"label\": \"%s\", \"keys\": %u, \"sentences\": %u, \"first_hits\": %u, \"first_rate\": %.4f,\n"
        " \"pace_us\": %ld, \"pending_keys\": %u, \"p50_ms\": %.2f, \"p95_ms\": %.2f, \"p99_ms\": %.2f, \"worst_ms\": %.2f,\n"
        " \"polls_sent\": %u, \"polls_answered\": %u, \"polls_applied\": %u, \"polls_dropped\": %u}\n",
        label.c_str(), keys, sentences, firstHits, sentences ? double(firstHits) / sentences : 0.0,
        paceMicros, pendingKeys, percentile(latency, 0.5), percentile(latency, 0.95), percentile(latency, 0.99),
        latency.empty() ? 0.0 : *std::max_element(latency.begin(), latency.end()),
        pollsSent, pollsAnswered, pollsApplied, pollsDropped);
    std::fputs(json, stdout);
    if (!output.empty()) { std::ofstream(output) << json; }
    return 0;
}
