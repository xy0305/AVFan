import Foundation

/// Account sync for the detail page's library actions （想看 / 看过 /
/// 保存至清单）. Every call mirrors the site's own fetch() calls —
/// same endpoints (read from the page's data attributes), same JSON
/// bodies, same CSRF header — inside the app's existing site session,
/// so actions land on the user's avfan account itself.
enum LibrarySync {
    struct Outcome {
        var success: Bool
        var message: String?
        var needsLogin: Bool = false
        /// Set by a successful create: the DELETE target for the review.
        var removeURL: String?
        /// Set by a successful list creation: the returned row HTML.
        var listFragment: String?
    }

    private static func resolve(_ path: String) -> URL? {
        if path.hasPrefix("http") { return URL(string: path) }
        return SiteClient.shared.catalogURL(path: path)
    }

    private static func outcome(status: Int, json: [String: Any]?) -> Outcome {
        if status == 401 || status == 403 {
            return Outcome(success: false, message: "请先登录 avfan 账号", needsLogin: true)
        }
        let success = (json?["success"] as? Bool) ?? (200..<300).contains(status)
        return Outcome(
            success: success,
            message: json?["message"] as? String,
            removeURL: json?["remove_url"] as? String,
            listFragment: json?["list"] as? String
        )
    }

    /// Mark the movie 想看 or 看过 (the site's createReview call; it
    /// also switches an existing review to the other status).
    static func setReview(url: String, actionType: String, csrf: String?) async -> Outcome {
        guard let endpoint = resolve(url) else {
            return Outcome(success: false, message: "页面没有给出同步地址")
        }
        do {
            let (status, json) = try await SiteClient.shared.jsonRequest(
                method: "POST", url: endpoint, csrf: csrf,
                body: ["status": actionType, "rating": "0"]
            )
            return outcome(status: status, json: json)
        } catch {
            return Outcome(success: false, message: "同步失败：\(error.localizedDescription)")
        }
    }

    /// Remove the movie's review entirely (the site's removeReview).
    static func removeReview(url: String, csrf: String?) async -> Outcome {
        guard let endpoint = resolve(url) else {
            return Outcome(success: false, message: "页面没有给出同步地址")
        }
        do {
            let (status, json) = try await SiteClient.shared.jsonRequest(
                method: "DELETE", url: endpoint, csrf: csrf, body: nil
            )
            return outcome(status: status, json: json)
        } catch {
            return Outcome(success: false, message: "同步失败：\(error.localizedDescription)")
        }
    }

    /// The save-to-list picker's rows: the endpoint answers JSON whose
    /// "lists" field is an HTML fragment; further pages append the
    /// same way the site's infinite scroll does.
    static func fetchListOptions(listsURL: String, csrf: String?) async -> [SyncListOption] {
        var options: [SyncListOption] = []
        var page = 1
        while page <= 5 {
            let separator = listsURL.contains("?") ? "&" : "?"
            guard let endpoint = resolve("\(listsURL)\(separator)page=\(page)") else { break }
            do {
                let (status, json) = try await SiteClient.shared.jsonRequest(
                    method: "GET", url: endpoint, csrf: csrf, body: nil
                )
                guard (200..<300).contains(status), let fragment = json?["lists"] as? String else { break }
                options += HTMLParser.listOptions(in: fragment)
                let hasNext = (json?["has_next_page"] as? Bool) ?? false
                guard hasNext, let next = json?["next_page"] as? Int, next > page else { break }
                page = next
            } catch {
                break
            }
        }
        return options
    }

    /// Toggle this movie's membership in one list (the site's
    /// toggleList call: same POST adds or removes).
    static func toggleList(changeURL: String, listID: String, csrf: String?) async -> Outcome {
        guard let endpoint = resolve(changeURL) else {
            return Outcome(success: false, message: "页面没有给出同步地址")
        }
        do {
            let (status, json) = try await SiteClient.shared.jsonRequest(
                method: "POST", url: endpoint, csrf: csrf,
                body: ["list_id": listID]
            )
            return outcome(status: status, json: json)
        } catch {
            return Outcome(success: false, message: "同步失败：\(error.localizedDescription)")
        }
    }

    /// Create a new list (the site's saveList call in "new" mode).
    static func createList(url: String, mode: String, name: String, csrf: String?) async -> Outcome {
        guard let endpoint = resolve(url) else {
            return Outcome(success: false, message: "页面没有给出同步地址")
        }
        do {
            let (status, json) = try await SiteClient.shared.jsonRequest(
                method: mode == "new" ? "POST" : "PUT", url: endpoint, csrf: csrf,
                body: ["name": name]
            )
            return outcome(status: status, json: json)
        } catch {
            return Outcome(success: false, message: "同步失败：\(error.localizedDescription)")
        }
    }
}
