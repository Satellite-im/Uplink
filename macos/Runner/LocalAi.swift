import Foundation
#if canImport(FlutterMacOS)
import FlutterMacOS
#else
import Flutter
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Replies to choose from and summaries, by the small language model Apple keeps on the device (the same file in
/// macos/Runner and ios/Runner; lib/local_ai.dart; Matt, 2026-11-26: "add more intelligent auto replies using a very
/// lightweight local AI that summarizes text and whatnot"). It is Apple Intelligence's own model, through the
/// FoundationModels framework (macOS 26 and iOS 26 on): nothing of ours is downloaded and nothing leaves the device.
/// Where the device has no such model (older systems, Apple Intelligence off or not here) `status` says so and the
/// app keeps to its own replies.
#if canImport(FoundationModels)
/// The three replies, as the model is held to give them.
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct RepliesAnswer {
  @Guide(description: "Three different short replies, each at most eight words", .count(3))
  var replies: [String]
}

/// The summary, as the model is held to give it: one sentence.
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct SummaryAnswer {
  @Guide(description: "One sentence of at most twenty words, in the third person, saying what the messages say and ask")
  var sentence: String
}
#endif

final class LocalAi: NSObject {
  static let shared = LocalAi()

  /// The `ghost/local_ai` channel: status, replies (a conversation's last texts), summarize (words).
  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "ghost/local_ai", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "status":
        result(LocalAi.status())
      case "replies":
        let messages = args["messages"] as? [[String: Any]] ?? []
        Task {
          let said = await LocalAi.replies(messages)
          DispatchQueue.main.async { result(said) }
        }
      case "summarize":
        let text = args["text"] as? String ?? ""
        let kind = args["kind"] as? String ?? "conversation"
        Task {
          let said = await LocalAi.summarize(text, kind: kind)
          DispatchQueue.main.async { result(said) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// "available", "downloading" (the model is still coming), or "unavailable".
  static func status() -> String {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available: return "available"
      case .unavailable(.modelNotReady): return "downloading"
      default: return "unavailable"
      }
    }
    #endif
    return "unavailable"
  }

  /// The conversation as lines, "Me: …" for the person's own texts and "<name>: …" for the others', oldest first.
  static func lines(_ messages: [[String: Any]]) -> String {
    messages.suffix(12).compactMap { m -> String? in
      let text = (m["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty { return nil }
      let who = (m["mine"] as? Bool ?? false) ? "Me" : ((m["who"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Them")
      return "\(who): \(String(text.prefix(600)))"
    }.joined(separator: "\n")
  }

  /// Three short replies the person ("Me") could send next, or none. Asked for as a list the framework holds the
  /// model to (`RepliesAnswer`), so the answer is three replies and nothing else.
  static func replies(_ messages: [[String: Any]]) async -> [String] {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, *) {
      guard status() == "available" else { return [] }
      let talk = lines(messages)
      if talk.isEmpty { return [] }
      let last = messages.last { !($0["mine"] as? Bool ?? false) }
      let them = (last?["who"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "them"
      let session = LanguageModelSession(instructions: """
        You help someone reply to text messages. You read a conversation and suggest three different short replies \
        they could send next, written as them, casual like a text, in the conversation's language, each at most eight \
        words. Each reply answers the newest message directly. Offer different directions (for example yes, no, a \
        question back). Never make up facts, plans or places that aren't in the conversation.

        Example. Conversation: "Sam: are you coming to the game saturday?" Replies: "Yes, I'll be there!", \
        "Can't this time, sorry", "What time does it start?"
        Example. Conversation: "Jo: thank you for the flowers, they're beautiful" Replies: "So glad you like them!", \
        "You deserve them ❤️", "Anytime!"
        """)
      do {
        let prompt = "The conversation (\"Me\" is the person you help):\n\(talk)\n\nSuggest three replies to \(them)'s last message."
        let r = try await session.respond(to: prompt, generating: RepliesAnswer.self, options: GenerationOptions(temperature: 0.5))
        return tidyReplies(r.content.replies.joined(separator: "\n"))
      } catch {
        return []
      }
    }
    #endif
    return []
  }

  /// A reply on each line, their marks, numbers and quotes taken off; at most three.
  static func tidyReplies(_ said: String) -> [String] {
    var out: [String] = []
    for raw in said.split(whereSeparator: \.isNewline) {
      var s = raw.trimmingCharacters(in: .whitespaces)
      while let c = s.first, "-*•0123456789.)".contains(c) { s.removeFirst() }
      s = s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
      if s.lowercased().hasPrefix("me:") { s = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
      if s.isEmpty || s.count > 60 || out.contains(s) { continue }
      out.append(s)
      if out.count == 3 { break }
    }
    return out
  }

  /// One sentence on what [text] says: a conversation (a line a text) or one long message. Nil where it can't.
  static func summarize(_ text: String, kind: String) async -> String? {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, *) {
      guard status() == "available", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      let what = kind == "message" ? "a long text message someone was sent" : "the messages someone was sent while away, a line a message, each starting with who sent it"
      let session = LanguageModelSession(instructions: """
        You summarise \(what), so they can catch up at a glance. Answer with one short sentence of at most twenty \
        words, in the third person (for example "Ana is running late and asks you to order for her."), in the \
        messages' language. Say what matters and anything asked of the reader; don't repeat the messages word for \
        word, and don't add anything that isn't in them.
        """)
      do {
        let r = try await session.respond(to: "Summarise:\n\(String(text.prefix(6000)))", generating: SummaryAnswer.self, options: GenerationOptions(temperature: 0.2))
        let line = r.content.sentence.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
      } catch {
        return nil
      }
    }
    #endif
    return nil
  }
}
