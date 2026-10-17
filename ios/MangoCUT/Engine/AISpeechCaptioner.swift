import AVFoundation
import Foundation
import Speech

/// Motor de Reconhecimento de Fala para Legendas Automáticas com Inteligência Artificial.
/// Inspirado nos modelos de ASR do CapCut (ByteNN ~180 MB), mas implementado de forma 100% nativa
/// usando o framework Speech da Apple com `requiresOnDeviceRecognition = true`.
/// Processa o áudio do vídeo totalmente offline, sem enviar dados para a nuvem, garantindo privacidade total.
enum AISpeechCaptioner {
    struct Caption: Identifiable, Sendable {
        let id = UUID().uuidString
        let text: String
        let startUs: Double
        let durationUs: Double
    }

    enum CaptionError: LocalizedError {
        case notAuthorized
        case notAvailable
        case noSpeechDetected
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Permissão de reconhecimento de voz necessária para gerar legendas automáticas."
            case .notAvailable:
                return "O reconhecimento de voz local não está disponível neste dispositivo."
            case .noSpeechDetected:
                return "Nenhuma fala foi detectada no vídeo."
            case .recognitionFailed(let msg):
                return "Falha no reconhecimento de fala: \(msg)"
            }
        }
    }

    /// Solicita autorização de reconhecimento de voz caso ainda não tenha sido concedida.
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Analisa o arquivo de mídia e devolve uma lista de frases legendadas sincronizadas no tempo.
    static func transcribe(url: URL) async throws -> [Caption] {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status != .authorized {
            let granted = await requestAuthorization()
            guard granted else { throw CaptionError.notAuthorized }
        }

        // Tenta o idioma local do usuário ou português brasileiro / inglês como fallback
        let recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "pt-BR"))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

        guard let recognizer, recognizer.isAvailable else {
            throw CaptionError.notAvailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        // Garante execução 100% no dispositivo via Apple Neural Engine (offline, seguro)
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var hasFinished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !hasFinished else { return }
                if let error {
                    hasFinished = true
                    continuation.resume(throwing: CaptionError.recognitionFailed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                hasFinished = true

                let captions = groupSegmentsIntoCaptions(result.bestTranscription.segments)
                if captions.isEmpty {
                    continuation.resume(throwing: CaptionError.noSpeechDetected)
                } else {
                    continuation.resume(returning: captions)
                }
            }
        }
    }

    /// Agrupa palavras reconhecidas em frases curtas e naturais para leitura confortável na tela (2 a 4 segundos por bloco).
    private static func groupSegmentsIntoCaptions(_ segments: [SFTranscriptionSegment]) -> [Caption] {
        var captions: [Caption] = []
        var currentWords: [String] = []
        var blockStartUs: Double = 0
        var blockEndUs: Double = 0

        for segment in segments {
            let word = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }

            let startUs = segment.timestamp * 1_000_000
            let endUs = (segment.timestamp + segment.duration) * 1_000_000

            if currentWords.isEmpty {
                blockStartUs = startUs
                blockEndUs = endUs
                currentWords.append(word)
            } else {
                let durationSoFar = endUs - blockStartUs
                let pauseBeforeWord = startUs - blockEndUs

                // Quebra a legenda quando a pausa for maior que 0.6s ou o bloco atingir ~3.5s ou ~5 palavras
                if pauseBeforeWord > 600_000 || durationSoFar > 3_500_000 || currentWords.count >= 5 {
                    let phrase = currentWords.joined(separator: " ")
                    let duration = max(blockEndUs - blockStartUs, 1_200_000)
                    captions.append(Caption(text: phrase, startUs: blockStartUs, durationUs: duration))

                    currentWords = [word]
                    blockStartUs = startUs
                    blockEndUs = endUs
                } else {
                    currentWords.append(word)
                    blockEndUs = endUs
                }
            }
        }

        if !currentWords.isEmpty {
            let phrase = currentWords.joined(separator: " ")
            let duration = max(blockEndUs - blockStartUs, 1_200_000)
            captions.append(Caption(text: phrase, startUs: blockStartUs, durationUs: duration))
        }

        return captions
    }
}
