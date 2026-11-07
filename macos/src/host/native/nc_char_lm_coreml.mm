// Core ML backend of the shared character language model (nc_lm_*), for iOS
// and macOS. It exports the same C functions as nc_char_lm_ort.cpp and runs
// the same algorithms (nc_char_lm_ort.inc): the trie of candidates, the memo
// of earlier calls, continuation and draft correction. Only one graph run
// differs.
//
// The model is char_lm.mlmodelc, made from char_lm.onnx by
// scripts/char_lm_coreml.py: the same int8 weights, float16 activations, one
// function per sequence length (64, 128 and 256 by default; metadata.json
// lists them) so that every shape is fixed and Core ML can place the whole
// graph on the Neural Engine. There the weights do not count against the
// process: on an iPhone 15 Pro the keyboard extension holds 3.5 MB more once
// the model is loaded and about 17 MB more after 10,000 keys, where the ONNX
// Runtime engine on macOS holds some 300 MB.
//
// A Core ML run has no inputs for keys and values of earlier tokens. Where the
// algorithms keep keys and values (CharLmKeys), this backend keeps each
// token's chain -- the ids and positions from BOS to the token -- and a run
// computes the union of the chains of its tokens again, as one trie. The
// numbers of a token depend on its chain alone, so the result is what a run
// over the kept keys would give. A union longer than the longest function is
// split into several predictions of whole chains.
#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>
#include <mach/mach.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cfloat>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <vector>

#define CASSOTIS_EXPORT __attribute__((visibility("default")))
#define NC_CHAR_LM_COREML 1

// Multifunction models need iOS 18 / macOS 15, newer than every Core ML API used
// here, and CharLmOpenModel, the only way to a model, checks for them first; the
// deployment targets of the hosts are older (iOS 15, macOS 11 and 14).
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

// The few ONNX Runtime types nc_char_lm_ort.inc names, for this backend.
namespace Ort {
class RunOptions {
    std::atomic<bool> stop_{false};
public:
    void SetTerminate() { stop_.store(true); }
    bool Terminated() const { return stop_.load(); }
};

// A run's result: [0] the log-probabilities of its new tokens, float [1, n, vocab];
// [1] the chains of its new tokens (what a past would hold); or, from
// CharLmKeys::Past(), the key store a run is given as its past.
class Value {
public:
    struct Shape {
        std::vector<int64_t> dims;
        std::vector<int64_t> GetShape() const { return dims; }
    };
    Value() = default;
    Value(std::nullptr_t) {}
    template <typename T> const T* GetTensorData() const {
        static_assert(std::is_same<T, float>::value, "the Core ML backend returns float log-probabilities");
        return logp.get();
    }
    Shape GetTensorTypeAndShapeInfo() const { return {dims}; }

    std::shared_ptr<float[]> logp;
    std::vector<int64_t> dims;
    std::shared_ptr<std::vector<std::vector<uint32_t>>> chains;
    const void* store = nullptr;
};
}  // namespace Ort

namespace {
std::mutex& InitializationMutex() { static std::mutex mutex; return mutex; }
template <typename T> bool ReadBinary(std::ifstream& stream, T& value) {
    return static_cast<bool>(stream.read(reinterpret_cast<char*>(&value), sizeof(value)));
}

// As in nc_char_lm_ort.cpp: the Pascal host may run with floating-point traps
// enabled; library code must not raise them.
class FloatingPointMaskGuard {
public:
    FloatingPointMaskGuard() {
#if defined(__aarch64__)
        asm volatile("mrs %0, fpcr" : "=r"(old_fpcr_));
        asm volatile("mrs %0, fpsr" : "=r"(old_fpsr_));
        constexpr std::uint64_t kExceptionEnableMask = (UINT64_C(0x1f) << 8) | (UINT64_C(1) << 15);
        const std::uint64_t masked_fpcr = old_fpcr_ & ~kExceptionEnableMask;
        asm volatile("msr fpcr, %0\n\tisb" : : "r"(masked_fpcr) : "memory");
        asm volatile("msr fpsr, xzr" : : : "memory");
#endif
    }
    ~FloatingPointMaskGuard() {
#if defined(__aarch64__)
        asm volatile("msr fpsr, %0" : : "r"(old_fpsr_) : "memory");
        asm volatile("msr fpcr, %0\n\tisb" : : "r"(old_fpcr_) : "memory");
#endif
    }
private:
#if defined(__aarch64__)
    std::uint64_t old_fpcr_{};
    std::uint64_t old_fpsr_{};
#endif
};

void SetError(char* destination, int capacity, std::string_view message) {
    if (destination == nullptr || capacity <= 0) return;
    const size_t copy_length = std::min(message.size(), static_cast<size_t>(capacity - 1));
    if (copy_length > 0) std::memcpy(destination, message.data(), copy_length);
    destination[copy_length] = '\0';
}

std::string ErrorText(const char* message) {
    if (message == nullptr || *message == '\0') return "unknown Core ML error";
    return message;
}

// A token of a chain: id and position packed in one word.
inline uint32_t CharLmPack(int64_t id, int64_t position) {
    return (static_cast<uint32_t>(id) << 16) | static_cast<uint32_t>(position & 0xFFFF);
}
inline int64_t CharLmPackedId(uint32_t packed) { return packed >> 16; }
inline int64_t CharLmPackedPosition(uint32_t packed) { return packed & 0xFFFF; }

// Where nc_char_lm_ort.inc keeps keys and values, the chains of the kept tokens.
class CharLmKeys {
    size_t capacity_{}, count_{};
    std::vector<std::vector<uint32_t>> chains_;

public:
    size_t count() const { return count_; }
    size_t capacity() const { return capacity_; }

    void Reset(int64_t, int64_t, int64_t, size_t capacity) {
        count_ = 0;
        if (capacity_ < capacity) {
            capacity_ = capacity;
            chains_.resize(capacity_);
        }
    }

    void Truncate(size_t count) { count_ = std::min(count_, count); }

    void Append(const std::vector<Ort::Value>& outputs, size_t rows, const std::vector<size_t>& taken) {
        if (outputs.size() < 2 || !outputs[1].chains || outputs[1].chains->size() != rows)
            throw std::runtime_error("character LM run without its chains");
        if (count_ + taken.size() > capacity_) throw std::runtime_error("character LM cache is full");
        for (size_t k = 0; k < taken.size(); ++k) chains_[count_ + k] = (*outputs[1].chains)[taken[k]];
        count_ += taken.size();
    }

    void Keep(const std::vector<int32_t>& kept) {
        for (size_t k = 0; k < kept.size(); ++k)
            if (static_cast<size_t>(kept[k]) != k) chains_[k] = std::move(chains_[static_cast<size_t>(kept[k])]);
        count_ = kept.size();
    }

    std::vector<Ort::Value> Past() {
        Ort::Value past;
        past.store = this;
        return {std::move(past)};
    }

    const std::vector<uint32_t>& Chain(size_t slot) const {
        if (slot >= count_) throw std::runtime_error("character LM mask names an empty slot");
        return chains_[slot];
    }
};

// One function of the model with its input buffers, reused by every run of its
// length (runs are serialized).
struct CharLmFunction {
    int length = 0;
    MLModel* model = nil;
    MLMultiArray* ids = nil;
    MLMultiArray* positions = nil;
    MLMultiArray* mask = nil;
    MLMultiArray* logp = nil;  // the output, in the model's shared buffer
    MLPredictionOptions* options = nil;
    id<MLFeatureProvider> input = nil;
};

// One compiled model, shared by every handle opened on it: one Core ML function
// per sequence length (the lengths are in its metadata.json), each loaded on
// first use. Runs are serialized; the Neural Engine takes one at a time anyway,
// and so all functions write their output to one buffer, sized for the longest.
class CharLmCoreMlModel {
public:
    explicit CharLmCoreMlModel(const std::string& path) {
        @autoreleasepool {
            url_ = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()] isDirectory:YES];
            // A test knob: where Core ML may run the model (default: CPU and Neural Engine).
            const char* units = std::getenv("CASSOTIS_LM_COMPUTE_UNITS");
            const std::string chosen = units ? units : "";
            explicit_units_ = !chosen.empty();
            units_ = chosen == "gpu" ? MLComputeUnitsCPUAndGPU : chosen == "cpu" ? MLComputeUnitsCPUOnly :
                chosen == "all" ? MLComputeUnitsAll : MLComputeUnitsCPUAndNeuralEngine;
            NSData* data = [NSData dataWithContentsOfURL:[url_ URLByAppendingPathComponent:@"metadata.json"]];
            id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            id first = [root isKindOfClass:[NSArray class]] && [root count] > 0 ? root[0] : nil;
            id functions = [first isKindOfClass:[NSDictionary class]] ? first[@"functions"] : nil;
            if ([functions isKindOfClass:[NSArray class]])
                for (id function in functions) {
                    id name = [function isKindOfClass:[NSDictionary class]] ? function[@"name"] : nil;
                    int length = 0;
                    if ([name isKindOfClass:[NSString class]] && std::sscanf([name UTF8String], "len%d", &length) == 1 &&
                        length > 0 && length <= 4096)
                        lengths_.push_back(length);
                }
            std::sort(lengths_.begin(), lengths_.end());
            lengths_.erase(std::unique(lengths_.begin(), lengths_.end()), lengths_.end());
            if (lengths_.empty()) throw std::runtime_error("character LM model lists no len<N> functions");
        }
    }

    const std::vector<int>& lengths() const { return lengths_; }
    size_t Longest() const { return static_cast<size_t>(lengths_.back()); }

    // The shortest function that holds `tokens`, 0 when none does.
    int Bucket(size_t tokens) const {
        for (int length : lengths_)
            if (tokens <= static_cast<size_t>(length)) return length;
        return 0;
    }

    // Callers hold mutex() and an autorelease pool.
    CharLmFunction& Function(int length) {
        auto found = functions_.find(length);
        if (found != functions_.end()) return *found->second;
        if (@available(macOS 15.0, iOS 18.0, *)) {
            auto function = std::make_unique<CharLmFunction>();
            function->length = length;
            MLModelConfiguration* configuration = [[MLModelConfiguration alloc] init];
            configuration.computeUnits = units_;
            configuration.functionName = [NSString stringWithFormat:@"len%d", length];
            NSError* error = nil;
            function->model = [MLModel modelWithContentsOfURL:url_ configuration:configuration error:&error];
            if (!function->model)
                throw std::runtime_error(std::string("character LM model unavailable: ") +
                    (error ? error.localizedDescription.UTF8String : "unknown error"));
            function->ids = Array(@[@1, @(length)], MLMultiArrayDataTypeInt32);
            function->positions = Array(@[@1, @(length)], MLMultiArrayDataTypeInt32);
            function->mask = Array(@[@1, @1, @(length), @(length)], MLMultiArrayDataTypeFloat16);
            const size_t vocab = Vocabulary(function->model);
            const size_t needed = Longest() * vocab;
            if (!output_) {
                output_.reset(new _Float16[needed]);
                output_size_ = needed;
            } else if (output_size_ != needed) {
                // Earlier functions' backings point into the buffer: never reallocate it.
                throw std::runtime_error("character LM functions disagree on their vocabulary");
            }
            error = nil;
            function->logp = [[MLMultiArray alloc] initWithDataPointer:output_.get()
                shape:@[@1, @(length), @(vocab)] dataType:MLMultiArrayDataTypeFloat16
                strides:@[@(static_cast<NSInteger>(length * vocab)), @(static_cast<NSInteger>(vocab)), @1]
                deallocator:nil error:&error];
            if (!function->logp) throw std::runtime_error("character LM output allocation failed");
            function->options = [[MLPredictionOptions alloc] init];
            function->options.outputBackings = @{@"logp_all": function->logp};
            function->input = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{
                @"ids": function->ids, @"positions": function->positions, @"mask": function->mask} error:&error];
            if (!function->input) throw std::runtime_error("character LM input failed");
            return *functions_.emplace(length, std::move(function)).first->second;
        }
        throw std::runtime_error("the Core ML character LM needs iOS 18 or macOS 15");
    }

    std::mutex& mutex() { return mutex_; }
    // The buffer every function's output backing points into.
    const _Float16* Output() const { return output_.get(); }
    // CASSOTIS_LM_COMPUTE_UNITS chose where to run: no device checks.
    bool explicit_units() const { return explicit_units_; }
    // CharLmOpenModel has found that this device runs the model (callers hold mutex()).
    bool checked() const { return checked_; }
    void set_checked() { checked_ = true; }

private:
    static MLMultiArray* Array(NSArray<NSNumber*>* shape, MLMultiArrayDataType type) {
        NSError* error = nil;
        MLMultiArray* array = [[MLMultiArray alloc] initWithShape:shape dataType:type error:&error];
        if (!array) throw std::runtime_error("character LM input allocation failed");
        return array;
    }

    static size_t Vocabulary(MLModel* model) {
        MLFeatureDescription* output = model.modelDescription.outputDescriptionsByName[@"logp_all"];
        NSArray<NSNumber*>* shape = output.multiArrayConstraint.shape;
        if (shape.count != 3 || output.multiArrayConstraint.dataType != MLMultiArrayDataTypeFloat16)
            throw std::runtime_error("character LM model has no float16 logp_all [1, length, vocabulary]");
        return shape[2].unsignedLongValue;
    }

    NSURL* url_ = nil;
    MLComputeUnits units_ = MLComputeUnitsCPUAndNeuralEngine;
    bool explicit_units_ = false;
    bool checked_ = false;
    std::vector<int> lengths_;
    std::map<int, std::unique_ptr<CharLmFunction>> functions_;
    std::unique_ptr<_Float16[]> output_;
    size_t output_size_ = 0;
    std::mutex mutex_;
};
}  // namespace

#include "nc_char_lm_ort.inc"

namespace {
constexpr _Float16 kCharLmMasked = -30000.0f;  // the converter's mask value; exp() of it is zero

// One prediction over a trie of tokens (every token after its parent); copies
// the log-probabilities of `rows` (pairs of trie node, row of the result) into
// `out` (rows of `vocab` floats).
void CharLmPredict(CharLmCoreMlModel& model, const std::vector<uint32_t>& tokens,
    const std::vector<int32_t>& parents, const std::vector<std::pair<int32_t, size_t>>& rows,
    size_t vocab, float* out) {
    const int length = model.Bucket(tokens.size());
    if (length == 0) throw std::runtime_error("character LM run is longer than the model's longest function");
    CharLmFunction& f = model.Function(length);
    int32_t* id_values = static_cast<int32_t*>(f.ids.dataPointer);
    int32_t* position_values = static_cast<int32_t*>(f.positions.dataPointer);
    _Float16* mask_values = static_cast<_Float16*>(f.mask.dataPointer);
    const size_t id_stride = static_cast<size_t>(f.ids.strides[1].integerValue);
    const size_t position_stride = static_cast<size_t>(f.positions.strides[1].integerValue);
    const size_t row_stride = static_cast<size_t>(f.mask.strides[2].integerValue);
    const size_t column_stride = static_cast<size_t>(f.mask.strides[3].integerValue);
    const size_t total = tokens.size();
    for (size_t t = 0; t < static_cast<size_t>(length); ++t) {
        _Float16* line = mask_values + t * row_stride;
        for (size_t c = 0; c < static_cast<size_t>(length); ++c) line[c * column_stride] = kCharLmMasked;
        if (t < total) {
            id_values[t * id_stride] = static_cast<int32_t>(CharLmPackedId(tokens[t]));
            position_values[t * position_stride] = static_cast<int32_t>(CharLmPackedPosition(tokens[t]));
            for (int32_t a = static_cast<int32_t>(t); a >= 0; a = parents[static_cast<size_t>(a)])
                line[static_cast<size_t>(a) * column_stride] = 0;
        } else {
            // Padding: a token of its own, so that its softmax is defined.
            id_values[t * id_stride] = 0;
            position_values[t * position_stride] = 0;
            line[t * column_stride] = 0;
        }
    }
    NSError* error = nil;
    id<MLFeatureProvider> output = [f.model predictionFromFeatures:f.input options:f.options error:&error];
    if (!output)
        throw std::runtime_error(std::string("character LM run failed: ") +
            (error ? error.localizedDescription.UTF8String : "unknown error"));
    // Core ML writes into the backing; should it hand back another array, read that.
    MLMultiArray* logp = [output featureValueForName:@"logp_all"].multiArrayValue;
    if (!logp || logp.shape.count != 3 || logp.shape[2].unsignedLongValue != vocab ||
        logp.dataType != MLMultiArrayDataTypeFloat16)
        throw std::runtime_error("character LM output does not match its vocabulary");
    const size_t token_stride = static_cast<size_t>(logp.strides[1].integerValue);
    const size_t vocab_stride = static_cast<size_t>(logp.strides[2].integerValue);
    const _Float16* bytes = static_cast<const _Float16*>(logp == f.logp ? model.Output() : logp.dataPointer);
    for (const auto& [node, row] : rows) {
        const _Float16* source = bytes + static_cast<size_t>(node) * token_stride;
        float* target = out + row * vocab;
        if (vocab_stride == 1)
            for (size_t v = 0; v < vocab; ++v) target[v] = static_cast<float>(source[v]);
        else
            for (size_t v = 0; v < vocab; ++v) target[v] = static_cast<float>(source[v * vocab_stride]);
    }
}

std::vector<Ort::Value> CharLmRun(CharLmHandle& h, const std::vector<int64_t>& ids,
    const std::vector<int64_t>& positions, const std::vector<int32_t>& mask,
    int64_t past_length, std::vector<Ort::Value>* past, bool /*want_presents*/,
    Ort::RunOptions& options) {
    if (options.Terminated()) throw std::runtime_error("character LM deadline passed");
    const size_t n = ids.size();
    const size_t width = static_cast<size_t>(past_length) + n;
    if (n == 0 || positions.size() != n || mask.size() != n * width)
        throw std::runtime_error("character LM run has inconsistent inputs");
    const CharLmKeys* store = (past && !past->empty()) ? static_cast<const CharLmKeys*>((*past)[0].store) : nullptr;

    // The chain of every new token: its parent is the token it sees with the
    // highest position (a kept one, or an earlier new one); it must see that
    // parent's whole chain and nothing else.
    auto chains = std::make_shared<std::vector<std::vector<uint32_t>>>(n);
    for (size_t r = 0; r < n; ++r) {
        const int32_t* line = mask.data() + r * width;
        int64_t best_position = -1;
        const std::vector<uint32_t>* parent = nullptr;
        size_t seen = 0;
        for (size_t j = 0; j < static_cast<size_t>(past_length); ++j) {
            if (!line[j]) continue;
            if (!store) throw std::runtime_error("character LM mask names a past it was not given");
            ++seen;
            const auto& chain = store->Chain(j);
            if (CharLmPackedPosition(chain.back()) > best_position) {
                best_position = CharLmPackedPosition(chain.back());
                parent = &chain;
            }
        }
        for (size_t j = 0; j < r; ++j) {
            if (!line[static_cast<size_t>(past_length) + j]) continue;
            ++seen;
            if (positions[j] > best_position) {
                best_position = positions[j];
                parent = &(*chains)[j];
            }
        }
        if (ids[r] < 0 || ids[r] >= h.vocab_size || positions[r] < 0 || positions[r] >= h.block_size ||
            positions[r] <= best_position)
            throw std::runtime_error("character LM run has an invalid token");
        auto& chain = (*chains)[r];
        if (parent) chain = *parent;
        chain.push_back(CharLmPack(ids[r], positions[r]));
        if (seen + 1 != chain.size()) throw std::runtime_error("character LM mask is not a chain");
    }

    // Predictions: consecutive new tokens whose chains together, as a trie,
    // fit the longest function. A chain fits alone: it is at most block_size.
    const size_t vocab = static_cast<size_t>(h.vocab_size);
    auto logp = std::shared_ptr<float[]>(new float[n * vocab]);
    CharLmCoreMlModel& model = *h.model;
    const size_t longest = model.Longest();
    std::vector<uint32_t> tokens;
    std::vector<int32_t> parents;
    std::unordered_map<uint64_t, int32_t> index;
    std::vector<std::pair<int32_t, size_t>> rows;
    auto key = [](int32_t node, uint32_t packed) {
        return (static_cast<uint64_t>(static_cast<uint32_t>(node + 1)) << 32) | packed;
    };
    std::lock_guard<std::mutex> lock(model.mutex());
    for (size_t begin = 0; begin < n;) {
        tokens.clear();
        parents.clear();
        index.clear();
        rows.clear();
        size_t end = begin;
        for (; end < n; ++end) {
            const auto& chain = (*chains)[end];
            size_t depth = 0;
            int32_t node = -1;
            for (; depth < chain.size(); ++depth) {
                const auto found = index.find(key(node, chain[depth]));
                if (found == index.end()) break;
                node = found->second;
            }
            if (chain.size() > longest) throw std::runtime_error("character LM chain is longer than the model");
            if (end > begin && tokens.size() + (chain.size() - depth) > longest) break;
            for (; depth < chain.size(); ++depth) {
                tokens.push_back(chain[depth]);
                parents.push_back(node);
                node = static_cast<int32_t>(tokens.size() - 1);
                index.emplace(key(parents.back(), chain[depth]), node);
            }
            rows.emplace_back(node, end);
        }
        if (options.Terminated()) throw std::runtime_error("character LM deadline passed");
        @autoreleasepool {
            CharLmPredict(model, tokens, parents, rows, vocab, logp.get());
        }
        begin = end;
    }
    if (options.Terminated()) throw std::runtime_error("character LM deadline passed");

    std::vector<Ort::Value> result(2);
    result[0].logp = logp;
    result[0].dims = {1, static_cast<int64_t>(n), static_cast<int64_t>(vocab)};
    result[1].chains = chains;
    return result;
}

// Only a Neural Engine keeps the weights outside the process and runs the model
// in milliseconds. Core ML places it there from 16 cores on (A14, M1 and later).
// An iPhone XS Max (A12, 8 cores) gets a CPU or GPU fallback that unpacks the
// weights into the process, 100 MB to 1.7 GB for the three functions, and takes
// 60 to 600 ms for a run of 64 tokens: a keyboard extension would be killed.
constexpr NSInteger kCharLmMinNeuralEngineCores = 16;
// What a run of the shortest function may take once it is loaded, as a second
// check for what the core count does not catch: an iPhone 15 Pro needs about
// 5 ms and 2 MB, the XS Max fallbacks 60 to 600 ms, or 100 MB and more. The
// load is not counted: compiling for the Neural Engine takes seconds the first
// time.
constexpr double kCharLmCheckMaxMs = 100.0;
constexpr uint64_t kCharLmCheckMaxGrowth = 40ull << 20;

NSInteger CharLmNeuralEngineCores() {
    NSInteger cores = 0;
    for (id<MLComputeDeviceProtocol> device in MLAllComputeDevices())
        if ([(NSObject*)device isKindOfClass:[MLNeuralEngineComputeDevice class]])
            cores = std::max(cores, static_cast<MLNeuralEngineComputeDevice*>(device).totalCoreCount);
    return cores;
}

uint64_t CharLmFootprint() {
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS)
        return 0;
    return info.phys_footprint;
}

// Throws unless this device runs the model on its Neural Engine. Loads only the
// shortest function and runs it twice, so a device that cannot stops early.
// Callers hold the model's mutex and an autorelease pool.
void CharLmCheckDevice(CharLmCoreMlModel& model, size_t vocab) {
    if (model.checked()) return;
    if (!model.explicit_units()) {
        const NSInteger cores = CharLmNeuralEngineCores();
        if (cores < kCharLmMinNeuralEngineCores)
            throw std::runtime_error("character LM needs a Neural Engine of " +
                std::to_string(kCharLmMinNeuralEngineCores) + " cores; this device has " + std::to_string(cores));
    }
    model.Function(model.lengths().front());
    const uint64_t before = CharLmFootprint();
    std::vector<float> row(vocab);
    CharLmPredict(model, {CharLmPack(kCharLmBos, 0)}, {-1}, {{0, 0}}, vocab, row.data());
    const auto started = std::chrono::steady_clock::now();
    CharLmPredict(model, {CharLmPack(kCharLmBos, 0)}, {-1}, {{0, 0}}, vocab, row.data());
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    const uint64_t after = CharLmFootprint();
    const uint64_t grown = after > before ? after - before : 0;
    if (!model.explicit_units() && (ms > kCharLmCheckMaxMs || grown > kCharLmCheckMaxGrowth))
        throw std::runtime_error("character LM does not run on this device's Neural Engine (a run takes " +
            std::to_string(static_cast<int>(ms)) + " ms, the runs added " + std::to_string(grown >> 20) + " MB)");
    model.set_checked();
}

// The architecture of char_lm.onnx (runtime_manifest.json). The algorithms read
// these only to size key stores, which here hold chains.
void CharLmOpenModel(CharLmHandle& h, const std::string& directory) {
    if (@available(macOS 15.0, iOS 18.0, *)) {
    } else {
        throw std::runtime_error("the Core ML character LM needs iOS 18 or macOS 15");
    }
    // A chain packs a token as id << 16 | position.
    if (h.vocab_size > 65536 || h.block_size > 65536)
        throw std::runtime_error("character LM is too large for the Core ML runtime's chains");
    h.layers = 11;
    h.heads = 16;
    h.head_dim = 64;
    const std::string path = directory + "/char_lm.mlmodelc";
    if (!std::filesystem::is_directory(path)) throw std::runtime_error("missing " + path);
    const std::string key = CharLmSessionKey(path);
    h.model = CharLmSessions()[key].lock();
    if (!h.model) {
        h.model = std::make_shared<CharLmCoreMlModel>(path);
        CharLmSessions()[key] = h.model;
    }
    // The first load of a function compiles it for the Neural Engine (seconds,
    // once per model file; the system keeps the result), later loads take tens
    // of milliseconds. Doing it here keeps that off the first keystrokes: the
    // hosts open the model on a loader thread.
    std::lock_guard<std::mutex> lock(h.model->mutex());
    @autoreleasepool {
        CharLmCheckDevice(*h.model, static_cast<size_t>(h.vocab_size));
        for (int length : h.model->lengths()) {
            CharLmFunction& f = h.model->Function(length);
            if (static_cast<int64_t>(f.logp.shape[2].integerValue) != h.vocab_size)
                throw std::runtime_error("character LM model does not match its vocabulary");
        }
    }
}
}  // namespace
