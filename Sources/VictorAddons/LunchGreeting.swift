import AVFoundation
import Foundation

/// 🍽️ "Have a nice lunch", spoken in the language of the ☕️ break country, when a
/// lunch break starts — and again whenever the country is changed while that
/// lunch is running (2026-11-26, Victor: *"if I'm in Amsterdam … there should be
/// an expression of Bon Appetit in that language … the moment I change the
/// country … it should play"*).
///
/// The second trigger is the correction path: on a remote session the country
/// is the one thing he forgets to set, notices only once the finish time on the
/// watch reads wrong for the room, and fixes from the dropdown mid-lunch. The
/// greeting replays so the room hears it in *their* language after all.
///
/// Spoken live by the system voice (`AVSpeechSynthesizer`), not from recorded
/// files: one line per country here and nothing to generate or ship, and an
/// Enhanced/Premium voice downloaded in System Settings › Accessibility ›
/// Spoken Content is picked up with no change.
enum LunchGreeting {
    /// A break this long or longer is lunch — the 🍽️ rows of the ☕️ Break submenu
    /// (30 / 45 min / 1 hour), where the room goes to eat rather than to refill a cup.
    static let lunchMinutes = 30

    static func isLunch(minutes: Int) -> Bool { minutes >= lunchMinutes }

    struct Phrase: Equatable {
        let text: String
        /// BCP-47 language of `text`, e.g. `nl-NL` — picks the voice.
        let language: String
    }

    /// English, for a country with no line below.
    static let fallback = Phrase(text: "Enjoy your lunch!", language: "en-GB")

    /// What a local says to a room heading out **to lunch**, by ISO-3166 alpha-2.
    /// Lunch-specific wording wherever the language has one (*Bon déjeuner !*,
    /// *Buon pranzo!*, *Schöne Mittagspause!*, *Trevlig lunch!*) rather than a
    /// "bon appétit" that reads like a dinner table (Victor, 2026-11-26). The
    /// any-meal phrase stays where it is what people say at noon too: *Poftă
    /// bună!*, *Smacznego!*, *¡Buen provecho!* — and Dutch *Eet smakelijk!*,
    /// which Victor checked and kept over *Fijne lunch!*.
    /// Pure, so it is unit-tested. Extend by adding a line.
    static func phrase(forISO iso: String) -> Phrase {
        switch iso.uppercased() {
        case "RO": return .init(text: "Poftă bună!", language: "ro-RO")
        case "NL": return .init(text: "Eet smakelijk!", language: "nl-NL")
        case "BE": return .init(text: "Smakelijk!", language: "nl-BE")
        case "DE", "AT", "CH": return .init(text: "Schöne Mittagspause!", language: "de-DE")
        case "FR": return .init(text: "Bon déjeuner !", language: "fr-FR")
        case "IT": return .init(text: "Buon pranzo!", language: "it-IT")
        case "ES": return .init(text: "¡Buen provecho!", language: "es-ES")
        case "MX", "AR", "CL", "CO", "PE": return .init(text: "¡Buen provecho!", language: "es-MX")
        case "PT": return .init(text: "Bom almoço!", language: "pt-PT")
        case "BR": return .init(text: "Bom almoço!", language: "pt-BR")
        case "PL": return .init(text: "Smacznego!", language: "pl-PL")
        case "CZ": return .init(text: "Dobrou chuť!", language: "cs-CZ")
        case "HU": return .init(text: "Jó étvágyat!", language: "hu-HU")
        case "GR", "CY": return .init(text: "Καλή όρεξη!", language: "el-GR")
        case "DK": return .init(text: "God frokost!", language: "da-DK")
        case "NO": return .init(text: "God lunsj!", language: "nb-NO")
        case "SE": return .init(text: "Trevlig lunch!", language: "sv-SE")
        case "FI": return .init(text: "Hyvää lounasta!", language: "fi-FI")
        case "IL": return .init(text: "בתיאבון!", language: "he-IL")
        case "BG": return .init(text: "Добър апетит!", language: "bg-BG")
        case "HR": return .init(text: "Dobar tek!", language: "hr-HR")
        case "RS": return .init(text: "Prijatno!", language: "hr-HR")
        case "RU": return .init(text: "Приятного аппетита!", language: "ru-RU")
        case "UA": return .init(text: "Смачного!", language: "uk-UA")
        case "TR": return .init(text: "Afiyet olsun!", language: "tr-TR")
        case "JP": return .init(text: "お昼休み、ごゆっくりどうぞ！", language: "ja-JP")
        case "KR": return .init(text: "점심 맛있게 드세요!", language: "ko-KR")
        case "CN", "SG": return .init(text: "祝大家午餐愉快！", language: "zh-CN")
        case "TW": return .init(text: "祝大家午餐愉快！", language: "zh-TW")
        case "HK": return .init(text: "慢慢食！", language: "yue-HK")
        case "TH": return .init(text: "ทานข้าวเที่ยงให้อร่อยนะ", language: "th-TH")
        case "VN": return .init(text: "Chúc ngon miệng!", language: "vi-VN")
        case "ID": return .init(text: "Selamat makan siang!", language: "id-ID")
        case "MY": return .init(text: "Selamat makan tengah hari!", language: "ms-MY")
        case "IN": return .init(text: "Enjoy your lunch!", language: "en-IN")
        case "IE": return .init(text: "Enjoy your lunch!", language: "en-IE")
        case "US", "CA": return .init(text: "Enjoy your lunch!", language: "en-US")
        case "AU", "NZ": return .init(text: "Enjoy your lunch!", language: "en-AU")
        case "ZA": return .init(text: "Enjoy your lunch!", language: "en-ZA")
        default: return fallback
        }
    }

    // MARK: - Speaking

    /// Held so the utterance is not cut off by ARC; main thread only.
    private static let synthesizer: AVSpeechSynthesizer = {
        let s = AVSpeechSynthesizer()
        s.delegate = tracker
        return s
    }()
    private static let tracker = Tracker()

    /// What was last said and whether the synthesizer got through it — the app's
    /// log only reaches its own window, so `/test/break/state` reads this to tell
    /// "the words were spoken" from "the code path ran". Main thread only.
    private(set) static var last: (text: String, voice: String, iso: String)?
    private(set) static var finishedCount = 0

    private final class Tracker: NSObject, AVSpeechSynthesizerDelegate {
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
            DispatchQueue.main.async { LunchGreeting.finishedCount += 1 }
        }
    }

    /// `{"text":…,"voice":…,"iso":…,"finished":N}`, or `null` before the first greeting.
    static func stateJSON() -> String {
        guard let l = last else { return "null" }
        func esc(_ x: String) -> String { x.replacingOccurrences(of: "\"", with: "\\\"") }
        return "{\"text\":\"\(esc(l.text))\",\"voice\":\"\(esc(l.voice))\",\"iso\":\"\(l.iso)\",\"finished\":\(finishedCount)}"
    }

    /// The best installed voice for `language`: exact locale before the bare
    /// language, Premium before Enhanced before the default. Skips the novelty
    /// and Eloquence voices (Bad News, Grandpa, …), which share the locales.
    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let base = language.split(separator: "-").first.map(String.init) ?? language
        let usable = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.identifier.contains("speech.synthesis") && !$0.identifier.contains("eloquence")
        }
        func best(_ vs: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
            vs.max { $0.quality.rawValue < $1.quality.rawValue }
        }
        return best(usable.filter { $0.language == language })
            ?? best(usable.filter { $0.language.hasPrefix(base + "-") })
    }

    /// Say the greeting for `country`. A voice missing for its language falls
    /// back to the English line rather than having a foreign voice mangle it.
    static func speak(for country: BreakCountry) {
        DispatchQueue.main.async {
            var p = phrase(forISO: country.iso)
            var v = voice(for: p.language)
            if v == nil { p = fallback; v = voice(for: p.language) }
            let u = AVSpeechUtterance(string: p.text)
            u.voice = v
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
            // Bluetooth speakers swallow the first ~0.5 s while the codec wakes:
            // the same warm-up tone the gong uses, then the words.
            let comp = AddonSounds.shared.currentBluetoothCompensation
            if comp > 0 { BluetoothOutput.playWakeTone(seconds: comp) }
            u.preUtteranceDelay = comp
            overlayInfo("🍽️ \(country.flag) \(p.text) [\(v?.name ?? "default voice")]")
            last = (p.text, v?.name ?? "default", country.iso)
            synthesizer.speak(u)
        }
    }
}
