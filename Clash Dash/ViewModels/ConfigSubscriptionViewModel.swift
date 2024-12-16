import Foundation

@MainActor
class ConfigSubscriptionViewModel: ObservableObject {
    @Published var subscriptions: [ConfigSubscription] = []
    @Published var isLoading = false
    @Published var showError = false
    @Published var errorMessage: String?
    @Published var templateOptions: [String] = []
    
    private let server: ClashServer
    
    init(server: ClashServer) {
        self.server = server
    }
    
    func loadSubscriptions() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            subscriptions = try await fetchSubscriptions()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func parseSubscription(_ line: String) -> (key: String, value: String)? {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        
        let key = String(parts[0])
        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
        
        if key.contains(".sub_ua") {
            return (key, value.replacingOccurrences(of: "'", with: "").lowercased())
        }
        
        if key.contains(".enabled") {
            return (key, value.replacingOccurrences(of: "'", with: ""))
        }
        
        if key.contains(".name") || key.contains(".address") {
            return (key, value.replacingOccurrences(of: "'", with: ""))
        }
        
        return (key, value)
    }
    
    private func fetchSubscriptions() async throws -> [ConfigSubscription] {
        let token = try await getAuthToken()
        
        // 构建请求
        let scheme = server.useSSL ? "https" : "http"
        let baseURL = "\(scheme)://\(server.url):\(server.openWRTPort ?? "80")"
        guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sysauth=\(token)", forHTTPHeaderField: "Cookie")
        
        let command: [String: Any] = [
            "method": "exec",
            "params": ["uci show openclash | grep \"config_subscribe\" | sed 's/openclash\\.//g' | sort"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: command)
        
        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NetworkError.serverError(500)
        }
        
        struct UCIResponse: Codable {
            let result: String
            let error: String?
        }
        
        let uciResponse = try JSONDecoder().decode(UCIResponse.self, from: data)
        if let error = uciResponse.error, !error.isEmpty {
            throw NetworkError.serverError(500)
        }
        
        // 解析结果
        var subscriptions: [ConfigSubscription] = []
        var currentId: Int?
        var currentSub = ConfigSubscription()
        
        let lines = uciResponse.result.components(separatedBy: "\n")
        for line in lines {
            guard let (key, value) = parseSubscription(line) else { continue }
            
            if key.hasPrefix("@config_subscribe[") {
                if let idStr = key.firstMatch(of: /\[(\d+)\]/)?.1,
                   let id = Int(idStr) {
                    if id != currentId {
                        if currentId != nil {
                            subscriptions.append(currentSub)
                        }
                        currentId = id
                        currentSub = ConfigSubscription(id: id)
                    }
                    
                    if key.contains(".name") {
                        currentSub.name = value
                    } else if key.contains(".address") {
                        currentSub.address = value
                    } else if key.contains(".enabled") {
                        currentSub.enabled = value == "1"
                    } else if key.contains(".sub_ua") {
                        currentSub.subUA = value
                    } else if key.contains(".sub_convert") {
                        currentSub.subConvert = value == "1"
                    } else if key.contains(".convert_address") {
                        currentSub.convertAddress = value
                    } else if key.contains(".template") {
                        currentSub.template = value
                    } else if key.contains(".emoji") {
                        currentSub.emoji = value == "true"
                    } else if key.contains(".udp") {
                        currentSub.udp = value == "true"
                    } else if key.contains(".skip_cert_verify") {
                        currentSub.skipCertVerify = value == "true"
                    } else if key.contains(".sort") {
                        currentSub.sort = value == "true"
                    } else if key.contains(".node_type") {
                        currentSub.nodeType = value == "true"
                    } else if key.contains(".rule_provider") {
                        currentSub.ruleProvider = value == "true"
                    } else if key.contains(".keyword") {
                        let cleanValue = value.trimmingCharacters(in: .whitespaces)
                        if currentSub.keyword == nil {
                            currentSub.keyword = cleanValue
                        } else {
                            currentSub.keyword! += " " + cleanValue
                        }
                        print("处理关键词: \(cleanValue)") // 添加调试日志
                    } else if key.contains(".ex_keyword") {
                        let cleanValue = value.trimmingCharacters(in: .whitespaces)
                        if currentSub.exKeyword == nil {
                            currentSub.exKeyword = cleanValue
                        } else {
                            currentSub.exKeyword! += " " + cleanValue
                        }
                        print("处理排除关键词: \(cleanValue)") // 添加调试日志
                    }
                }
            }
        }
        
        if currentId != nil {
            subscriptions.append(currentSub)
        }
        
        return subscriptions
    }
    
    private func getAuthToken() async throws -> String {
        guard let username = server.openWRTUsername,
              let password = server.openWRTPassword else {
            throw NetworkError.unauthorized
        }
        
        let scheme = server.useSSL ? "https" : "http"
        let baseURL = "\(scheme)://\(server.url):\(server.openWRTPort ?? "80")"
        guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/auth") else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "id": 1,
            "method": "login",
            "params": [username, password]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NetworkError.unauthorized
        }
        
        struct AuthResponse: Codable {
            let result: String?
            let error: String?
        }
        
        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        guard let token = authResponse.result else {
            throw NetworkError.unauthorized
        }
        
        return token
    }
    
    func addSubscription(_ subscription: ConfigSubscription) async {
        // TODO: 实现添加订阅逻辑
    }

        // 修改解析关键词的方法
    func parseKeywordValues(_ input: String?) -> [String] {
        guard let input = input else { return [] }
        
        print("解析关键词输入: \(input)") // 添加调试日志
        
        // 使用正则表达式匹配单引号之间的内容
        let pattern = "'([^']+)'"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            print("正则表达式创建失败") // 添加调试日志
            return []
        }
        
        let range = NSRange(location: 0, length: input.utf16.count)
        let matches = regex.matches(in: input, range: range)
        
        let words = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: input) else { return nil }
            let word = String(input[range])
            print("匹配到关键词: \(word)") // 添加调试日志
            return word
        }
        
        print("解析结果: \(words)") // 添加调试日志
        return words
    }
    
    func updateSubscription(_ subscription: ConfigSubscription) async {
        do {
            print("🔄 开始更新订阅: \(subscription.name)")
            print("📝 当前订阅状态:")
            printSubscriptionState(subscription)
            
            let token = try await getAuthToken()
            
            if let oldSub = subscriptions.first(where: { $0.id == subscription.id }) {
                print("\n📝 对比旧订阅状态:")
                printSubscriptionState(oldSub)
                
                print("\n📝 检查字段更改...")
                var commands: [String] = []
                
                // 基本字段比较
                if oldSub.name != subscription.name {
                    commands.append("uci set openclash.@config_subscribe[\(subscription.id)].name='\(subscription.name)'")
                }
                if oldSub.address != subscription.address {
                    commands.append("uci set openclash.@config_subscribe[\(subscription.id)].address='\(subscription.address)'")
                }
                if oldSub.subUA != subscription.subUA {
                    commands.append("uci set openclash.@config_subscribe[\(subscription.id)].sub_ua='\(subscription.subUA)'")
                }
                if oldSub.enabled != subscription.enabled {
                    commands.append("uci set openclash.@config_subscribe[\(subscription.id)].enabled='\(subscription.enabled ? "1" : "0")'")
                }
                if oldSub.subConvert != subscription.subConvert {
                    commands.append("uci set openclash.@config_subscribe[\(subscription.id)].sub_convert='\(subscription.subConvert ? "1" : "0")'")
                }
                
                // 转换选项比较
                if subscription.subConvert {
                    if oldSub.convertAddress != subscription.convertAddress {
                        if let addr = subscription.convertAddress {
                            commands.append("uci set openclash.@config_subscribe[\(subscription.id)].convert_address='\(addr)'")
                        }
                    }
                    if oldSub.template != subscription.template {
                        if let template = subscription.template {
                            commands.append("uci set openclash.@config_subscribe[\(subscription.id)].template='\(template)'")
                        }
                    }

                    // 布尔值选项：当 subConvert 为 true 时，始终设置值
                    let boolOptions = [
                        "emoji": subscription.emoji,
                        "udp": subscription.udp,
                        "skip_cert_verify": subscription.skipCertVerify,
                        "sort": subscription.sort,
                        "node_type": subscription.nodeType,
                        "rule_provider": subscription.ruleProvider
                    ]
                    
                    for (key, value) in boolOptions {
                        // 如果值为 nil 或为 false，设置为 false
                        // 如果值为 true，设置为 true
                        let finalValue = value ?? false
                        commands.append("uci set openclash.@config_subscribe[\(subscription.id)].\(key)='\(finalValue ? "true" : "false")'")
                    }
                }
                
                // 关键词比较
                if oldSub.keyword != subscription.keyword {
                        
                    let keywords = parseKeywordValues(subscription.keyword) // 使用新的解析方法
                    
                    if !keywords.isEmpty{
                    // 只有当旧值存在时才发送 delete 命令
                        if oldSub.keyword != nil {
                            commands.append("uci delete openclash.@config_subscribe[\(subscription.id)].keyword")
                        }
                        for keyword in keywords {
                            print("添加关键词: \(keyword)")
                            commands.append("uci add_list openclash.@config_subscribe[\(subscription.id)].keyword='\(keyword)'")
                        }
                    }else {
                            commands.append("uci delete openclash.@config_subscribe[\(subscription.id)].keyword")
                    }
                }
                
                // 排除关键词比较
                if oldSub.exKeyword != subscription.exKeyword {
                    let keywords = parseKeywordValues(subscription.exKeyword) // 使用新的解析方法
                    if !keywords.isEmpty{
                    // 只有当旧值存在时才发送 delete 命令
                        if oldSub.exKeyword != nil {
                            commands.append("uci delete openclash.@config_subscribe[\(subscription.id)].ex_keyword")
                        }
                        for keyword in keywords {
                            print("添加关键词: \(keyword)")
                            commands.append("uci add_list openclash.@config_subscribe[\(subscription.id)].ex_keyword='\(keyword)'")
                        }
                    }else{
                       commands.append("uci delete openclash.@config_subscribe[\(subscription.id)].ex_keyword")
                    }
                }
                
                // 自定义参数比较
                if oldSub.customParams != subscription.customParams {
                    if let params = subscription.customParams {
                        if oldSub.customParams != nil {
                            commands.append("uci delete openclash.@config_subscribe[\(subscription.id)].custom_params")
                        }
                        for param in params {
                            commands.append("uci add_list openclash.@config_subscribe[\(subscription.id)].custom_params='\(param)'")
                        }
                    }
                }
                
                if commands.isEmpty {
                    print("ℹ️ 没有字段被更改，跳过更新")
                    return
                }
                
                // 构建请求
                let scheme = server.useSSL ? "https" : "http"
                let baseURL = "\(scheme)://\(server.url):\(server.openWRTPort ?? "80")"
                guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
                    throw NetworkError.invalidURL
                }
                
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("sysauth=\(token)", forHTTPHeaderField: "Cookie")
                
                let command: [String: Any] = [
                    "method": "exec",
                    "params": [commands.joined(separator: " && ")]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: command)
                
                let session = URLSession.shared
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    print("❌ 服务器返回错误状态码: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    throw NetworkError.serverError(500)
                }
                
                struct UCIResponse: Codable {
                    let result: String
                    let error: String?
                }
                
                let uciResponse = try JSONDecoder().decode(UCIResponse.self, from: data)
                if let error = uciResponse.error, !error.isEmpty {
                    print("UCI命令执行失败: \(error)")
                    throw NetworkError.serverError(500)
                }

                print("📤 发送的命令:")
                print(commands.joined(separator: " && "))
                
                print("✅ UCI命令执行成功")
                
                // 提交更改
                try await commitChanges(token: token)
                print("✅ 更改已提��")
                
                // 重新加载订阅列表
                await loadSubscriptions()
                print("✅ 订阅列表已刷新")
            }
            
        } catch {
            print("❌ 更新订阅失败: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    func toggleSubscription(_ subscription: ConfigSubscription, enabled: Bool) async {
        print("🔄 切换订阅状态: \(subscription.name) -> \(enabled ? "启用" : "禁用")")
        do {
            let token = try await getAuthToken()
            
            // 构建请求
            let scheme = server.useSSL ? "https" : "http"
            let baseURL = "\(scheme)://\(server.url):\(server.openWRTPort ?? "80")"
            guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
                throw NetworkError.invalidURL
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("sysauth=\(token)", forHTTPHeaderField: "Cookie")
            
            let command: [String: Any] = [
                "method": "exec",
                "params": ["uci set openclash.@config_subscribe[\(subscription.id)].enabled='\(enabled ? "1" : "0")' && uci commit openclash"]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: command)
            
            print("📤 发送切换命令...")
            let session = URLSession.shared
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("❌ 服务器返回错误状态码: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                throw NetworkError.serverError(500)
            }
            
            struct UCIResponse: Codable {
                let result: String
                let error: String?
            }
            
            let uciResponse = try JSONDecoder().decode(UCIResponse.self, from: data)
            if let error = uciResponse.error, !error.isEmpty {
                print("❌ UCI命令执行失败: \(error)")
                throw NetworkError.serverError(500)
            }
            
            print("✅ UCI命令执行成功")
            
            // 提交更改
            try await commitChanges(token: token)
            print("✅ 更改已提交")
            
            // 重新加载订阅列表
            await loadSubscriptions()
            print("✅ 订阅列表已刷新")
            
        } catch {
            print("❌ 切换订阅状态失败: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func commitChanges(token: String) async throws {
        let scheme = server.useSSL ? "https" : "http"
        let baseURL = "\(scheme)://\(server.url):\(server.openWRTPort ?? "80")"
        guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
            throw NetworkError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sysauth=\(token)", forHTTPHeaderField: "Cookie")
        
        let command: [String: Any] = [
            "method": "exec",
            "params": ["uci commit openclash"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: command)
        
        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NetworkError.serverError(500)
        }
        
        struct UCIResponse: Codable {
            let result: String
            let error: String?
        }
        
        let uciResponse = try JSONDecoder().decode(UCIResponse.self, from: data)
        if let error = uciResponse.error, !error.isEmpty {
            throw NetworkError.serverError(500)
        }
    }
    
    // 修改格式化关键词的方法
    func formatQuotedValues(_ values: [String]) -> String? {
        let filtered = values.filter { !$0.isEmpty }
        // 每个关键词只需要一层单引号
        let formatted = filtered.isEmpty ? nil : filtered.map { 
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return "'\(trimmed)'"
        }.joined(separator: " ")
        print("格式化关键词: \(values) -> \(formatted ?? "nil")") // 添加调试日志
        return formatted
    }
    
    // 修改解析关键词的方法
    func parseQuotedValues(_ input: String?) -> [String] {
        guard let input = input else { return [] }
        
        print("解析关键词输入: \(input)") // 添加调试日志
        
        // 使用正则表达式匹配单引号之间的内容
        let pattern = "'([^']+)'"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            print("正则表达式创建失败") // 添加调试日志
            return []
        }
        
        let range = NSRange(location: 0, length: input.utf16.count)
        let matches = regex.matches(in: input, range: range)
        
        let words = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: input) else { return nil }
            let word = String(input[range])
            print("匹配到关键词: \(word)") // 添加调试日志
            return word
        }
        
        print("解析结果: \(words)") // 添加调试日志
        return words
    }
    
    // 辅助方法：打印订阅状态
    private func printSubscriptionState(_ subscription: ConfigSubscription) {
        print("- 名称: \(subscription.name.replacingOccurrences(of: "'", with: ""))")
        print("- 地址: \(subscription.address.replacingOccurrences(of: "'", with: ""))")
        print("- 启用状态: \(subscription.enabled)")
        print("- User-Agent: \(subscription.subUA)")
        print("- 订阅转换: \(subscription.subConvert)")
        if subscription.subConvert {
            print("  - 转换地址: \(subscription.convertAddress ?? "无")")
            print("  - 转换模板: \(subscription.template ?? "无")")
            print("  - Emoji: \(subscription.emoji ?? false)")
            print("  - UDP: \(subscription.udp ?? false)")
            print("  - 跳过证书验证: \(subscription.skipCertVerify ?? false)")
            print("  - 排序: \(subscription.sort ?? false)")
            print("  - 节点类型: \(subscription.nodeType ?? false)")
            print("  - 规则集: \(subscription.ruleProvider ?? false)")
            print("  - 自定义参数: \(subscription.customParams ?? [])")
        }
        print("- 包含关键词: \(subscription.keyword ?? "无")")
        print("- 排除关键词: \(subscription.exKeyword ?? "无")")
    }
    
    func loadTemplateOptions() async {
        do {
            let token = try await getAuthToken()
            
            let scheme = server.useSSL ? "https" : "http"
            let baseURL = "\(scheme)://\(server.url):\(server.openWRTPort ?? "80")"
            guard let url = URL(string: "\(baseURL)/cgi-bin/luci/rpc/sys?auth=\(token)") else {
                throw NetworkError.invalidURL
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("sysauth=\(token)", forHTTPHeaderField: "Cookie")
            
            let command: [String: Any] = [
                "method": "exec",
                "params": ["cat /usr/share/openclash/res/sub_ini.list | cut -d',' -f1"]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: command)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw NetworkError.serverError(500)
            }
            
            struct TemplateResponse: Codable {
                let result: String
                let error: String?
            }
            
            let templateResponse = try JSONDecoder().decode(TemplateResponse.self, from: data)
            if let error = templateResponse.error, !error.isEmpty {
                throw NetworkError.serverError(500)
            }
            
            // 解析模板选项
            templateOptions = templateResponse.result
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
        } catch {
            print("加载模板选项失败: \(error)")
        }
    }
} 