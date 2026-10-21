import Foundation

// MARK: - 判断层：TypeSafe Jev / System One 客户端
//
// Jev 是结构化决策模型：给它一个 state 加一组带类型的题目，返回校准过的概率而不是文字。
// 与 macOS 版 src/judge_jev.py 同一请求形状：
//   POST {base}/v1/systemone   Authorization: Bearer <key>
//   {"model": …, "state": …, "questions": {intent: choice, risk: score}}
// 排序只是又一道 choice 题：把候选文本当选项，哪条最合适。

struct JudgeResult: Equatable {
    var intent: String
    var confidence: Double
    var intentProbs: [String: Double]
    var risk: Double
    var riskProbs: [String: Double]
    var actions: [String]

    var riskLevelText: String { riskLabel(for: risk) }
}

struct RankedCandidate: Equatable {
    var text: String
    var prob: Double
}

/// 判断结果的内存缓存。实测判断一次要一秒多，而「换一批」是对同一条消息反复分析——
/// 判断结论不会变，没必要每次重付一次往返。只在进程内、不落盘；换了消息自然失效。
final class JevJudgeCache {
    static let shared = JevJudgeCache()

    private struct Key: Hashable {
        let message: String
        let context: String
    }

    private var store: [Key: (result: JudgeResult, at: Date)] = [:]
    private let ttl: TimeInterval = 300
    private let lock = NSLock()

    func get(message: String, context: String?) -> JudgeResult? {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(message: message, context: context ?? "")
        guard let hit = store[key], Date().timeIntervalSince(hit.at) < ttl else { return nil }
        return hit.result
    }

    func put(_ result: JudgeResult, message: String, context: String?) {
        lock.lock()
        defer { lock.unlock() }
        if store.count > 8 { store.removeAll() }
        store[Key(message: message, context: context ?? "")] = (result, Date())
    }
}

final class JevJudge {
    private let base: String
    private let key: String
    private let model: String

    init(cfg: JevConfig) {
        self.base = cfg.judgeBase.trimmingCharacters(in: .whitespaces)
        self.key = cfg.judgeKey.trimmingCharacters(in: .whitespaces)
        self.model = cfg.judgeModel.trimmingCharacters(in: .whitespaces)
    }

    var isConfigured: Bool { !key.isEmpty && !base.isEmpty && !model.isEmpty }

    // MARK: URL 拼接（与 macOS 版 #42 单一规则一致）
    //
    // 三种填法等价可用：只到主机（…/v1/systemone 自动补）、带版本段（…/v1 只补动作段）、
    // 完整动作路径（原样使用）。网关可以改名动作段（Vercel 是 /v1/evaluate、
    // OpenRouter 是 /api/alpha/decisions）。

    static func requestURL(_ rawBase: String) -> String {
        let b = rawBase.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        let segs = b.split(separator: "/").map(String.init)
        guard let last = segs.last?.lowercased() else { return b }
        let actionSegs: Set<String> = ["systemone", "evaluate", "decisions"]
        if actionSegs.contains(last) { return b }
        if last.range(of: #"^v\d+$"#, options: .regularExpression) != nil { return b + "/systemone" }
        return b + "/v1/systemone"
    }

    /// 判断层用的是 TypeSafe Jev 的 systemone 接口（结构化决策），
    /// 不是通用的 /chat/completions。填了通用大模型服务（DeepSeek、智谱、
    /// OpenAI 兼容网关等）会稳定拿到 404——那个端点在这些服务上根本不存在。
    /// 这时该提示用生成层，而不是让用户盯着一个看不懂的状态码。
    ///
    /// 判据：systemone / evaluate / decisions 这类动作段是 Jev 专用，
    /// 出现在地址里说明就是 Jev 网关；否则一律按「通用服务」处理。
    static func looksLikeGenericService(_ rawBase: String) -> Bool {
        let b = rawBase.trimmingCharacters(in: .whitespaces).lowercased()
        let actionSegs: Set<String> = ["systemone", "evaluate", "decisions"]
        for seg in b.split(separator: "/").map(String.init) {
            if actionSegs.contains(seg) { return false }
        }
        return true
    }

    /// 404 的成因说明。返回 nil 表示不是这个原因。
    static func diagnose404(_ rawBase: String) -> String? {
        guard looksLikeGenericService(rawBase) else { return nil }
        return "判断层只支持 Jev 的 systemone 接口（api.typesafe.ai / OpenRouter / Vercel 网关）。"
            + "你填的是通用大模型服务地址，它没有这个端点，所以返回 404。"
            + "想用 DeepSeek / 智谱这类服务，请把 Key 填到下方「生成层」——那里才是 /chat/completions 形状。"
    }

    // MARK: 通用服务降级（OpenAI 兼容的 /chat/completions）
    //
    // 判断层原本只走 Jev 的 systemone 结构化决策接口。通用模型服务（DeepSeek、智谱…）
    // 没有这个端点，但它们能听懂自然语言指令——于是把「题目 + 评分表」改写成一段
    // 要求模型回 JSON 的 prompt，走标准 chat/completions 端点拿回同样的分布。
    //
    // 与原生路径的差别：概率是模型自报的，不是校准过的；排序同理。
    // 拿不到结构化结果时宁可降级为盲起草，也不要拿猜的分数糊弄界面。
    //
    // 输出格式刻意用「短键名 + 数组」而不是长词：DeepSeek 这类思考型模型会先烧掉
    // 一两千个 reasoning token，max_tokens 给小了正文就被截断（实测踩过：
    // 800 token 时正文只剩 5 个字符）。数组比带描述的字典省一半篇幅。

    /// 通用服务降级用的 prompt。输出格式写死成 JSON，避免模型自由发挥。
    static func genericJudgePrompt(message: String, context: String?) -> String {
        let ctx = (context?.isEmpty == false) ? "最近对话：\n\(context!)\n\n" : ""
        return """
        分析下面这条中文聊天消息，只输出 JSON，不要思考、不要解释。

        \(ctx)消息：「\(message)」

        意图（8 选 1）：\(INTENTS.keys.joined(separator: "/"))
        风险：0-9 分

        输出格式：
        {"intent":"派活","ip":{"派活":0.7,"催进度":0.2,"问进度":0.05,"批评":0.01,"要解释":0.01,"闲聊":0.02,"约会议":0.005,"夸奖":0.005},"risk":3.2,"rp":[0.02,0.05,0.2,0.3,0.2,0.1,0.05,0.03,0.02,0.01]}
        说明：ip 是 8 个意图按上面顺序的概率；rp 是 0-9 各整数分的概率，按顺序。
        """
    }

    /// 通用服务降级用的排序 prompt。
    static func genericRankPrompt(message: String, intent: String, candidates: [String]) -> String {
        let list = candidates.enumerated()
            .map { "\($0.offset+1). \($0.element)" }.joined(separator: "\n")
        return """
        给下面每条中文回复候选打分（0-1，越高越适合直接发出），只输出 JSON，不要思考、不要解释。

        收到的消息：「\(message)」
        判定出的意图：\(intent)

        候选回复：
        \(list)

        输出格式：
        {"pp":{"<候选原文>":0.8,"<候选原文>":0.5}}
        """
    }

    // MARK: 判断（意图 + 风险，一次调用出全分布）

    func judge(message: String, context: String?) async throws -> JudgeResult {
        // 通用服务走降级路径：把题目改写成 prompt，标准 chat/completions 拿回 JSON。
        if Self.looksLikeGenericService(base) {
            return try await judgeGeneric(message: message, context: context)
        }
        let state = context != nil && !context!.isEmpty ? "\(context!)\n\n\(message)" : message
        let payload: [String: Any] = [
            "model": model,
            "state": state,
            "questions": [
                "intent": [
                    "type": "choice",
                    "instructions": "这句话的真实意图是什么？",
                    "criteria": INTENTS,
                ] as [String: Any],
                "risk": [
                    "type": "score",
                    "instructions": "如果直接回复这句话，风险有多大？",
                    "criteria": RISK_LEVELS,
                ] as [String: Any],
            ],
        ]
        let data = try await post(payload, stage: "判断")
        let answers = data["answers"] as? [String: Any] ?? [:]
        let intentAns = answers["intent"] as? [String: Any] ?? [:]
        let riskAns = answers["risk"] as? [String: Any] ?? [:]

        var intent = intentAns["choice"] as? String ?? "闲聊"
        if !INTENTS.keys.contains(intent) {
            // 网关偶尔回显下标或近似标签
            intent = INTENTS.keys.first { intent.contains($0) } ?? "闲聊"
        }
        let confidence = doubleValue(intentAns["confidence"])
        let risk = doubleValue(riskAns["score"])
        return JudgeResult(
            intent: intent,
            confidence: confidence,
            intentProbs: doubleDict(intentAns["probabilities"]),
            risk: risk,
            riskProbs: doubleDict(riskAns["probabilities"]),
            actions: ACTION_MAP[intent] ?? []
        )
    }

    // MARK: 排序（候选文本当 choice 选项）

    func rank(message: String, intent: String, candidates: [String]) async throws -> [RankedCandidate] {
        guard !candidates.isEmpty else { return [] }
        if Self.looksLikeGenericService(base) {
            return try await rankGeneric(message: message, intent: intent, candidates: candidates)
        }
        // 去重后再当选项：两个槽位选了同一个话术时，模型很可能给出两条一模一样的候选，
        // 而字典键不能重复（用 uniqueKeysWithValues 会直接 trap 崩掉键盘）。
        let criteria = Dictionary(candidates.map { ($0, NSNull()) }, uniquingKeysWith: { first, _ in first })
        let payload: [String: Any] = [
            "model": model,
            "state": "收到的消息：\(message)\n判断出的意图：\(intent)",
            "questions": [
                "best": [
                    "type": "choice",
                    "instructions": "哪一条回复最合适？",
                    "criteria": criteria,
                ] as [String: Any],
            ],
        ]
        let data = try await post(payload, stage: "排序")
        let ans = (data["answers"] as? [String: Any])?["best"] as? [String: Any] ?? [:]
        let probs = doubleDict(ans["probabilities"])
        var ranked = candidates.map { c -> RankedCandidate in
            var p = probs[c] ?? 0
            if p == 0, let choice = ans["choice"] as? String, choice == c {
                p = doubleValue(ans["confidence"])   // 网关可能只回显选中项
            }
            return RankedCandidate(text: c, prob: p)
        }
        ranked.sort { $0.prob > $1.prob }
        return ranked
    }

    // MARK: 通用服务降级实现

    /// 通用服务：把题目写成 prompt，走 /chat/completions，要求模型回 JSON。
    private func judgeGeneric(message: String, context: String?) async throws -> JudgeResult {
        let prompt = Self.genericJudgePrompt(message: message, context: context)
        let raw = try await callGeneric(prompt: prompt, stage: "判断")
        let obj = try JevHTTP.parseJSONObject(raw)

        // 意图：模型可能回近似标签，按包含关系兜底
        var intent = (obj["intent"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !INTENTS.keys.contains(intent) {
            intent = INTENTS.keys.first { intent.contains($0) } ?? "闲聊"
        }
        // ip：8 个意图的概率字典
        let intentProbs = doubleDict(obj["ip"])
        // 置信度：优先用模型给的意图概率；没给就用分布里的最大值
        let confidence = intentProbs[intent] ?? intentProbs.values.max() ?? 0
        let risk = min(max(doubleValue(obj["risk"]), 0), 9)
        // rp：0-9 各整数分的概率数组，转成字典给界面用
        var riskProbs: [String: Double] = [:]
        if let arr = obj["rp"] as? [Any] {
            for (i, v) in arr.enumerated() where i < 10 {
                riskProbs["\(i)"] = doubleValue(v)
            }
        }
        return JudgeResult(
            intent: intent,
            confidence: confidence,
            intentProbs: intentProbs,
            risk: risk,
            riskProbs: riskProbs,
            actions: ACTION_MAP[intent] ?? []
        )
    }

    /// 通用服务：排序走 prompt + JSON。
    private func rankGeneric(message: String, intent: String, candidates: [String]) async throws -> [RankedCandidate] {
        let prompt = Self.genericRankPrompt(message: message, intent: intent, candidates: candidates)
        let raw = try await callGeneric(prompt: prompt, stage: "排序")
        let obj = try JevHTTP.parseJSONObject(raw)
        let probs = doubleDict(obj["pp"])
        var ranked = candidates.map { c in
            RankedCandidate(text: c, prob: probs[c] ?? 0)
        }
        ranked.sort { $0.prob > $1.prob }
        return ranked
    }

    /// 通用服务的实际请求：标准 OpenAI 兼容形状。
    ///
    /// max_tokens 给到 4000 是被实测逼出来的：DeepSeek 的 deepseek-flash 是思考型模型，
    /// 会先烧掉 500~2000 个 reasoning token，800 上限时正文只剩几个字符就被截断
    /// （finish_reason = length，解析必然失败）。4000 下 8 条测试消息全部拿到完整 JSON。
    private func callGeneric(prompt: String, stage: String) async throws -> String {
        let url = JevDraft.chatURL(base, kind: .openai)
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 4000,
            "temperature": 0.2,
            "stream": false,
        ]
        let data = try await JevHTTP.postJSON(
            body,
            url: url,
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(key)",
            ],
            budget: stage == "判断" ? 30 : 20,
            stage: stage
        )
        return try JevDraft.extractText(data, kind: .openai, model: model)
    }

    // MARK: transport

    private func post(_ payload: [String: Any], stage: String) async throws -> [String: Any] {
        do {
            return try await JevHTTP.postJSON(
                payload,
                url: Self.requestURL(base),
                headers: [
                    "Content-Type": "application/json",
                    "Authorization": "Bearer \(key)",
                ],
                budget: stage == "判断" ? 15 : 12,
                stage: stage
            )
        } catch let e as JevError {
            // 404 在这里几乎总是「端点不存在」而不是「资源不存在」，
            // 而判断层用的是非标准端点，通用服务一律 404。给出可操作的说明。
            if case .http(404, _) = e, let hint = Self.diagnose404(base) {
                throw JevError.config(hint)
            }
            throw e
        }
    }

    private func doubleValue(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    private func doubleDict(_ v: Any?) -> [String: Double] {
        guard let d = v as? [String: Any] else { return [:] }
        return d.mapValues(doubleValue)
    }
}
