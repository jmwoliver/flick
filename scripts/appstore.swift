// Fills in the iPhone app's App Store listing and submits it for review, through the
// App Store Connect API.
//
//   xcrun swift scripts/appstore.swift check     # read-only: show what's set and what's missing
//   xcrun swift scripts/appstore.swift apply     # set the listing, screenshots, build, review info
//   xcrun swift scripts/appstore.swift submit    # submit the version for App Review
//
// The listing text comes from docs/app-store/metadata.json. Credentials and contact details come
// from the environment, so nothing private is stored in the repo:
//
//   ASC_KEY_ID, ASC_ISSUER_ID     App Store Connect API key (Users and Access › Integrations)
//   ASC_KEY_PATH                  default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
//   ASC_CONTACT_FIRST, ASC_CONTACT_LAST, ASC_CONTACT_PHONE, ASC_CONTACT_EMAIL   App Review contact
//   ASC_REVIEW_ATTACHMENT         optional file (e.g. the demo video) attached for App Review
//
// App Privacy ("Data Not Collected") can't be set through the API; set it once on the website.

import CryptoKit
import Foundation

// MARK: - Setup

let env = ProcessInfo.processInfo.environment
func need(_ k: String) -> String {
    guard let v = env[k], !v.isEmpty else { fail("Set \(k).") }
    return v
}
func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data("Error: \(msg)\n".utf8)); exit(1) }
func say(_ msg: String) { print("==> \(msg)") }

let command = CommandLine.arguments.dropFirst().first ?? "check"
guard ["check", "apply", "submit"].contains(command) else { fail("Usage: appstore.swift check|apply|submit") }

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let meta = try! JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("docs/app-store/metadata.json"))) as! [String: Any]
func m(_ k: String) -> String { meta[k] as! String }

let keyID = need("ASC_KEY_ID"), issuer = need("ASC_ISSUER_ID")
let keyPath = env["ASC_KEY_PATH"] ?? "\(NSHomeDirectory())/.appstoreconnect/private_keys/AuthKey_\(keyID).p8"
guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8) else { fail("Can't read the API key at \(keyPath).") }
guard let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { fail("The API key file isn't a valid .p8 key.") }

// MARK: - API

func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func token() -> String {
    let header = b64url(try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"]))
    let now = Int(Date().timeIntervalSince1970)
    let claims = b64url(try! JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"]))
    let sig = try! privateKey.signature(for: Data("\(header).\(claims)".utf8)).rawRepresentation
    return "\(header).\(claims).\(b64url(sig))"
}

typealias JSON = [String: Any]
struct APIError: Error, CustomStringConvertible { let status: Int; let body: String; var description: String { "HTTP \(status): \(body)" } }

@discardableResult
func api(_ method: String, _ path: String, _ body: JSON? = nil) async throws -> JSON {
    var req = URLRequest(url: URL(string: path.hasPrefix("http") ? path : "https://api.appstoreconnect.apple.com\(path)")!)
    req.httpMethod = method
    req.setValue("Bearer \(token())", forHTTPHeaderField: "Authorization")
    if let body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as! HTTPURLResponse).statusCode
    guard (200..<300).contains(status) else {
        let errors = ((try? JSONSerialization.jsonObject(with: data)) as? JSON)?["errors"] as? [JSON] ?? []
        // Apple puts the actual reasons (e.g. a missing field) under meta.associatedErrors.
        let text = errors.map { e -> String in
            var s = "\(e["title"] ?? ""): \(e["detail"] ?? "")"
            if let assoc = (e["meta"] as? JSON)?["associatedErrors"] as? [String: [JSON]] {
                for (_, list) in assoc { for a in list { s += "\n    - \(a["detail"] ?? a["title"] ?? a["code"] ?? "")" } }
            }
            return s
        }.joined(separator: "; ")
        throw APIError(status: status, body: text.isEmpty ? String(decoding: data, as: UTF8.self) : text)
    }
    return data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? JSON ?? [:])
}
func list(_ path: String) async throws -> [JSON] { try await api("GET", path)["data"] as? [JSON] ?? [] }
func one(_ path: String) async throws -> JSON? {
    do { return try await api("GET", path)["data"] as? JSON } catch let e as APIError where e.status == 404 { return nil }
}
func attr(_ o: JSON, _ k: String) -> Any? { (o["attributes"] as? JSON)?[k] }
func id(_ o: JSON) -> String { o["id"] as! String }
func ref(_ type: String, _ id: String) -> JSON { ["data": ["type": type, "id": id]] }

/// Reserves an asset, uploads it in the parts Apple asks for, and marks it uploaded.
func upload(_ file: URL, type: String, relationship: String, parent: (String, String), extra: JSON = [:]) async throws {
    let data = try Data(contentsOf: file)
    var attrs: JSON = ["fileName": file.lastPathComponent, "fileSize": data.count]
    attrs.merge(extra) { a, _ in a }
    let res = try await api("POST", "/v1/\(type)", ["data": ["type": type, "attributes": attrs,
        "relationships": [relationship: ref(parent.0, parent.1)]]])
    let asset = res["data"] as! JSON
    for op in attr(asset, "uploadOperations") as? [JSON] ?? [] {
        var req = URLRequest(url: URL(string: op["url"] as! String)!)
        req.httpMethod = op["method"] as? String ?? "PUT"
        for h in op["requestHeaders"] as? [JSON] ?? [] { req.setValue(h["value"] as? String, forHTTPHeaderField: h["name"] as! String) }
        let offset = op["offset"] as! Int, length = op["length"] as! Int
        let (_, resp) = try await URLSession.shared.upload(for: req, from: data.subdata(in: offset..<(offset + length)))
        guard (200..<300).contains((resp as! HTTPURLResponse).statusCode) else { throw APIError(status: (resp as! HTTPURLResponse).statusCode, body: "upload part failed") }
    }
    let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try await api("PATCH", "/v1/\(type)/\(id(asset))", ["data": ["type": type, "id": id(asset),
        "attributes": ["uploaded": true, "sourceFileChecksum": md5]]])
}

// MARK: - Run

func run() async throws {
    let bundleID = m("bundleId"), locale = m("locale")
    guard let app = try await list("/v1/apps?filter[bundleId]=\(bundleID)").first else {
        fail("No app with bundle ID \(bundleID) in App Store Connect. Create it first (Apps › + › New App).")
    }
    let appID = id(app)
    say("App: \(attr(app, "name") ?? "?") (\(appID))")

    // The editable app info and version (a new app has exactly one of each).
    let infos = try await list("/v1/apps/\(appID)/appInfos")
    guard let info = infos.first(where: { !["READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_INFO"].contains((attr($0, "state") ?? attr($0, "appStoreState")) as? String ?? "") }) ?? infos.first
    else { fail("No app info found.") }
    let versions = try await list("/v1/apps/\(appID)/appStoreVersions?filter[platform]=IOS")
    guard let version = versions.first(where: { ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"].contains((attr($0, "appStoreState") ?? attr($0, "appVersionState")) as? String ?? "") })
    else { fail("No editable iOS version. States: \(versions.map { attr($0, "appStoreState") ?? "?" })") }
    let versionID = id(version)
    say("Version: \(attr(version, "versionString") ?? "?"), state \(attr(version, "appStoreState") ?? attr(version, "appVersionState") ?? "?")")

    let builds = try await list("/v1/builds?filter[app]=\(appID)&filter[version]=\(m("buildNumber"))&filter[preReleaseVersion.version]=\(m("versionString"))")
    let build = builds.first
    say("Build \(m("versionString")) (\(m("buildNumber"))): \(build.map { attr($0, "processingState") as? String ?? "?" } ?? "not found")")

    if command == "check" {
        let loc = try await list("/v1/appInfos/\(id(info))/appInfoLocalizations").first { attr($0, "locale") as? String == locale }
        let vloc = try await list("/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations").first { attr($0, "locale") as? String == locale }
        let attached = try await one("/v1/appStoreVersions/\(versionID)/build")
        let review = try await one("/v1/appStoreVersions/\(versionID)/appStoreReviewDetail")
        let price = try await one("/v1/apps/\(appID)/appPriceSchedule")
        let avail = try await one("/v1/apps/\(appID)/appAvailabilityV2")
        let primary = try await one("/v1/appInfos/\(id(info))/primaryCategory")
        let secondary = try await one("/v1/appInfos/\(id(info))/secondaryCategory")
        let age = try await one("/v1/appInfos/\(id(info))/ageRatingDeclaration")
        let unanswered = (age?["attributes"] as? JSON ?? [:]).filter { $0.value is NSNull }.map(\.key).sorted()
        var shots: [String] = []
        if let vloc {
            for s in try await list("/v1/appStoreVersionLocalizations/\(id(vloc))/appScreenshotSets") {
                let n = try await list("/v1/appScreenshotSets/\(id(s))/appScreenshots")
                shots.append("\(attr(s, "screenshotDisplayType") ?? "?"): \(n.count) (\(n.map { ((attr($0, "assetDeliveryState") as? JSON)?["state"] as? String) ?? "?" }.joined(separator: ", ")))")
            }
        }
        var attachments: [String] = []
        if let review {
            attachments = try await list("/v1/appStoreReviewDetails/\(id(review))/appStoreReviewAttachments")
                .map { "\(attr($0, "fileName") ?? "?") (\(((attr($0, "assetDeliveryState") as? JSON)?["state"] as? String) ?? "?"))" }
        }
        print("""
          Content rights:   \(attr(app, "contentRightsDeclaration") ?? "—")
          Categories:       \(primary.map(id) ?? "—") / \(secondary.map(id) ?? "—")
          Age rating:       \(age == nil ? "not started" : unanswered.isEmpty ? "all answered" : "unanswered: \(unanswered.joined(separator: ", "))")
          Screenshots:      \(shots.isEmpty ? "none" : shots.joined(separator: "; "))
          Review video:     \(attachments.isEmpty ? "none" : attachments.joined(separator: ", "))
          Sign-in required: \(review.map { attr($0, "demoAccountRequired") ?? "?" } ?? "—")
          Release:          \(attr(version, "releaseType") ?? "—")
          Build icon:       \(build.flatMap { attr($0, "iconAssetToken") } == nil ? "missing" : "present")
        """)
        print("""
          Name:             \(loc.flatMap { attr($0, "name") } ?? "—")
          Subtitle:         \(loc.flatMap { attr($0, "subtitle") } ?? "—")
          Privacy policy:   \(loc.flatMap { attr($0, "privacyPolicyUrl") } ?? "—")
          Description:      \((vloc.flatMap { attr($0, "description") as? String })?.prefix(60) ?? "—")…
          Keywords:         \(vloc.flatMap { attr($0, "keywords") } ?? "—")
          Support URL:      \(vloc.flatMap { attr($0, "supportUrl") } ?? "—")
          Copyright:        \(attr(version, "copyright") ?? "—")
          Build attached:   \(attached.map { attr($0, "version") ?? "?" } ?? "none")
          Review details:   \(review.map { "\(attr($0, "contactFirstName") ?? "") \(attr($0, "contactLastName") ?? ""), notes \((attr($0, "notes") as? String)?.count ?? 0) chars" } ?? "none")
          Price schedule:   \(price == nil ? "not set" : "set")
          Availability:     \(avail == nil ? "not set" : "set")
        """)
        return
    }

    if command == "apply" {
        // App-level info.
        try await api("PATCH", "/v1/apps/\(appID)", ["data": ["type": "apps", "id": appID,
            "attributes": ["contentRightsDeclaration": m("contentRights")]]])
        try await api("PATCH", "/v1/appInfos/\(id(info))", ["data": ["type": "appInfos", "id": id(info), "relationships": [
            "primaryCategory": ref("appCategories", m("primaryCategory")),
            "secondaryCategory": ref("appCategories", m("secondaryCategory"))]]])
        say("Set content rights and categories.")

        let infoLocs = try await list("/v1/appInfos/\(id(info))/appInfoLocalizations")
        let infoAttrs: JSON = ["name": m("name"), "subtitle": m("subtitle"), "privacyPolicyUrl": m("privacyPolicyUrl")]
        if let loc = infoLocs.first(where: { attr($0, "locale") as? String == locale }) {
            try await api("PATCH", "/v1/appInfoLocalizations/\(id(loc))", ["data": ["type": "appInfoLocalizations", "id": id(loc), "attributes": infoAttrs]])
        } else {
            try await api("POST", "/v1/appInfoLocalizations", ["data": ["type": "appInfoLocalizations",
                "attributes": infoAttrs.merging(["locale": locale]) { a, _ in a }, "relationships": ["appInfo": ref("appInfos", id(info))]]])
        }
        say("Set name, subtitle and privacy policy URL.")

        // Age rating: answer "none" to everything Flick doesn't have.
        if let decl = try await one("/v1/appInfos/\(id(info))/ageRatingDeclaration") {
            let noneEnums: Set = ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons",
                "horrorOrFearThemes", "matureOrSuggestiveThemes", "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
                "sexualContentGraphicAndNudity", "sexualContentOrNudity", "violenceCartoonOrFantasy", "violenceRealistic",
                "violenceRealisticProlongedGraphicOrSadistic"]
            let falseBools: Set = ["gambling", "unrestrictedWebAccess", "lootBox", "advertising", "ageAssurance",
                "healthOrWellnessTopics", "messagingAndChat", "parentalControls", "userGeneratedContent"]
            var set: JSON = [:]
            for (k, v) in (decl["attributes"] as? JSON ?? [:]) where v is NSNull {
                if noneEnums.contains(k) { set[k] = "NONE" } else if falseBools.contains(k) { set[k] = false }
            }
            if !set.isEmpty {
                try await api("PATCH", "/v1/ageRatingDeclarations/\(id(decl))", ["data": ["type": "ageRatingDeclarations", "id": id(decl), "attributes": set]])
            }
            say("Age rating: answered \(set.count) questions with None/No.")
        }

        // Free, available everywhere except China mainland (which requires an ICP filing).
        if try await one("/v1/apps/\(appID)/appPriceSchedule") == nil {
            let points = try await list("/v1/apps/\(appID)/appPricePoints?filter[territory]=USA&limit=200")
            guard let free = points.first(where: { Double(attr($0, "customerPrice") as? String ?? "1") == 0 }) else { fail("No free price point found.") }
            try await api("POST", "/v1/appPriceSchedules", [
                "data": ["type": "appPriceSchedules", "relationships": [
                    "app": ref("apps", appID), "baseTerritory": ref("territories", "USA"),
                    "manualPrices": ["data": [["type": "appPrices", "id": "${free}"]]]]],
                "included": [["type": "appPrices", "id": "${free}", "attributes": ["startDate": NSNull()],
                              "relationships": ["appPricePoint": ref("appPricePoints", id(free))]]]])
            say("Price: Free.")
        } else { say("Price already set.") }
        if try await one("/v1/apps/\(appID)/appAvailabilityV2") == nil {
            let territories = try await list("/v1/territories?limit=200").map(id).filter { $0 != "CHN" }
            try await api("POST", "/v2/appAvailabilities", [
                "data": ["type": "appAvailabilities", "attributes": ["availableInNewTerritories": true], "relationships": [
                    "app": ref("apps", appID),
                    "territoryAvailabilities": ["data": territories.map { ["type": "territoryAvailabilities", "id": "${\($0)}"] }]]],
                "included": territories.map { ["type": "territoryAvailabilities", "id": "${\($0)}", "attributes": ["available": true],
                                               "relationships": ["territory": ref("territories", $0)]] }])
            say("Availability: \(territories.count) countries and regions (all except China mainland).")
        } else { say("Availability already set.") }

        // Version: text, copyright, release.
        try await api("PATCH", "/v1/appStoreVersions/\(versionID)", ["data": ["type": "appStoreVersions", "id": versionID,
            "attributes": ["copyright": m("copyright"), "releaseType": "AFTER_APPROVAL"]]])
        let vlocs = try await list("/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations")
        let vattrs: JSON = ["description": m("description"), "keywords": m("keywords"), "promotionalText": m("promotionalText"),
                            "supportUrl": m("supportUrl"), "marketingUrl": m("marketingUrl")]
        var vlocID: String
        if let vloc = vlocs.first(where: { attr($0, "locale") as? String == locale }) {
            vlocID = id(vloc)
            try await api("PATCH", "/v1/appStoreVersionLocalizations/\(vlocID)", ["data": ["type": "appStoreVersionLocalizations", "id": vlocID, "attributes": vattrs]])
        } else {
            let r = try await api("POST", "/v1/appStoreVersionLocalizations", ["data": ["type": "appStoreVersionLocalizations",
                "attributes": vattrs.merging(["locale": locale]) { a, _ in a }, "relationships": ["appStoreVersion": ref("appStoreVersions", versionID)]]])
            vlocID = id(r["data"] as! JSON)
        }
        say("Set description, keywords, promotional text, support and marketing URLs, copyright.")

        // Screenshots: replace whatever is in the set with ours.
        let sets = try await list("/v1/appStoreVersionLocalizations/\(vlocID)/appScreenshotSets")
        var setID: String
        if let s = sets.first(where: { attr($0, "screenshotDisplayType") as? String == m("screenshotDisplayType") }) {
            setID = id(s)
            for shot in try await list("/v1/appScreenshotSets/\(setID)/appScreenshots") { try await api("DELETE", "/v1/appScreenshots/\(id(shot))") }
        } else {
            let r = try await api("POST", "/v1/appScreenshotSets", ["data": ["type": "appScreenshotSets",
                "attributes": ["screenshotDisplayType": m("screenshotDisplayType")],
                "relationships": ["appStoreVersionLocalization": ref("appStoreVersionLocalizations", vlocID)]]])
            setID = id(r["data"] as! JSON)
        }
        for path in meta["screenshots"] as! [String] {
            try await upload(root.appendingPathComponent(path), type: "appScreenshots", relationship: "appScreenshotSet", parent: ("appScreenshotSets", setID))
        }
        say("Uploaded \((meta["screenshots"] as! [String]).count) screenshots.")

        // Build.
        guard let build, attr(build, "processingState") as? String == "VALID" else { fail("Build \(m("buildNumber")) isn't processed yet. Try again in a few minutes.") }
        try await api("PATCH", "/v1/appStoreVersions/\(versionID)/relationships/build", ["data": ["type": "builds", "id": id(build)]])
        say("Attached build \(m("versionString")) (\(m("buildNumber"))).")

        // App Review information and attachment.
        let reviewAttrs: JSON = ["contactFirstName": need("ASC_CONTACT_FIRST"), "contactLastName": need("ASC_CONTACT_LAST"),
            "contactPhone": need("ASC_CONTACT_PHONE"), "contactEmail": need("ASC_CONTACT_EMAIL"),
            "demoAccountRequired": false, "notes": m("reviewNotes")]
        var reviewID: String
        if let r = try await one("/v1/appStoreVersions/\(versionID)/appStoreReviewDetail") {
            reviewID = id(r)
            try await api("PATCH", "/v1/appStoreReviewDetails/\(reviewID)", ["data": ["type": "appStoreReviewDetails", "id": reviewID, "attributes": reviewAttrs]])
        } else {
            let r = try await api("POST", "/v1/appStoreReviewDetails", ["data": ["type": "appStoreReviewDetails", "attributes": reviewAttrs,
                "relationships": ["appStoreVersion": ref("appStoreVersions", versionID)]]])
            reviewID = id(r["data"] as! JSON)
        }
        say("Set App Review contact and notes.")
        if let path = env["ASC_REVIEW_ATTACHMENT"] {
            let file = URL(fileURLWithPath: path, relativeTo: root)
            let existing = try await list("/v1/appStoreReviewDetails/\(reviewID)/appStoreReviewAttachments")
            if existing.contains(where: { attr($0, "fileName") as? String == file.lastPathComponent }) {
                say("Review attachment \(file.lastPathComponent) is already there.")
            } else {
                try await upload(file, type: "appStoreReviewAttachments", relationship: "appStoreReviewDetail", parent: ("appStoreReviewDetails", reviewID))
                say("Attached \(file.lastPathComponent) for App Review.")
            }
        }
        say("Done. Run 'check' to review, then 'submit'.")
        return
    }

    // submit
    let open = try await list("/v1/reviewSubmissions?filter[app]=\(appID)&filter[state]=READY_FOR_REVIEW&filter[platform]=IOS").first
    let submissionID: String
    if let open { submissionID = id(open) } else {
        let r = try await api("POST", "/v1/reviewSubmissions", ["data": ["type": "reviewSubmissions",
            "attributes": ["platform": "IOS"], "relationships": ["app": ref("apps", appID)]]])
        submissionID = id(r["data"] as! JSON)
    }
    let items = try await list("/v1/reviewSubmissions/\(submissionID)/items")
    if items.isEmpty {
        try await api("POST", "/v1/reviewSubmissionItems", ["data": ["type": "reviewSubmissionItems", "relationships": [
            "reviewSubmission": ref("reviewSubmissions", submissionID), "appStoreVersion": ref("appStoreVersions", versionID)]]])
    }
    try await api("PATCH", "/v1/reviewSubmissions/\(submissionID)", ["data": ["type": "reviewSubmissions", "id": submissionID,
        "attributes": ["submitted": true]]])
    say("Submitted for App Review.")
}

let done = DispatchSemaphore(value: 0)
Task {
    do { try await run() } catch { FileHandle.standardError.write(Data("Error: \(error)\n".utf8)); exit(1) }
    done.signal()
}
done.wait()
