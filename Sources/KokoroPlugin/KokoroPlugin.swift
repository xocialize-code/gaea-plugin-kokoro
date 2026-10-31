import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLX
import MLXKokoroTTS
import MLXToolKit

// gaea-plugin-kokoro: hexgrad's Kokoro-82M (Apache-2.0 weights; the MLX port, mlx-kokoro-tts-swift, is MIT) on MES
// audio.speak (Audio 0.1, media-engine-spec v0.7.0, Gaea AB-T-0393).
//
// - **Voices.** The 28 English preset voices the snapshot ships (American a*, British b*), af_heart the default. Kokoro
//   doesn't clone, so the offer declares no `voice_ref`; MES refuses one before it reaches the worker.
// - **Text.** The package draws one forward pass of at most 512 phonemes, so the worker plans the text: it splits it at
//   sentence ends (and, in a long sentence, at the last comma or space) into pieces of at most `maxPieceChars`, and
//   draws each in turn. `[pause Ns]` (and a bare `[pause]`, half a second) is silence between pieces (Audio §2.2), the
//   one cue the offer lists; MESKit removes any other with `cue_unsupported` before the run.
// - **Streaming.** Each piece is sent as soon as it's drawn, as the package's own 16-bit samples, which Gaea passes to
//   a `pcm_s16le` client untouched: the stream is the batch WAV, byte for byte.
// - **Seeds.** Kokoro's sine source draws its phase and noise from MLX's random state, so the worker seeds that state
//   with the job's seed before the first piece (MES Audio §1.6: a request without one still gets one, reported in
//   `effective.seed`). The same seed and text give the same samples, here and in kokoro-inproc.

public let kokoroModelID = "kokoro-82m"
public let sampleRate = 24000
/// The most characters one forward pass is given: well inside the package's 512-phoneme window.
public let maxPieceChars = 300
public let maxTextChars = 4000
/// A bare `[pause]`.
public let defaultPauseSeconds = 0.5
public let maxPauseSeconds = 10.0

/// The English voices in the Kokoro-82M snapshot, as MES preset voices (Base §6.5).
public let kokoroVoices: [(id: String, title: String, tags: [String])] = {
    let american = ["alloy", "aoede", "bella", "heart", "jessica", "kore", "nicole", "nova", "river", "sarah", "sky"]
    let americanMale = ["adam", "echo", "eric", "fenrir", "liam", "michael", "onyx", "puck", "santa"]
    let british = ["alice", "emma", "isabella", "lily"]
    let britishMale = ["daniel", "fable", "george", "lewis"]
    func voices(_ prefix: String, _ names: [String], _ tags: [String]) -> [(String, String, [String])] {
        names.map { ("\(prefix)_\($0)", $0.capitalized, tags) }
    }
    return voices("af", american, ["female", "american"]) + voices("am", americanMale, ["male", "american"])
        + voices("bf", british, ["female", "british"]) + voices("bm", britishMale, ["male", "british"])
}()
public let defaultVoice = KokoroVoice.default.id

/// A voice's language: American voices speak en-US, British ones en-GB.
public func language(_ voice: String) -> String { voice.hasPrefix("b") ? "en-GB" : "en-US" }

// MARK: - The text plan

/// One piece of the plan: words for a forward pass, or silence.
public enum Piece: Sendable, Equatable {
    case words(String)
    case pause(Double)
}

/// The text as pieces (Audio §2.2's cue syntax: `[pause Ns]`, `[pause]`, and `\[` for a literal bracket). Other
/// bracketed text stays words.
public func plan(_ text: String) throws -> [Piece] {
    var pieces: [Piece] = []
    var buffer = ""
    func flush() {
        let words = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { pieces += split(words).map(Piece.words) }
        buffer = ""
    }
    var i = text.startIndex
    while i < text.endIndex {
        let c = text[i]
        if c == "\\", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "[" {
            buffer.append("[")
            i = text.index(i, offsetBy: 2)
            continue
        }
        if c == "[", let close = text[i...].firstIndex(of: "]"),
           let m = text[text.index(after: i)..<close].wholeMatch(of: /pause(?: ([0-9]+(?:\.[0-9]+)?)s)?/) {
            let seconds = m.1.flatMap { Double($0) } ?? defaultPauseSeconds
            guard seconds <= maxPauseSeconds else {
                throw GPPError(.invalidRequest, "A pause is at most \(Int(maxPauseSeconds)) s.", detail: ["param": "text"])
            }
            flush()
            if seconds > 0 { pieces.append(.pause(seconds)) }
            i = text.index(after: close)
            continue
        }
        buffer.append(c)
        i = text.index(after: i)
    }
    flush()
    return pieces
}

/// Words cut into sentences of at most `maxPieceChars`: at a sentence end, else at the last comma, semicolon or
/// space before the limit.
public func split(_ words: String) -> [String] {
    var sentences: [String] = []
    var current = ""
    for c in words {
        current.append(c)
        if ".!?".contains(c) || c.isNewline {
            let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            current = ""
        }
    }
    let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !rest.isEmpty { sentences.append(rest) }
    // A sentence end inside the merged run joins short sentences back up to the limit, so a pass isn't wasted on "Hi."
    var merged: [String] = []
    for s in sentences.flatMap(cut) {
        if let last = merged.last, last.count + 1 + s.count <= maxPieceChars { merged[merged.count - 1] = last + " " + s } else { merged.append(s) }
    }
    return merged
}

func cut(_ sentence: String) -> [String] {
    var out: [String] = []
    var s = Substring(sentence)
    while s.count > maxPieceChars {
        let window = s.prefix(maxPieceChars)
        let at = window.lastIndex(where: { ",;:".contains($0) }).map { s.index(after: $0) }
            ?? window.lastIndex(of: " ") ?? window.endIndex
        out.append(s[..<at].trimmingCharacters(in: .whitespaces))
        s = s[at...].drop(while: { $0 == " " })
    }
    if !s.isEmpty { out.append(String(s)) }
    return out.filter { !$0.isEmpty }
}

// MARK: - WAV

/// The 16-bit PCM inside one of the package's WAVs (its `encodeWAV16`: a 44-byte header, mono, 24 kHz).
public func pcm16(_ wav: Data) throws -> Data {
    guard wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8), wav[wav.startIndex + 8..<wav.startIndex + 12] == Data("WAVE".utf8),
          wav[wav.startIndex + 36..<wav.startIndex + 40] == Data("data".utf8) else {
        throw GPPError(.modelError, "Kokoro returned audio that isn't its usual 16-bit WAV.")
    }
    return wav.subdata(in: (wav.startIndex + 44)..<wav.endIndex)
}

/// Silence: `seconds` of 16-bit zeros.
public func silence(_ seconds: Double) -> Data { Data(count: Int((seconds * Double(sampleRate)).rounded()) * 2) }

/// A mono 16-bit WAV of `pcm` at Kokoro's rate.
public func wav16(_ pcm: Data) -> Data {
    var out = Data(capacity: 44 + pcm.count)
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); out.append(contentsOf: Array("WAVE".utf8))
    out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    out.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
    out.append(pcm)
    return out
}

// MARK: - The operation

/// What a speak job asks: the text's plan and the voice, validated.
public struct SpeakPlan: Sendable {
    public var pieces: [Piece]
    public var voice: String
    public var characters: Int
}

public func speakPlan(text: String?, voice: String?) throws -> SpeakPlan {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw GPPError(.invalidRequest, "audio.speak needs text.", detail: ["param": "text"])
    }
    guard text.count <= maxTextChars else {
        throw GPPError(.invalidRequest, "Kokoro speaks at most \(maxTextChars) characters at a time.", detail: ["param": "text"])
    }
    let voice = voice ?? defaultVoice
    guard kokoroVoices.contains(where: { $0.id == voice }) else {
        throw GPPError(.invalidRequest, "Kokoro has no voice \(voice).", detail: ["param": "voice"])
    }
    let pieces = try plan(text)
    guard pieces.contains(where: { if case .words = $0 { true } else { false } }) else {
        throw GPPError(.invalidRequest, "audio.speak needs words, not only pauses.", detail: ["param": "text"])
    }
    return SpeakPlan(pieces: pieces, voice: voice, characters: text.count)
}

/// Draws the plan piece by piece with `draw`, handing each piece's 16-bit samples to `emit` as soon as it's made (the
/// last with `final`). Returns all the samples, in order.
public func speak(_ plan: SpeakPlan, seed: UInt64, draw: (String) async throws -> Data,
                  emit: ((Data, Bool) throws -> Void)? = nil) async throws -> Data {
    MLXRandom.seed(seed)
    var all = Data()
    for (i, piece) in plan.pieces.enumerated() {
        try Task.checkCancellation()
        let pcm: Data
        switch piece {
        case .words(let words): pcm = try pcm16(try await draw(words))
        case .pause(let seconds): pcm = silence(seconds)
        }
        all.append(pcm)
        try emit?(pcm, i == plan.pieces.count - 1)
    }
    return all
}

let speakOperation = EngineOperation("audio.speak") { job, session in
    let plan = try speakPlan(text: try job.text("text"), voice: job.param("voice")?.stringValue)
    let stream = session.streams("audio")
    // MES seeds are 0 to 2^32 - 1 (Audio §1.6).
    let seed = job.seed ?? UInt64.random(in: 0..<(1 << 32))
    let all = try await speak(plan, seed: seed, draw: { words in
        guard let response = try await session.run(TTSRequest(text: words, voice: VoiceSelector(.named(plan.voice)))) as? TTSResponse else {
            throw GPPError(.modelError, "Kokoro returned no audio.")
        }
        return response.audio.data
    }, emit: stream ? { pcm, final in try session.emit("audio", int16: pcm, sampleRate: sampleRate, final: final) } : nil)
    let effective: [String: JSONValue] = [
        "voice": .string(plan.voice), "language": .string(language(plan.voice)), "seed": .int(Int64(seed)),
        "x-kokoro.pieces": .int(Int64(plan.pieces.count)),
    ]
    if stream { return RunResult(outputs: [.streamed("audio")], effective: effective) }
    let url = session.outputDir.appending(path: "audio-0.wav")
    try wav16(all).write(to: url)
    return RunResult(outputs: [.file("audio", url, mediaType: "audio/wav")], effective: effective)
}

// MARK: - The plugin

public let kokoroLanes = [LaneDefinition(id: "bf16", default: true, configuration: KokoroConfiguration())]

let kokoroModel = ModelDefinition.engine(KokoroTTSPackage.self, id: kokoroModelID, title: "Kokoro-82M",
                                         lanes: kokoroLanes, operations: [speakOperation])

let kokoroOffer = PluginManifest.Offer(
    operation: "audio.speak", profile: "audio",
    model: [
        "id": .string(kokoroModelID), "title": "Kokoro-82M",
        "license": ["spdx": "Apache-2.0", "commercial_use": true, "terms_url": "https://huggingface.co/hexgrad/Kokoro-82M"],
        "memory_class": "small", "speed_class": "fast", "quality_tiers": ["draft", "standard", "best"],
        "notes": "Fast English text-to-speech with 28 preset voices (American and British). Write plain sentences; [pause 1s] adds silence. It doesn't clone voices or act emotions.",
        "supports": [
            "voices": .int(Int64(kokoroVoices.count)), "default_voice": true, "stream": true,
            "languages": ["en-US", "en-GB"], "cues": ["pause"], "sample_rate": .int(Int64(sampleRate)), "channels": 1,
        ],
        "limits": ["max_text_chars": .int(Int64(maxTextChars))],
    ],
    voices: kokoroVoices.map { voice -> JSONValue in
        var fields: [String: JSONValue] = [
            "id": .string(voice.id), "title": .string(voice.title), "languages": [.string(language(voice.id))],
            "tags": .array(voice.tags.map { .string($0) }),
        ]
        if voice.id == defaultVoice { fields["notes"] = "The default voice." }
        return .object(fields)
    })

public let kokoroPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.kokoro", version: "0.1.0", minGaea: "0.9.0", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-kokoro", title: "Kokoro",
    summary: "Kokoro-82M: fast English text-to-speech, 28 preset voices, streamed sentence by sentence (MES audio.speak).",
    license: "Apache-2.0", executable: "gaea-kokoro-worker",
    models: [kokoroModel], offers: [kokoroOffer])
