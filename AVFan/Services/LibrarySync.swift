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
        /// Set by a successful cast-review creation: the review's id.
        var reviewID: String?
    }

    private static func resolve(_ path: String) -> URL? {
        if path.hasPrefix("http") { return URL(string: path) }
        return SiteClient.shared.catalogURL(path: path)
    }

    /// Bridge the WebView cookie store into the shared store
    /// before every account write (build 34). The login lives in
    /// WKWebsiteDataStore, which persists across launches; the
    /// shared store's session cookies do not — after a relaunch
    /// the page fetches can look signed in (cached or WebView
    /// HTML) while these POSTs go out as a guest, get bounced to
    /// the sign-in page, and record nothing on the account.
    private static func prepare() async {
        await CookieBridge.exportWebKitToShared()
    }

    private static func outcome(status: Int, json: [String: Any]?) -> Outcome {
        if status == 401 || status == 403 {
            return Outcome(success: false, message: "请先登录 avfan 账号", needsLogin: true)
        }
        let success = (json?["success"] as? Bool) ?? (200..<300).contains(status)
        var reviewID: String?
        if let number = json?["id"] as? NSNumber { reviewID = number.stringValue }
        if let text = json?["id"] as? String { reviewID = text }
        return Outcome(
            success: success,
            message: json?["message"] as? String,
            removeURL: json?["remove_url"] as? String,
            listFragment: json?["list"] as? String,
            reviewID: reviewID
        )
    }

    /// A model action （关注/收藏）: POST {model, model_id} to the
    /// button's own data-url, exactly like the site's model controller.
    static func modelAction(url: String, model: String?, modelID: String?, csrf: String?) async -> Outcome {
        await prepare()
        guard let endpoint = resolve(url) else {
            return Outcome(success: false, message: "页面没有给出同步地址")
        }
        do {
            let (status, json) = try await SiteClient.shared.jsonRequest(
                method: "POST", url: endpoint, csrf: csrf,
                body: ["model": model ?? "", "model_id": modelID ?? ""]
            )
            return modelOutcome(status: status, json: json)
        } catch {
            return Outcome(success: false, message: "同步失败：\(error.localizedDescription)")
        }
    }

    /// Success for a model action means what the site's own JS
    /// means: the JSON says success == true. A 2xx with no JSON
    /// is the sign-in page after a redirect — the write did NOT
    /// land (build 34: list collects claimed success in the app
    /// while the account never recorded them).
    private static func modelOutcome(status: Int, json: [String: Any]?) -> Outcome {
        if status == 401 || status == 403 {
            return Outcome(success: false, message: "请先登录 avfan 账号", needsLogin: true)
        }
        guard let json else {
            return Outcome(success: false, message: "服务器未确认（登录可能已失效）", needsLogin: (200..<300).contains(status))
        }
        let ok = (json["success"] as? Bool) == true
        return Outcome(
            success: ok,
            message: json["message"] as? String ?? (ok ? nil : "服务器未确认收藏")
        )
    }

    /// The undo of a model action （取消关注/取消收藏）: DELETE the
    /// button's data-url.
    static func modelUndo(url: String, csrf: String?) async -> Outcome {
        await prepare()
        guard let endpoint = resolve(url) else {
            return Outcome(success: false, message: "页面没有给出同步地址")
        }
        do {
            let (status, json) = try await SiteClient.shared.jsonRequest(
                method: "DELETE", url: endpoint, csrf: csrf, body: nil
            )
            return modelOutcome(status: status, json: json)
        } catch {
            return Outcome(success: false, message: "同步失败：\(error.localizedDescription)")
        }
    }

    /// Post a cast short review: POST {cast_id, score, body} to the
    /// review element's data-create-url (a score is required).
    static func createCastReview(url: String, castSqid: String, score: Int, body: String, csrf: String?) async -> Outcome {
        await prepare()
        guard let endpoint = resolve(url) else {
            return Outcome(success: false, message: "页面没有给出同步地址")
        }
        do {
            let (status, json) = try await SiteClient.shared.jsonRequest(
                method: "POST", url: endpoint, csrf: csrf,
                body: ["cast_id": castSqid, "score": "\(score)", "body": body]
            )
            return outcome(status: status, json: json)
        } catch {
            return Outcome(success: false, message: "同步失败：\(error.localizedDescription)")
        }
    }

    /// Mark the movie 想看 or 看过 (the site's createReview call; it
    /// also switches an existing review to the other status).
    static func setReview(url: String, actionType: String, csrf: String?) async -> Outcome {
        await prepare()
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
        await prepare()
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
        await prepare()
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
        await prepare()
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
        await prepare()
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
