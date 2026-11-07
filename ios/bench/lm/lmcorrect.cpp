// nc_lm_correct over correct_cases.py's lines (context TAB draft TAB true TAB
// allowed code points: "," within a position, ";" between positions), width 2 as
// the repair host; one JSON line per case.
//   lmcorrect LIB MODEL_DIR CASES
#include <dlfcn.h>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
using Create = void* (*)(const char*, int, char*, int);
using Correct = int (*)(void*, const char16_t*, const char16_t*, const uint32_t*, const int*, int, char16_t*, int, float*, int, char*, int);
static std::u16string Utf16(const std::string& s) {
    std::u16string out;
    for (size_t i = 0; i < s.size();) {
        uint32_t c = static_cast<unsigned char>(s[i]);
        int extra = c < 0x80 ? 0 : c < 0xE0 ? 1 : c < 0xF0 ? 2 : 3;
        c &= extra == 0 ? 0x7F : extra == 1 ? 0x1F : extra == 2 ? 0x0F : 0x07;
        for (int k = 1; k <= extra; ++k) c = (c << 6) | (static_cast<unsigned char>(s[i + k]) & 0x3F);
        i += 1 + extra;
        if (c >= 0x10000) { c -= 0x10000; out.push_back(char16_t(0xD800 + (c >> 10))); out.push_back(char16_t(0xDC00 + (c & 0x3FF))); }
        else out.push_back(char16_t(c));
    }
    return out;
}
static std::string Utf8(const char16_t* s) {
    std::string out;
    for (; *s; ++s) {
        uint32_t c = *s;
        if (c < 0x80) out += char(c);
        else if (c < 0x800) { out += char(0xC0 | (c >> 6)); out += char(0x80 | (c & 0x3F)); }
        else { out += char(0xE0 | (c >> 12)); out += char(0x80 | ((c >> 6) & 0x3F)); out += char(0x80 | (c & 0x3F)); }
    }
    return out;
}
int main(int argc, char** argv) {
    if (argc < 4) { std::fprintf(stderr, "usage: lmcorrect LIB MODEL_DIR CASES\n"); return 2; }
    void* lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) { std::fprintf(stderr, "%s\n", dlerror()); return 1; }
    auto create = reinterpret_cast<Create>(dlsym(lib, "nc_lm_create"));
    auto correct = reinterpret_cast<Correct>(dlsym(lib, "nc_lm_correct"));
    char error[1024] = {};
    void* h = create(argv[2], 8, error, sizeof(error));
    if (!h) { std::fprintf(stderr, "create: %s\n", error); return 1; }
    std::ifstream in(argv[3]);
    std::string line;
    int index = 0;
    while (std::getline(in, line)) {
        std::vector<std::string> parts;
        std::stringstream ss(line);
        std::string part;
        while (std::getline(ss, part, '\t')) parts.push_back(part);
        const auto context = Utf16(parts[0]), draft = Utf16(parts[1]);
        std::vector<uint32_t> allowed;
        std::vector<int> offsets{0};
        std::stringstream positions(parts[3]);
        std::string position;
        while (std::getline(positions, position, ';')) {
            std::stringstream points(position);
            std::string point;
            while (std::getline(points, point, ',')) allowed.push_back(uint32_t(std::stoul(point)));
            offsets.push_back(int(allowed.size()));
        }
        char16_t out[256] = {};
        float gain = 0;
        auto t0 = std::chrono::steady_clock::now();
        int result = correct(h, context.c_str(), draft.c_str(), allowed.data(), offsets.data(), 2, out, 256, &gain, 0, error, sizeof(error));
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        std::printf("{\"i\":%d,\"result\":%d,\"ms\":%.2f,\"gain\":%.3f,\"text\":\"%s\",\"draft\":\"%s\",\"true\":\"%s\"}\n", index++, result, ms, gain,
            result == 1 ? Utf8(out).c_str() : "", parts[1].c_str(), parts[2].c_str());
    }
    return 0;
}
