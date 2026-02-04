import AVFoundation
import Foundation

final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speakingMessageId: UUID?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggleSpeak(messageId: UUID, text: String) {
        guard !text.isEmpty else { return }
        if speakingMessageId == messageId, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            speakingMessageId = nil
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        speakingMessageId = messageId
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        speakingMessageId = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        speakingMessageId = nil
    }
}
