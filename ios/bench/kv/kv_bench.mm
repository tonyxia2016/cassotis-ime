// Times one function of a compiled model: kv_bench MODEL.mlmodelc [--surface] [--runs N] FUNCTION...
// len<N>: the plain functions; kv<N>_<P>: keys and values as inputs and outputs.
// --surface backs `past` with an IOSurface pixel buffer, which Core ML can hand to the
// Neural Engine without a copy.
#import <CoreML/CoreML.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

static double now_ms() {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
static double footprint_mb() {
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count);
    return info.phys_footprint / 1048576.0;
}
static MLMultiArray* array(NSArray<NSNumber*>* shape, MLMultiArrayDataType type) {
    NSError* error = nil;
    MLMultiArray* a = [[MLMultiArray alloc] initWithShape:shape dataType:type error:&error];
    if (!a) { NSLog(@"array: %@", error); exit(1); }
    return a;
}

int main(int argc, char** argv) {
    @autoreleasepool {
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        bool surface = false, fast = false;
        int runs = 60, gap = 0;
        const int chain = 30;
        for (int a = 2; a < argc; ++a) {
            std::string name = argv[a];
            if (name == "--surface") { surface = true; continue; }
            if (name == "--plain") { surface = false; continue; }
            if (name == "--runs") { runs = atoi(argv[++a]); continue; }
            if (name == "--fast") { fast = true; continue; }
            if (name == "--gap") { gap = atoi(argv[++a]); continue; }
            @autoreleasepool {
                int n = 0, p = 0;
                bool kv = std::sscanf(name.c_str(), "kv%d_%d", &n, &p) == 2;
                if (!kv && std::sscanf(name.c_str(), "len%d", &n) != 1) { fprintf(stderr, "bad %s\n", name.c_str()); return 2; }
                MLModelConfiguration* config = [[MLModelConfiguration alloc] init];
                config.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
                config.functionName = [NSString stringWithUTF8String:name.c_str()];
                if (fast) {
                    MLOptimizationHints* hints = [[MLOptimizationHints alloc] init];
                    hints.specializationStrategy = MLSpecializationStrategyFastPrediction;
                    config.optimizationHints = hints;
                }
                const double before = footprint_mb();
                double t0 = now_ms();
                NSError* error = nil;
                MLModel* model = [MLModel modelWithContentsOfURL:url configuration:config error:&error];
                if (!model) { NSLog(@"load: %@", error); return 1; }
                const double loaded = now_ms() - t0;
                const int width = p + n;
                MLMultiArray* ids = array(@[@1, @(n)], MLMultiArrayDataTypeInt32);
                MLMultiArray* positions = array(@[@1, @(n)], MLMultiArrayDataTypeInt32);
                MLMultiArray* mask = array(@[@1, @1, @(n), @(width)], MLMultiArrayDataTypeFloat16);
                // A chain of up to `chain` tokens: each sees the kept ones and those before it.
                const int used = std::min(n, chain);
                auto* idv = static_cast<int32_t*>(ids.dataPointer);
                auto* pov = static_cast<int32_t*>(positions.dataPointer);
                auto* mv = static_cast<_Float16*>(mask.dataPointer);
                const size_t rs = mask.strides[2].unsignedLongValue, cs = mask.strides[3].unsignedLongValue;
                for (int t = 0; t < n; ++t) {
                    _Float16* line = mv + t * rs;
                    for (int c = 0; c < width; ++c) line[c * cs] = -30000.0f;
                    if (t < used) {
                        idv[t] = 100 + t;
                        pov[t] = t + std::min(p, 16);
                        for (int c = 0; c < std::min(p, 16); ++c) line[c * cs] = 0;
                        for (int c = 0; c <= t; ++c) line[(p + c) * cs] = 0;
                    } else {
                        idv[t] = 0;
                        pov[t] = 0;
                        line[(p + t) * cs] = 0;
                    }
                }
                NSMutableDictionary* inputs = [@{@"ids": ids, @"positions": positions, @"mask": mask} mutableCopy];
                CVPixelBufferRef buffer = nullptr;
                if (kv) {
                    MLMultiArray* past = nil;
                    NSArray<NSNumber*>* shape = @[@1, @22, @(p), @1024];
                    if (surface) {
                        NSDictionary* attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
                        CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, 1024, 22 * p,
                            kCVPixelFormatType_OneComponent16Half, (__bridge CFDictionaryRef)attributes, &buffer);
                        if (status != kCVReturnSuccess) { fprintf(stderr, "pixel buffer: %d\n", status); return 1; }
                        CVPixelBufferLockBaseAddress(buffer, 0);
                        auto* bytes = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
                        const size_t row = CVPixelBufferGetBytesPerRow(buffer);
                        for (int y = 0; y < 22 * p; ++y) {
                            auto* line = reinterpret_cast<_Float16*>(bytes + y * row);
                            for (int x = 0; x < 1024; ++x) line[x] = _Float16(((x * 7 + y * 13) % 200) / 100.0f - 1.0f);
                        }
                        CVPixelBufferUnlockBaseAddress(buffer, 0);
                        past = [[MLMultiArray alloc] initWithPixelBuffer:buffer shape:shape];
                        if (!past) { fprintf(stderr, "pixel buffer array refused\n"); return 1; }
                    } else {
                        past = array(shape, MLMultiArrayDataTypeFloat16);
                        auto* values = static_cast<_Float16*>(past.dataPointer);
                        const size_t total = 22 * size_t(p) * 1024;
                        for (size_t i = 0; i < total; ++i) values[i] = _Float16((i % 200) / 100.0f - 1.0f);
                    }
                    inputs[@"past"] = past;
                }
                id<MLFeatureProvider> input = [[MLDictionaryFeatureProvider alloc] initWithDictionary:inputs error:&error];
                if (!input) { NSLog(@"input: %@", error); return 1; }
                t0 = now_ms();
                id<MLFeatureProvider> out = [model predictionFromFeatures:input error:&error];
                if (!out) { NSLog(@"predict: %@", error); return 1; }
                const double first = now_ms() - t0;
                std::vector<double> times;
                for (int r = 0; r < runs + 5; ++r) {
                    @autoreleasepool {
                        if (gap) std::this_thread::sleep_for(std::chrono::milliseconds(gap));
                        t0 = now_ms();
                        out = [model predictionFromFeatures:input error:&error];
                        const double t = now_ms() - t0;
                        if (r >= 5) times.push_back(t);
                    }
                }
                std::sort(times.begin(), times.end());
                printf("%-12s %s load %8.1f ms  first %7.1f ms  median %6.2f ms  p90 %6.2f ms  min %6.2f ms  footprint +%.1f MB\n",
                    name.c_str(), kv ? (surface ? "surface" : "plain  ") : "       ", loaded, first,
                    times[times.size() / 2], times[times.size() * 9 / 10], times.front(), footprint_mb() - before);
                fflush(stdout);
                if (buffer) CVPixelBufferRelease(buffer);
            }
        }
    }
    return 0;
}
