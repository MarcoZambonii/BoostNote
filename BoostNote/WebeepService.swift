import Foundation

// WeBeep (webeep.polimi.it) è un'istanza Moodle: usiamo il flusso di
// login mobile ufficiale di Moodle (l'utente si autentica sulla vera
// pagina Polimi in un browser incorporato — l'app non vede mai la
// password) e poi le Web Services REST standard di Moodle.
enum WebeepService {
    static let baseURL = "https://webeep.polimi.it"
    private static let tokenKey = "webeepToken"

    static var savedToken: String? {
        KeychainStore.get(tokenKey)
    }

    static func save(token: String) {
        KeychainStore.set(token, forKey: tokenKey)
    }

    static func signOut() {
        KeychainStore.remove(tokenKey)
    }

    static func loginLaunchURL(passport: String) -> URL? {
        var components = URLComponents(string: "\(baseURL)/admin/tool/mobile/launch.php")
        components?.queryItems = [
            URLQueryItem(name: "service", value: "moodle_mobile_app"),
            URLQueryItem(name: "passport", value: passport),
            URLQueryItem(name: "urlscheme", value: "moodlemobile")
        ]
        return components?.url
    }

    // Il redirect finale ha la forma "moodlemobile://token=<base64>".
    // Il base64 decodifica in "siteid:::token:::privatetoken".
    static func extractToken(fromRedirect url: URL) -> String? {
        guard let raw = url.absoluteString.components(separatedBy: "token=").last,
              let decodedData = Data(base64Encoded: raw.removingPercentEncoding ?? raw),
              let decoded = String(data: decodedData, encoding: .utf8) else { return nil }
        let parts = decoded.components(separatedBy: ":::")
        if parts.count >= 2 { return parts[1] }
        // Fallback difensivo se Moodle usa un delimitatore diverso.
        let simpleParts = decoded.components(separatedBy: ":")
        return simpleParts.count >= 2 ? simpleParts[1] : nil
    }

    static func siteInfo(token: String) async -> WebeepSiteInfo? {
        await call(function: "core_webservice_get_site_info", token: token, params: [:])
    }

    static func courses(token: String, userID: Int) async -> [WebeepCourse] {
        let params = ["userid": String(userID)]
        return (await call(function: "core_enrol_get_users_courses", token: token, params: params)) ?? []
    }

    // Struttura reale del corso (sezioni Moodle con i rispettivi file),
    // per mostrare i materiali raggruppati come su WeBeep invece che in
    // un'unica lista piatta.
    static func contents(token: String, courseID: Int) async -> [WebeepSection] {
        let params = ["courseid": String(courseID)]
        let sections: [WebeepSection]? = await call(function: "core_course_get_contents", token: token, params: params)
        return (sections ?? []).filter { section in
            !(section.modules ?? []).flatMap { $0.contents ?? [] }.isEmpty
        }
    }

    static func downloadFile(_ file: WebeepFile, token: String) async -> Data? {
        guard var components = URLComponents(string: file.fileurl) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        guard let url = components.url else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }

    // Moodle inserisce spesso i nomi multilingua con il filtro "multilang":
    // {mlang it}Nome italiano{mlang}{mlang en}English name{mlang}. Qui
    // teniamo solo la versione italiana (o la prima disponibile).
    static func stripMultilang(_ raw: String, preferred: String = "it") -> String {
        guard raw.contains("{mlang") else { return raw }
        guard let regex = try? NSRegularExpression(pattern: #"\{mlang\s+([a-zA-Z, ]+)\}(.*?)\{mlang\}"#, options: [.dotMatchesLineSeparators]) else {
            return raw
        }
        let nsrange = NSRange(raw.startIndex..., in: raw)
        var matches: [(lang: String, text: String)] = []
        regex.enumerateMatches(in: raw, range: nsrange) { match, _, _ in
            guard let match, match.numberOfRanges == 3,
                  let langRange = Range(match.range(at: 1), in: raw),
                  let textRange = Range(match.range(at: 2), in: raw) else { return }
            matches.append((String(raw[langRange]).trimmingCharacters(in: .whitespaces), String(raw[textRange])))
        }
        guard !matches.isEmpty else { return raw }
        let chosen = matches.first { $0.lang.lowercased().contains(preferred) } ?? matches[0]
        return chosen.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func call<T: Decodable>(function: String, token: String, params: [String: String]) async -> T? {
        var components = URLComponents(string: "\(baseURL)/webservice/rest/server.php")
        var items = [
            URLQueryItem(name: "wstoken", value: token),
            URLQueryItem(name: "wsfunction", value: function),
            URLQueryItem(name: "moodlewsrestformat", value: "json")
        ]
        items += params.map { URLQueryItem(name: $0.key, value: $0.value) }
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

struct WebeepSiteInfo: Decodable {
    var userid: Int
    var fullname: String
    var username: String?
}

struct WebeepCourse: Identifiable, Decodable {
    var id: Int
    var fullname: String
    var shortname: String?
}

struct WebeepSection: Decodable, Identifiable {
    var id: Int
    var name: String?
    var modules: [WebeepModule]?

    // Solo i moduli che portano davvero dei file (i "resource"/"folder" di
    // Moodle): un modulo "folder" è la vera cartella che su WeBeep spesso
    // porta il nome del professore o dell'argomento.
    var modulesWithFiles: [WebeepModule] {
        (modules ?? []).filter { !($0.contents ?? []).isEmpty }
    }

    var files: [WebeepFile] {
        modulesWithFiles.flatMap { $0.contents ?? [] }
    }
}

struct WebeepModule: Decodable, Identifiable {
    var id: Int
    var name: String?
    var modname: String?
    var contents: [WebeepFile]?
}

struct WebeepFile: Identifiable, Decodable {
    var filename: String
    var fileurl: String
    var mimetype: String?
    // Percorso reale dentro un modulo "folder" di Moodle (es. "/Lezione 1/"):
    // è la sottodivisione che il professore ha davvero impostato.
    var filepath: String?

    var id: String { fileurl }

    // "/" o vuoto = alla radice del modulo; altrimenti nome della sottocartella.
    var subfolderName: String? {
        guard let filepath else { return nil }
        let trimmed = filepath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? nil : trimmed
    }
}
