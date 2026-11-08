// A run of a real shape: R new tokens in a trie under a chain of A tokens, every token
// real. Plain functions run the whole union (A + R). K/V functions run the R new tokens
// against the A kept ones, whose keys and values come from earlier runs of the function;
// each timed run also copies the kept rows into the input and the new rows out of the
// output, as a backend would.
//   kv_real MODEL.mlmodelc [--surface] [--leaves-unread] R A FUNCTION [R A FUNCTION...]
#import <CoreML/CoreML.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>
#include <vector>

static double now_ms() {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
static MLMultiArray* array(NSArray<NSNumber*>* shape, MLMultiArrayDataType type) {
    NSError* error = nil;
    MLMultiArray* a = [[MLMultiArray alloc] initWithShape:shape dataType:type error:&error];
    if (!a) { NSLog(@"array: %@", error); exit(1); }
    return a;
}
static const int kVocab = 12017, kBlocks = 22, kEmbed = 1024;

struct Run {
    MLModel* model = nil;
    int n = 0, p = 0;
    MLMultiArray* ids = nil;
    MLMultiArray* positions = nil;
    MLMultiArray* mask = nil;
    MLMultiArray* past = nil;
    id<MLFeatureProvider> input = nil;
    size_t past_row_bytes = kEmbed * 2;
    void* past_bytes = nullptr;
    size_t past_block_stride = 0;
};

// Sets the token rows: tokens[i] sees sees[i] (columns of the mask).
static void fill(Run& r, const std::vector<int>& ids, const std::vector<int>& positions,
    const std::vector<std::vector<int>>& sees) {
    auto* idv = static_cast<int32_t*>(r.ids.dataPointer);
    auto* pov = static_cast<int32_t*>(r.positions.dataPointer);
    auto* mv = static_cast<_Float16*>(r.mask.dataPointer);
    const size_t rs = r.mask.strides[2].unsignedLongValue, cs = r.mask.strides[3].unsignedLongValue;
    const int width = r.p + r.n;
    for (int t = 0; t < r.n; ++t) {
        _Float16* line = mv + t * rs;
        for (int c = 0; c < width; ++c) line[c * cs] = -30000.0f;
        if (t < int(ids.size())) {
            idv[t] = ids[t];
            pov[t] = positions[t];
            for (int c : sees[t]) line[c * cs] = 0;
        } else {
            idv[t] = 0;
            pov[t] = 0;
            line[(r.p + t) * cs] = 0;
        }
    }
}

int main(int argc, char** argv) {
    @autoreleasepool {
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        std::mt19937 rng(7);
        bool surface = false;
        int a = 2;
        if (a < argc && std::string(argv[a]) == "--surface") { surface = true; ++a; }
        for (; a + 2 < argc; a += 3) {
            @autoreleasepool {
                const int R = atoi(argv[a]), A = atoi(argv[a + 1]);
                const std::string name = argv[a + 2];
                int n = 0, p = 0;
                const bool kv = std::sscanf(name.c_str(), "kv%d_%d", &n, &p) == 2;
                if (!kv && std::sscanf(name.c_str(), "len%d", &n) != 1) return 2;
                MLModelConfiguration* config = [[MLModelConfiguration alloc] init];
                config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
                config.functionName = [NSString stringWithUTF8String:name.c_str()];
                NSError* error = nil;
                Run r;
                r.model = [MLModel modelWithContentsOfURL:url configuration:config error:&error];
                if (!r.model) { NSLog(@"load: %@", error); return 1; }
                r.n = n;
                r.p = p;
                r.ids = array(@[@1, @(n)], MLMultiArrayDataTypeInt32);
                r.positions = array(@[@1, @(n)], MLMultiArrayDataTypeInt32);
                r.mask = array(@[@1, @1, @(n), @(p + n)], MLMultiArrayDataTypeFloat16);
                NSMutableDictionary* inputs = [@{@"ids": r.ids, @"positions": r.positions, @"mask": r.mask} mutableCopy];
                CVPixelBufferRef buffer = nullptr;
                if (kv) {
                    NSArray<NSNumber*>* shape = @[@1, @(kBlocks), @(p), @(kEmbed)];
                    if (surface) {
                        NSDictionary* attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
                        if (CVPixelBufferCreate(kCFAllocatorDefault, kEmbed, kBlocks * p,
                                kCVPixelFormatType_OneComponent16Half, (__bridge CFDictionaryRef)attributes, &buffer) != kCVReturnSuccess)
                            return 1;
                        CVPixelBufferLockBaseAddress(buffer, 0);
                        r.past_bytes = CVPixelBufferGetBaseAddress(buffer);
                        r.past_row_bytes = CVPixelBufferGetBytesPerRow(buffer);
                        r.past = [[MLMultiArray alloc] initWithPixelBuffer:buffer shape:shape];
                        CVPixelBufferUnlockBaseAddress(buffer, 0);
                    } else {
                        r.past = array(shape, MLMultiArrayDataTypeFloat16);
                        r.past_bytes = r.past.dataPointer;
                    }
                    std::memset(r.past_bytes, 0, r.past_row_bytes * kBlocks * p);
                    inputs[@"past"] = r.past;
                }
                r.input = [[MLDictionaryFeatureProvider alloc] initWithDictionary:inputs error:&error];
                if (!r.input) { NSLog(@"input: %@", error); return 1; }

                // Output backings, as the backend has for logp_all.
                std::vector<_Float16> logp_store(size_t(n) * kVocab), present_store;
                MLMultiArray* logp = [[MLMultiArray alloc] initWithDataPointer:logp_store.data()
                    shape:@[@1, @(n), @(kVocab)] dataType:MLMultiArrayDataTypeFloat16
                    strides:@[@(n * kVocab), @(kVocab), @1] deallocator:nil error:&error];
                MLPredictionOptions* options = [[MLPredictionOptions alloc] init];
                NSMutableDictionary* backings = [@{@"logp_all": logp} mutableCopy];
                if (kv) {
                    present_store.resize(size_t(n) * kBlocks * kEmbed);
                    backings[@"present"] = [[MLMultiArray alloc] initWithDataPointer:present_store.data()
                        shape:@[@1, @(kBlocks), @(n), @(kEmbed)] dataType:MLMultiArrayDataTypeFloat16
                        strides:@[@(kBlocks * n * kEmbed), @(n * kEmbed), @(kEmbed), @1] deallocator:nil error:&error];
                }
                options.outputBackings = backings;

                std::uniform_int_distribution<int> token(2, kVocab - 1);
                std::vector<int> chain(A);
                for (int& t : chain) t = token(rng);
                // A store of kept rows outside the input, as a backend's memo would be.
                std::vector<_Float16> store(size_t(std::max(A, 1) + R) * kBlocks * kEmbed);
                auto store_row = [&](int block, int slot) { return store.data() + (size_t(slot) * kBlocks + block) * kEmbed; };

                // The R new tokens: branches of four under the chain.
                auto trie = [&](int base, std::vector<int>& ids, std::vector<int>& positions, std::vector<std::vector<int>>& sees,
                                int offset_new, int offset_old, int old_count) {
                    std::vector<int> parent(R);
                    for (int i = 0; i < R; ++i) {
                        parent[i] = i % 4 == 0 ? -1 : i - 1;
                        ids.push_back(token(rng));
                        std::vector<int> see;
                        for (int c = 0; c < old_count; ++c) see.push_back(offset_old + c);
                        int depth = 0;
                        for (int j = i; j >= 0; j = parent[j]) { see.push_back(offset_new + j); ++depth; }
                        positions.push_back(base + depth - 1);
                        sees.push_back(see);
                    }
                };
                std::vector<int> ids, positions;
                std::vector<std::vector<int>> sees;
                if (!kv) {
                    // The whole union: the chain, then the trie.
                    for (int i = 0; i < A; ++i) {
                        ids.push_back(chain[i]);
                        positions.push_back(i);
                        std::vector<int> see;
                        for (int c = 0; c <= i; ++c) see.push_back(c);
                        sees.push_back(see);
                    }
                    trie(A, ids, positions, sees, A, 0, A);
                    if (int(ids.size()) > n) { fprintf(stderr, "%s too short for %d\n", name.c_str(), A + R); return 2; }
                    fill(r, ids, positions, sees);
                } else {
                    if (A > p || R > n) { fprintf(stderr, "%s too short for R %d A %d\n", name.c_str(), R, A); return 2; }
                    // Earlier runs give the chain its keys and values.
                    for (int begin = 0; begin < A;) {
                        const int count = std::min(n, A - begin);
                        ids.clear(); positions.clear(); sees.clear();
                        for (int i = 0; i < count; ++i) {
                            ids.push_back(chain[begin + i]);
                            positions.push_back(begin + i);
                            std::vector<int> see;
                            for (int c = 0; c < begin; ++c) see.push_back(c);
                            for (int c = 0; c <= i; ++c) see.push_back(p + c);
                            sees.push_back(see);
                        }
                        fill(r, ids, positions, sees);
                        id<MLFeatureProvider> out = [r.model predictionFromFeatures:r.input options:options error:&error];
                        if (!out) { NSLog(@"predict: %@", error); return 1; }
                        for (int i = 0; i < count; ++i)
                            for (int b = 0; b < kBlocks; ++b) {
                                const _Float16* source = present_store.data() + (size_t(b) * n + i) * kEmbed;
                                std::memcpy(store_row(b, begin + i), source, kEmbed * 2);
                                std::memcpy(static_cast<uint8_t*>(r.past_bytes) + (size_t(b) * p + begin + i) * r.past_row_bytes, source, kEmbed * 2);
                            }
                        begin += count;
                    }
                    ids.clear(); positions.clear(); sees.clear();
                    trie(A, ids, positions, sees, p, 0, A);
                    fill(r, ids, positions, sees);
                }
                std::vector<double> times, copies;
                for (int run = 0; run < 45; ++run) {
                    @autoreleasepool {
                        double t0 = now_ms();
                        if (kv)  // the kept rows into the input
                            for (int b = 0; b < kBlocks; ++b)
                                for (int s = 0; s < A; ++s)
                                    std::memcpy(static_cast<uint8_t*>(r.past_bytes) + (size_t(b) * p + s) * r.past_row_bytes,
                                        store_row(b, s), kEmbed * 2);
                        const double t1 = now_ms();
                        id<MLFeatureProvider> out = [r.model predictionFromFeatures:r.input options:options error:&error];
                        if (!out) { NSLog(@"predict: %@", error); return 1; }
                        const double t2 = now_ms();
                        if (kv)  // the new rows into the store
                            for (int b = 0; b < kBlocks; ++b)
                                for (int s = 0; s < R; ++s)
                                    std::memcpy(store_row(b, A + s), present_store.data() + (size_t(b) * n + s) * kEmbed, kEmbed * 2);
                        const double t3 = now_ms();
                        if (run >= 5) { times.push_back(t2 - t1); copies.push_back((t1 - t0) + (t3 - t2)); }
                    }
                }
                std::sort(times.begin(), times.end());
                std::sort(copies.begin(), copies.end());
                printf("R %3d A %3d  %-10s %s predict median %6.2f ms (p90 %6.2f), copies %5.2f ms, total %6.2f ms\n", R, A, name.c_str(),
                    kv ? (surface ? "surface" : "plain  ") : "       ", times[times.size() / 2], times[times.size() * 9 / 10],
                    copies[copies.size() / 2], times[times.size() / 2] + copies[copies.size() / 2]);
                fflush(stdout);
                if (buffer) CVPixelBufferRelease(buffer);
            }
        }
    }
    return 0;
}
