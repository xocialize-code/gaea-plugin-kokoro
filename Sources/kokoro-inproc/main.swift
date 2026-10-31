import Foundation
import KokoroPlugin
import MLXKokoroTTS
import MLXServeCore
import MLXToolKit

// The in-process reference for the plugin: Kokoro-82M loaded by MLXServeEngine in this process, with the lane
// configuration the worker uses and the same text plan (KokoroPlugin), drawn piece by piece as the worker draws it.
// A cold run then a warm one; the WAV is written to --out, and one JSON line of timings is printed. Not part of the
// plugin bundle.
//
//   kokoro-inproc [--text <text> | --text-file <path>] [--voice af_heart] [--seed 42] [--models-root <dir>] [--out <wav>]
//                 [--once]

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let started = ContinuousClock.now
let text = try option("--text-file").map { try String(contentsOfFile: $0, encoding: .utf8) }
    ?? option("--text") ?? "Gaea speaks. This sentence came from a signed plugin, over its own protocol."
let voice = option("--voice") ?? defaultVoice
let seed = UInt64(option("--seed") ?? "") ?? 42
let once = args.contains("--once")
let outPath = option("--out")
let modelsRoot = URL(fileURLWithPath: option("--models-root")
                     ?? NSHomeDirectory() + "/Library/Application Support/MLXEngine/Models", isDirectory: true)

// The budget Gaea sends a worker on a large Mac (wiresWeights off).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 64_000_000_000, wiresWeights: false))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(kokoroModelID)
_ = try await engine.register(KokoroTTSPackage.registration, configuration: kokoroLanes[0].configuration, id: id)
var clock = ContinuousClock.now
_ = try await engine.prepare(.tts, package: id)
var result: [String: Any] = ["model": kokoroModelID, "voice": voice, "seed": seed, "prepare_s": seconds(since: clock)]

let plan = try speakPlan(text: text, voice: voice)
result["pieces"] = plan.pieces.count
func draw() async throws -> Data {
    try await speak(plan, seed: seed, draw: { words in
        let response = try await engine.run(TTSRequest(text: words, voice: VoiceSelector(.named(voice))), package: id)
        guard let tts = response as? TTSResponse else { throw PackageError.unsupportedCapability(.tts) }
        return tts.audio.data
    })
}
clock = ContinuousClock.now
let pcm = try await draw()
result["run1_s"] = seconds(since: clock)
result["audio_s"] = Double(pcm.count / 2) / Double(sampleRate)
if !once {
    clock = ContinuousClock.now
    let again = try await draw()
    result["run2_s"] = seconds(since: clock)
    result["deterministic"] = again == pcm
}
if let outPath { try wav16(pcm).write(to: URL(fileURLWithPath: outPath)) }
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
result["max_rss_gb"] = Double(usage.ru_maxrss) / 1e9
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
