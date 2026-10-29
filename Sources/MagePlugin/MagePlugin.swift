import Foundation
import GaeaPluginKit
import GaeaProtocol
import ImageIO
import MLXMageFlow
import MLXToolKit

// gaea-plugin-mage-flow: Microsoft's Mage-Flow family (MIT weights, MIT port) as a Gaea research plugin, on
// mage-flow-swift through MLXServeEngine (Gaea AB-T-0374).
//
// Five checkpoints, as mlx-image-runtime's catalog serves them:
// - mage-flow (RL-aligned, 20 steps, CFG 5) and mage-flow-turbo (distilled, 4 steps, no CFG): square text-to-image;
// - mage-flow-edit (RL-aligned, 20 steps), mage-flow-edit-turbo (4 steps, int8) and mage-flow-edit-base (30 steps):
//   square instruction editing from 1–3 references.
//
// Every offer is named-only: the normalizer never picks a Mage model by default, and a request runs one only by naming
// it. Each model has lanes, one per DiT quant, with the package's footprints; the default is the catalog's quant.
// Microsoft's content filter is off, as in the catalog (AB-D-0122). Weights come from the models root Gaea sends in
// configure; the engine materializes a missing snapshot.

/// The validated envelope: square, 512–2048 px, multiples of 16; the footprints were measured at 1024², the catalog's cap.
public let minSide = 512, maxSide = 1024, grid = 16, maxReferences = 3

public enum Model: String, CaseIterable, Sendable {
    case flow = "mage-flow"
    case turbo = "mage-flow-turbo"
    case edit = "mage-flow-edit"
    case editTurbo = "mage-flow-edit-turbo"
    case editBase = "mage-flow-edit-base"

    public var variant: MageFlowVariant {
        switch self {
        case .flow: .flow
        case .turbo: .turbo
        case .edit: .edit
        case .editTurbo: .editTurbo
        case .editBase: .editBase
        }
    }

    public var title: String {
        switch self {
        case .flow: "Mage-Flow"
        case .turbo: "Mage-Flow Turbo"
        case .edit: "Mage-Flow Edit"
        case .editTurbo: "Mage-Flow Edit Turbo"
        case .editBase: "Mage-Flow Edit Base"
        }
    }

    public var isEdit: Bool { variant.isEdit }
    public var distilled: Bool { self == .turbo || self == .editTurbo }
    public var defaultSteps: Int { variant.defaultSteps }
    public var defaultGuidance: Double { Double(variant.defaultGuidance) }

    /// The catalog's quant: bf16, except Edit Turbo's int8 DiT (the removal gate measured it that way, AB-R-0464).
    public var defaultQuant: Quant { self == .editTurbo ? .int8 : .bf16 }

    /// The lanes, default first. Edit Turbo has no bf16 lane: its components are fetched without the bf16 DiT.
    public var quants: [Quant] { self == .editTurbo ? [.int8, .int4] : [.bf16, .int8, .int4] }

    /// The package configuration for one lane; mage-inproc builds the same one.
    public func configuration(quant: Quant) -> MageFlowConfiguration {
        MageFlowConfiguration(variant: variant, quant: quant, bypassContentFilter: true)
    }
}

/// The MES size a job asks for (`size`, or `aspect` with `megapixels`, Image profile §2), else `fallback`.
func requestedSize(_ job: Job, fallback: (Int, Int)) throws -> (Int, Int) {
    if let size = job.param("size") {
        guard let w = size["width"]?.intValue, let h = size["height"]?.intValue, w > 0, h > 0 else {
            throw GPPError(.invalidRequest, "size is {width, height} in pixels.")
        }
        return (w, h)
    }
    if let aspect = job.param("aspect")?.stringValue {
        let parts = aspect.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { throw GPPError(.invalidRequest, "aspect is W:H, e.g. 16:9.") }
        let pixels = (job.param("megapixels")?.doubleValue ?? 1.0) * 1_000_000
        let height = (pixels * parts[1] / parts[0]).squareRoot()
        return (Int(height * parts[0] / parts[1]), Int(height))
    }
    return fallback
}

/// Mage draws squares: the side keeps the asked area, clamped to 512–1024 and floored to a multiple of 16. A change is
/// reported as `size_snapped`.
public func squared(_ size: (Int, Int)) -> (side: Int, warning: Warning?) {
    let area = (Double(size.0) * Double(size.1)).squareRoot()
    let side = min(maxSide, max(minSide, Int(area))) / grid * grid
    let warning = (side, side) == size ? nil : Warning(
        code: "size_snapped", message: "Drew \(side)×\(side) for \(size.0)×\(size.1): Mage-Flow draws squares of 512–1024 px, "
            + "in multiples of 16.",
        param: "size")
    return (side, warning)
}

/// The run's settings shared by generate and edit: steps, guidance, seed, and the warnings for what a model ignores.
struct Shared {
    var steps: Int
    var guidance: Double
    var negative: String?
    var seed: UInt64
    var count: Int
    var warnings: [Warning] = []

    /// `counted`: image.generate takes MES `count`; image.edit has one output and no count.
    init(_ job: Job, model: Model, counted: Bool = true) throws {
        steps = job.param("x-mage.steps")?.intValue ?? model.defaultSteps
        guard (1...100).contains(steps) else { throw GPPError(.invalidRequest, "x-mage.steps is 1–100.") }
        guidance = model.distilled ? 1 : job.param("x-mage.guidance")?.doubleValue ?? model.defaultGuidance
        guard (1...20).contains(guidance) else { throw GPPError(.invalidRequest, "x-mage.guidance is 1–20.") }
        count = counted ? job.param("count")?.intValue ?? 1 : 1
        guard (1...8).contains(count) else { throw GPPError(.invalidRequest, "count is 1–8.") }
        let negative = job.param("negative_prompt")?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if model.distilled, negative != nil {
            warnings.append(Warning(code: "negative_prompt_ignored",
                                    message: "\(model.title) is distilled to run without CFG, so a negative prompt does nothing.",
                                    param: "negative_prompt"))
        }
        self.negative = model.distilled ? nil : negative
        if job.param("prompt_enhance")?.stringValue == "on" {
            warnings.append(Warning(code: "prompt_enhance_ignored", message: "This plugin doesn't rewrite prompts; Gaea's enhancer does.",
                                    param: "prompt_enhance"))
        }
        // Image profile §2: a request without a seed still gets one, reported in effective.
        seed = job.seed ?? UInt64.random(in: 0..<(1 << 31))
    }

    func effective(side: Int, model: Model, counted: Bool = true) -> [String: JSONValue] {
        var values: [String: JSONValue] = [
            "size": ["width": .int(Int64(side)), "height": .int(Int64(side))],
            "seed": .int(Int64(seed)), "x-mage.steps": .int(Int64(steps)),
        ]
        if counted { values["count"] = .int(Int64(count)) }
        if !model.distilled { values["x-mage.guidance"] = .double(guidance) }
        if let negative { values["negative_prompt"] = .string(negative) }
        return values
    }
}

/// MES image.generate: one engine call per image, each with seed + i.
func generate(_ model: Model) -> EngineOperation {
    EngineOperation("image.generate", outputNames: ["image": "images"]) { job in
        guard let prompt = try job.text("prompt"), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GPPError(.invalidRequest, "image.generate needs a prompt.")
        }
        let size = squared(try requestedSize(job, fallback: (1024, 1024)))
        var shared = try Shared(job, model: model)
        if let warning = size.warning { shared.warnings.insert(warning, at: 0) }
        let effective = shared.effective(side: size.side, model: model)
        return (0..<shared.count).map { i in
            EngineCall(T2IRequest(prompt: prompt, negativePrompt: shared.negative, width: size.side, height: size.side,
                                  steps: shared.steps, guidanceScale: shared.guidance, seed: shared.seed + UInt64(i)),
                       effective: effective, warnings: shared.warnings)
        }
    }
}

/// MES image.edit: 1–3 references in instruction order ("the cat from image 1 on the sofa from image 2"), drawn at a
/// square from the first image's area (Image profile §3). One output.
///
/// The normalizer's own calls by name also reach it: `mode: tiles` edits each image alone with the same instruction and
/// returns them stacked (the creative upscale), and `initSigma` starts from Image 1 noised to that sigma.
func edit(_ model: Model) -> EngineOperation {
    EngineOperation("image.edit", outputNames: ["image": "image"]) { job in
        guard let instruction = try job.text("instruction") ?? job.text("prompt"), !instruction.isEmpty else {
            throw GPPError(.invalidRequest, "image.edit needs an instruction.")
        }
        let tiles = job.param("mode")?.stringValue == MageFlowModes.tiles.rawValue
        let references = job.inputs["images"] ?? job.inputs["image"] ?? []
        let most = tiles ? MageFlowModes.maxTiles : maxReferences
        guard (1...most).contains(references.count) else {
            throw GPPError(.invalidRequest, "image.edit takes 1–\(most) images; got \(references.count).", detail: ["param": "images"])
        }
        guard let source = CGImageSourceCreateWithURL(references[0] as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let inputWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let inputHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw GPPError(.invalidRequest, "image.edit needs readable PNG or JPEG images.")
        }
        let size = squared(try requestedSize(job, fallback: (inputWidth, inputHeight)))
        var shared = try Shared(job, model: model, counted: false)
        if let warning = size.warning { shared.warnings.insert(warning, at: 0) }
        if job.param("strength") != nil {
            shared.warnings.append(Warning(code: "param_ignored",
                                           message: "Mage-Flow edits by reference conditioning from noise, so strength does nothing.",
                                           param: "strength"))
        }
        var metaData: MetaData = [:]
        var effective = shared.effective(side: size.side, model: model, counted: false)
        if let sigma = job.param("initSigma")?.doubleValue {
            guard sigma > 0, sigma <= 1 else { throw GPPError(.invalidRequest, "initSigma is in (0, 1].") }
            metaData[MageFlowMetaKeys.initSigmaKey] = .double(sigma)
            effective["initSigma"] = .double(sigma)
        }
        if tiles { effective["mode"] = .string(MageFlowModes.tiles.rawValue) }
        let images = try references.indices.map { try job.image(job.inputs["images"] == nil ? "image" : "images", index: $0) }
        return [EngineCall(IEditRequest(images: images, prompt: instruction, negativePrompt: shared.negative,
                                        width: size.side, height: size.side, steps: shared.steps,
                                        guidanceScale: shared.guidance, seed: shared.seed,
                                        mode: tiles ? MageFlowModes.tiles : nil, metaData: metaData),
                           effective: effective, warnings: shared.warnings)]
    }
}

public func lanes(_ model: Model) -> [LaneDefinition] {
    model.quants.map { quant in
        LaneDefinition(id: quant.rawValue, default: quant == model.defaultQuant, configuration: model.configuration(quant: quant))
    }
}

let mit: JSONValue = ["spdx": "MIT", "commercial_use": true,
                      "terms_url": "https://huggingface.co/mage-flow-community/Mage-Flow/blob/main/LICENSE"]
let limits = PluginManifest.Limits(maxPixels: maxSide * maxSide, minSide: minSide, maxSide: maxSide, sizeMultiple: grid)
let editLimits = PluginManifest.Limits(maxPixels: maxSide * maxSide, minSide: minSide, maxSide: maxSide, sizeMultiple: grid,
                                       maxImages: maxReferences)

func params(_ model: Model) -> JSONValue {
    var properties: [String: JSONValue] = [
        "x-mage.steps": ["type": "integer", "minimum": 1, "maximum": 100, "default": .int(Int64(model.defaultSteps)),
                         "description": .string(model.distilled ? "Denoising steps. \(model.title) is distilled for 4."
                             : "Denoising steps; more is slower and finer."),
                         "x-mes-ui": ["widget": "slider", "label": "Steps", "advanced": true]],
    ]
    if !model.distilled {
        properties["x-mage.guidance"] = [
            "type": "number", "minimum": 1, "maximum": 20, "default": .double(model.defaultGuidance),
            "description": "Classifier-free guidance: how strongly the prompt (and against the negative prompt) steers. 1 turns CFG off.",
            "x-mes-ui": ["widget": "slider", "label": "Guidance", "advanced": true],
        ]
    }
    return ["type": "object", "properties": .object(properties), "additionalProperties": false]
}

func offerModel(_ model: Model) -> JSONValue {
    let tiers: JSONValue = switch model {
    case .turbo, .editTurbo: ["draft", "standard"]
    case .flow, .edit: ["standard", "best"]
    case .editBase: ["best"]
    }
    let notes: String = switch model {
    case .flow: "RL-aligned text-to-image, 20 steps with CFG 5. Square only, 512–1024 px."
    case .turbo: "Distilled to 4 steps without CFG: negative prompts do nothing. Square only, 512–1024 px."
    case .edit: "RL-aligned instruction editing, 20 steps with CFG 5: 1–3 images, named in the instruction in order. Square output."
    case .editTurbo: "Instruction editing distilled to 4 steps (int8 DiT): 1–3 images, named in the instruction in order. "
        + "The normalizer's remover for erase at best and the creative upscale's editor, when named."
    case .editBase: "The quality edit checkpoint, 30 steps with CFG 5: 1–3 images. Square output."
    }
    return [
        "id": .string(model.rawValue), "title": .string(model.title), "license": mit,
        "memory_class": "large", "speed_class": .string(model.distilled ? "fast" : "slow"),
        "quality_tiers": tiers, "named_only": true,
        "notes": .string("Research plugin, named-only: runs only when a request names it. " + notes),
    ]
}

public let magePlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.mage-flow",
    version: "0.1.0",
    minGaea: "0.2.0",
    team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize/gaea-plugin-mage-flow",
    title: "Mage-Flow",
    summary: "Microsoft's Mage-Flow (MIT): a 4.1B native-resolution NR-MMDiT with Qwen3-VL-4B conditioning. Text-to-image "
        + "(RL-aligned and the 4-step Turbo) and square instruction editing from up to 3 references (RL, Turbo and Base). "
        + "A research plugin: every model is named-only.",
    license: "Apache-2.0",
    executable: "gaea-mage-flow-worker",
    models: Model.allCases.map { model in
        model.isEdit
            ? .engine(MageFlowEditPackage.self, id: model.rawValue, title: model.title, lanes: lanes(model), operations: [edit(model)])
            : .engine(MageFlowT2IPackage.self, id: model.rawValue, title: model.title, lanes: lanes(model),
                      operations: [generate(model)])
    },
    offers: Model.allCases.map { model in
        model.isEdit
            ? PluginManifest.Offer(operation: "image.edit", profile: "image", model: offerModel(model), params: params(model),
                                   limits: editLimits)
            : PluginManifest.Offer(operation: "image.generate", profile: "image", model: offerModel(model), params: params(model),
                                   defaults: ["count": 1], limits: limits)
    })
