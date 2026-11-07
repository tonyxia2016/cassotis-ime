// A/B harness for the nc_lm_* runtimes: loads one library, runs every case of
// a file (context TAB text TAB text ...), writes one JSON line per case.
#include <dlfcn.h>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

using Create = void* (*)(const char*, int, char*, int);
using Destroy = void (*)(void*);
using ScoreNext = int (*)(void*, const char16_t*, const char16_t* const*, int, int, int, float*,
    const int*, int, int, uint32_t*, float*, int, char*, int);
using Continue = int (*)(void*, const char16_t*, const char16_t*, int, char16_t*, int, float*, int, char*, int);

static std::u16string Utf16(const std::string& s) {
    std::u16string out;
    for (size_t i = 0; i < s.size();) {
        uint32_t c = static_cast<unsigned char>(s[i]);
        int extra = c < 0x80 ? 0 : c < 0xE0 ? 1 : c < 0xF0 ? 2 : 3;
        c &= extra == 0 ? 0x7F : extra == 1 ? 0x1F : extra == 2 ? 0x0F : 0x07;
        for (int k = 1; k <= extra; ++k) c = (c << 6) | (static_cast<unsigned char>(s[i + k]) & 0x3F);
        i += 1 + extra;
        if (c >= 0x10000) {
            c -= 0x10000;
            out.push_back(static_cast<char16_t>(0xD800 + (c >> 10)));
            out.push_back(static_cast<char16_t>(0xDC00 + (c & 0x3FF)));
        } else out.push_back(static_cast<char16_t>(c));
    }
    return out;
}

static std::string Utf8(uint32_t c) {
    std::string out;
    if (c < 0x80) out += static_cast<char>(c);
    else if (c < 0x800) { out += static_cast<char>(0xC0 | (c >> 6)); out += static_cast<char>(0x80 | (c & 0x3F)); }
    else if (c < 0x10000) {
        out += static_cast<char>(0xE0 | (c >> 12)); out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (c & 0x3F));
    } else {
        out += static_cast<char>(0xF0 | (c >> 18)); out += static_cast<char>(0x80 | ((c >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((c >> 6) & 0x3F)); out += static_cast<char>(0x80 | (c & 0x3F));
    }
    return out;
}

static std::string Utf8(const char16_t* s) {
    std::string out;
    for (; *s; ++s) {
        uint32_t c = *s;
        if (c >= 0xD800 && c < 0xDC00 && s[1]) { c = 0x10000 + ((c - 0xD800) << 10) + (s[1] - 0xDC00); ++s; }
        out += Utf8(c);
    }
    return out;
}

static double Now() {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

int main(int argc, char** argv) {
    if (argc < 4) { std::fprintf(stderr, "usage: lmtest LIB MODEL_DIR CASES [threads] [timeout_ms] [top_k]\n"); return 2; }
    const int threads = argc > 4 ? std::atoi(argv[4]) : 8;
    const int timeout_ms = argc > 5 ? std::atoi(argv[5]) : 0;
    const int top_k = argc > 6 ? std::atoi(argv[6]) : 8;
    void* lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) { std::fprintf(stderr, "%s\n", dlerror()); return 1; }
    auto create = reinterpret_cast<Create>(dlsym(lib, "nc_lm_create"));
    auto destroy = reinterpret_cast<Destroy>(dlsym(lib, "nc_lm_destroy"));
    auto score_next = reinterpret_cast<ScoreNext>(dlsym(lib, "nc_lm_score_next"));
    auto cont = reinterpret_cast<Continue>(dlsym(lib, "nc_lm_continue"));
    char error[1024] = {};
    double t0 = Now();
    void* h = create(argv[2], threads, error, sizeof(error));
    if (!h) { std::fprintf(stderr, "create: %s\n", error); return 1; }
    std::printf("{\"open_ms\":%.1f}\n", Now() - t0);
    std::ifstream in(argv[3]);
    std::string line;
    int index = 0;
    while (std::getline(in, line)) {
        std::vector<std::string> parts;
        size_t start = 0;
        for (;;) {
            size_t tab = line.find('\t', start);
            parts.push_back(line.substr(start, tab == std::string::npos ? std::string::npos : tab - start));
            if (tab == std::string::npos) break;
            start = tab + 1;
        }
        if (parts.size() < 2) continue;
        const std::u16string context = Utf16(parts[0]);
        std::vector<std::u16string> texts;
        for (size_t i = 1; i < parts.size(); ++i) texts.push_back(Utf16(parts[i]));
        std::vector<const char16_t*> pointers;
        for (auto& t : texts) pointers.push_back(t.c_str());
        const int count = static_cast<int>(texts.size());
        std::vector<float> logp(count);
        const int next_index[1] = {0};
        std::vector<uint32_t> next_cp(top_k);
        std::vector<float> next_logp(top_k);
        double t1 = Now();
        int scored = score_next(h, context.c_str(), pointers.data(), count, count, 0, logp.data(),
            next_index, 1, top_k, next_cp.data(), next_logp.data(), timeout_ms, error, sizeof(error));
        double score_ms = Now() - t1;
        char16_t buffer[64] = {};
        float cont_logp[16] = {};
        double t2 = Now();
        int produced = cont(h, context.c_str(), texts[0].c_str(), 6, buffer, 64, cont_logp, timeout_ms, error, sizeof(error));
        double cont_ms = Now() - t2;
        std::printf("{\"i\":%d,\"scored\":%d,\"score_ms\":%.3f,\"cont_ms\":%.3f,\"logp\":[", index, scored, score_ms, cont_ms);
        for (int i = 0; i < count; ++i) std::printf("%s%.4f", i ? "," : "", scored > i ? logp[i] : 0.0f);
        std::printf("],\"next\":[");
        for (int i = 0; i < top_k; ++i)
            std::printf("%s[\"%s\",%.4f]", i ? "," : "", scored > 0 && next_cp[i] ? Utf8(next_cp[i]).c_str() : "", next_logp[i]);
        std::printf("],\"cont\":\"%s\",\"cont_n\":%d", produced > 0 ? Utf8(buffer).c_str() : "", produced);
        if (scored < 0 || produced < 0) {
            std::string e(error);
            for (auto& c : e) if (c == '"' || c == '\\') c = '\'';
            std::printf(",\"error\":\"%s\"", e.c_str());
        }
        std::printf("}\n");
        ++index;
    }
    double t3 = Now();
    destroy(h);
    std::printf("{\"close_ms\":%.1f}\n", Now() - t3);
    return 0;
}
