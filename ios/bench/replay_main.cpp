// macOS driver for replay.cpp: the engine archive linked into a plain process.
#include "replay.hpp"
#include "cassotis_core.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <thread>
using namespace cassotis;

int main(int argc, char **argv) {
    std::string dictionary, user, resources, data, corpus, output, digest, label = "macos";
    ReplayOptions options;
    uint32_t sentences = 0, holdSeconds = 0;
    for (int i = 1; i + 1 < argc; i += 2) {
        std::string a = argv[i], v = argv[i + 1];
        if (a == "--dictionary") dictionary = v;
        else if (a == "--user-dictionary") user = v;
        else if (a == "--resources") resources = v;
        else if (a == "--data") data = v;
        else if (a == "--corpus") corpus = v;
        else if (a == "--output") output = v;
        else if (a == "--digest") options.digestPath = v;
        else if (a == "--label") label = v;
        else if (a == "--keys") options.maxKeys = uint32_t(atoi(v.c_str()));
        else if (a == "--sentences") sentences = uint32_t(atoi(v.c_str()));
        else if (a == "--sample-every") options.sampleEvery = uint32_t(atoi(v.c_str()));
        else if (a == "--pace-us") options.paceMicros = uint32_t(atoi(v.c_str()));
        else if (a == "--context") options.useContext = v == "1";
        else if (a == "--census") options.censusPath = v;
        else if (a == "--trim-every") options.trimEvery = uint32_t(atoi(v.c_str()));
        else if (a == "--option") {  // name=value, passed to the engine before it opens
            auto eq = v.find('=');
            if (eq == std::string::npos || cassotis_core_set_option(v.substr(0, eq).c_str(), atoi(v.c_str() + eq + 1)) != 0) {
                std::cerr << "bad option " << v << "\n"; return 2;
            }
        }
        else if (a == "--hold") holdSeconds = uint32_t(atoi(v.c_str()));
        else if (a == "--loop") options.loop = v == "1";
        else { std::cerr << "unknown option " << a << "\n"; return 2; }
    }
    auto rows = loadCorpus(corpus);
    if (sentences && rows.size() > sentences) rows.resize(sentences);
    auto before = memorySnapshot();
    auto t0 = std::chrono::steady_clock::now();
    EngineClient client;
    std::string error;
    if (!client.connect(dictionary, user, resources, data, error)) {
        std::cerr << "open failed: " << error << "\n";
        return 1;
    }
    double openSeconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    auto after = memorySnapshot();
    auto result = replay(client, rows, options);
    auto json = toJSON(result, label, before, after, openSeconds);
    if (!output.empty()) std::ofstream(output) << json;
    // Summary only: the samples go to the file.
    auto cut = json.find("  \"samples\"");
    std::cout << json.substr(0, cut) << "}\n";
    if (holdSeconds) {  // leave the heap in place for heap(1)/malloc_history(1)
        std::cout.flush();
        std::this_thread::sleep_for(std::chrono::seconds(holdSeconds));
    }
    client.disconnect();
    return result.error.empty() ? 0 : 1;
}
