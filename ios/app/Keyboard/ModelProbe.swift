import CoreML
import Foundation

/// Times the Core ML character LM function by function, without the engine:
/// load, the first prediction, the median of the next seven, and the footprint
/// after each. The keyboard and the host app's self test both run it
/// (mode=mltest), so a phone without the keyboards enabled can be measured too.
enum ModelProbe {
  /// units: ne (CPU and Neural Engine, the engine's choice), cpu, gpu or all.
  static func run(url: URL, lengths: [Int], units: String, label: String) -> String {
    var rows: [String] = []
    var held: [MLModel] = []  // memory adds up as in the engine, which keeps every function
    let before = EngineBridge.footprint()
    for length in lengths {
      guard #available(iOS 18.0, *) else {
        rows.append("{\"length\":\(length),\"error\":\"needs iOS 18\"}")
        break
      }
      let configuration = MLModelConfiguration()
      switch units {
      case "gpu": configuration.computeUnits = .cpuAndGPU
      case "cpu": configuration.computeUnits = .cpuOnly
      case "all": configuration.computeUnits = .all
      default: configuration.computeUnits = .cpuAndNeuralEngine
      }
      configuration.functionName = "len\(length)"
      do {
        let started = CFAbsoluteTimeGetCurrent()
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let load = CFAbsoluteTimeGetCurrent() - started
        let loaded = EngineBridge.footprint()
        let count = NSNumber(value: length)
        let ids = try MLMultiArray(shape: [1, count], dataType: .int32)
        let positions = try MLMultiArray(shape: [1, count], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, 1, count, count], dataType: .float16)
        let idValues = ids.dataPointer.bindMemory(to: Int32.self, capacity: length)
        let placeValues = positions.dataPointer.bindMemory(to: Int32.self, capacity: length)
        for i in 0..<length {
          idValues[i] = Int32(2 + (i * 37) % 12000)
          placeValues[i] = Int32(min(i, 255))
        }
        idValues[0] = 0
        let maskValues = mask.dataPointer.bindMemory(to: UInt16.self, capacity: length * length)
        let open = Float16(0).bitPattern
        let closed = Float16(-30000).bitPattern
        let rowStride = mask.strides[2].intValue
        for r in 0..<length {
          for c in 0..<length { maskValues[r * rowStride + c] = c <= r ? open : closed }
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
          "ids": ids, "positions": positions, "mask": mask,
        ])
        let firstStarted = CFAbsoluteTimeGetCurrent()
        var output = try model.prediction(from: input)
        let first = (CFAbsoluteTimeGetCurrent() - firstStarted) * 1000
        var times: [Double] = []
        for _ in 0..<7 {
          let start = CFAbsoluteTimeGetCurrent()
          output = try model.prediction(from: input)
          times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        times.sort()
        // Matches the Mac's numbers when the model computes what the Mac computes.
        var checksum = 0.0
        if let logp = output.featureValue(for: "logp_all")?.multiArrayValue {
          for i in 0..<(min(length, 64) - 1) {
            let next = NSNumber(value: Int(idValues[i + 1]))
            checksum += logp[[0, NSNumber(value: i), next]].doubleValue
          }
        }
        held.append(model)
        rows.append(
          "{\"length\":\(length),\"load_s\":\(String(format: "%.2f", load)),"
            + "\"after_load_mb\":\(megabytes(loaded)),"
            + "\"after_predict_mb\":\(megabytes(EngineBridge.footprint())),"
            + "\"first_ms\":\(String(format: "%.1f", first)),"
            + "\"median_ms\":\(String(format: "%.1f", times[times.count / 2])),"
            + "\"best_ms\":\(String(format: "%.1f", times[0])),"
            + "\"checksum\":\(String(format: "%.3f", checksum))}")
      } catch {
        rows.append("{\"length\":\(length),\"error\":\"\(error.localizedDescription)\"}")
      }
    }
    let json =
      "{\"label\":\"\(label)\",\"units\":\"\(units)\","
      + "\"before_mb\":\(megabytes(before)),\"end_mb\":\(megabytes(EngineBridge.footprint())),"
      + "\"peak_mb\":\(megabytes(EngineBridge.footprintPeak())),"
      + "\"available_mb\":\(megabytes(EngineBridge.available())),\"functions\":[\(rows.joined(separator: ","))]}"
    held.removeAll()
    return json
  }

  /// Where Core ML would run each operation of one function (MLComputePlan):
  /// operations and estimated cost by preferred device, the operators kept off
  /// the Neural Engine, and what working this out costs.
  static func plan(url: URL, length: Int, units: String, label: String) -> String {
    guard #available(iOS 18.0, *) else { return "{\"label\":\"\(label)\",\"error\":\"needs iOS 18\"}" }
    let configuration = MLModelConfiguration()
    switch units {
    case "gpu": configuration.computeUnits = .cpuAndGPU
    case "cpu": configuration.computeUnits = .cpuOnly
    case "all": configuration.computeUnits = .all
    default: configuration.computeUnits = .cpuAndNeuralEngine
    }
    // MLComputePlan refuses functionName on a multifunction model: it plans
    // every function, and the one asked for is looked up below.
    let before = EngineBridge.footprint()
    let started = CFAbsoluteTimeGetCurrent()
    final class Box: @unchecked Sendable { var plan: MLComputePlan?; var error: Error? }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      do { box.plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration) }
      catch { box.error = error }
      done.signal()
    }
    done.wait()
    let seconds = CFAbsoluteTimeGetCurrent() - started
    guard let plan = box.plan else {
      return "{\"label\":\"\(label)\",\"error\":\"\(box.error?.localizedDescription ?? "no plan")\"}"
    }
    var counts: [String: Int] = [:]
    var costs: [String: Double] = [:]
    var offEngine: [String: Int] = [:]
    if case .program(let program) = plan.modelStructure, let function = program.functions["len\(length)"] {
      for operation in function.block.operations {
        guard let usage = plan.deviceUsage(for: operation) else { continue }
        let device: String
        switch usage.preferred {
        case .cpu: device = "cpu"
        case .gpu: device = "gpu"
        case .neuralEngine: device = "ne"
        @unknown default: device = "other"
        }
        counts[device, default: 0] += 1
        costs[device, default: 0] += plan.estimatedCost(of: operation)?.weight ?? 0
        if device != "ne" { offEngine[operation.operatorName + "@" + device, default: 0] += 1 }
      }
    }
    let total = max(costs.values.reduce(0, +), 1e-9)
    let countText = counts.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
    let costText = costs.sorted { $0.key < $1.key }
      .map { "\"\($0.key)\":\(String(format: "%.3f", $0.value / total))" }.joined(separator: ",")
    let offText = offEngine.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }
      .joined(separator: ",")
    return "{\"label\":\"\(label)\",\"units\":\"\(units)\",\"length\":\(length),"
      + "\"plan_s\":\(String(format: "%.2f", seconds)),\"before_mb\":\(megabytes(before)),"
      + "\"after_mb\":\(megabytes(EngineBridge.footprint())),\"peak_mb\":\(megabytes(EngineBridge.footprintPeak())),"
      + "\"operations\":{\(countText)},\"cost_share\":{\(costText)},\"off_engine\":{\(offText)}}"
  }

  private static func megabytes(_ value: UInt64) -> String {
    String(format: "%.1f", Double(value) / 1_048_576)
  }
}
