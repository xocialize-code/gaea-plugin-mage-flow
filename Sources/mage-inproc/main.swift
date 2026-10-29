import Foundation
import MagePlugin
import MLXMageFlow
import MLXServeCore
import MLXToolKit

// The in-process reference for the plugin: one Mage-Flow lane loaded by MLXServeEngine in this process, with the lane
// configuration the worker uses (MagePlugin) and the request it would build. A cold run then a warm one; the first
// image is written to --out, and one JSON line of timings is printed. Not part of the plugin bundle.
//
//   mage-inproc [--model mage-flow | mage-flow-turbo | mage-flow-edit | mage-flow-edit-turbo | mage-flow-edit-base]
//               [--lane bf16 | int8 | int4] [--prompt <text>] [--negative <text>] [--size 1024] [--steps N]
//               [--guidance G] [--seed 42] [--image <png> ...] [--models-root <dir>] [--out <png>] [--runs 2]
//
// An edit model takes --image (repeatable, 1–3) with the prompt as the instruction.

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func options(_ name: String) -> [String] {
    var values: [String] = []
    while let value = option(name) { values.append(value) }
    return values
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let started = ContinuousClock.now
guard let model = Model(rawValue: option("--model") ?? "mage-flow-turbo") else {
    FileHandle.standardError.write(Data("unknown --model; one of \(Model.allCases.map(\.rawValue))\n".utf8))
    exit(2)
}
let quant = Quant(rawValue: option("--lane") ?? model.defaultQuant.rawValue) ?? model.defaultQuant
let prompt = option("--prompt") ?? "a lighthouse on a rocky coast at dusk, photorealistic"
let negative = option("--negative")
let side = Int(option("--size") ?? "") ?? 1024
let steps = Int(option("--steps") ?? "") ?? model.defaultSteps
let guidance = model.distilled ? 1 : Double(option("--guidance") ?? "") ?? model.defaultGuidance
let seed = UInt64(option("--seed") ?? "") ?? 42
let imagePaths = options("--image")
let outPath = option("--out")
let runs = Int(option("--runs") ?? "") ?? 2
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)

var result: [String: Any] = ["model": model.rawValue, "lane": quant.rawValue, "size": side, "steps": steps,
                             "guidance": guidance, "seed": seed, "references": imagePaths.count]

// The budget Gaea sends a worker on a large Mac (wiresWeights off, the automatic pool cap).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(model.rawValue)
let registration = model.isEdit ? MageFlowEditPackage.registration : MageFlowT2IPackage.registration
_ = try await engine.register(registration, configuration: model.configuration(quant: quant), id: id)

var clock = ContinuousClock.now
_ = try await engine.prepare(model.isEdit ? .imageEdit : .textToImage, package: id)
result["prepare_s"] = seconds(since: clock)

let images = try imagePaths.map { path in
    Image(format: path.lowercased().hasSuffix(".png") ? .png : .jpeg, data: try Data(contentsOf: URL(fileURLWithPath: path)))
}
// The worker's request, field for field (MagePlugin's generate and edit): a distilled model sends no negative prompt.
let request: any CapabilityRequest = model.isEdit
    ? IEditRequest(images: images, prompt: prompt, negativePrompt: model.distilled ? nil : negative, width: side, height: side,
                   steps: steps, guidanceScale: guidance, seed: seed, mode: nil, metaData: [:])
    : T2IRequest(prompt: prompt, negativePrompt: model.distilled ? nil : negative, width: side, height: side, steps: steps,
                 guidanceScale: guidance, seed: seed)

for run in 1...max(1, runs) {
    clock = ContinuousClock.now
    let response = try await engine.run(request, package: id)
    result["run\(run)_s"] = seconds(since: clock)
    let image = (response as? T2IResponse)?.image ?? (response as? IEditResponse)?.image
    if run == 1, let image, let outPath { try image.data.write(to: URL(fileURLWithPath: outPath)) }
}
result["cold_s"] = seconds(since: started) - (runs > 1 ? result["run\(runs)_s"] as! Double : 0)

let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
