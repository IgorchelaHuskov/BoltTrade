//
//   DataProvider.swift
//  Treading
//
//  Created by Igorchela on 9.01.26.
//

import Foundation
import CryptoKit

actor DataProvider {
    private let wsService: WebSocketService
    private let decoder = JSONDecoder()
    
    init(wsService: WebSocketService) {
        self.wsService = wsService
    }
    
    /// Метод, который предоставляет типизированный поток событий стакана
    func subscribeToOrderBook(urlString: String) async -> AsyncStream<OrderBookStreamUpdate> {
        // Получаем сырой поток из транспортного сервиса
        let rawStream = await wsService.start(urlString: urlString)
        
        return AsyncStream { continuation in
            let task = Task {
                // Подписываемся на сырые данные
                for await data in rawStream {
                    guard !Task.isCancelled else { break }
                    do {
                        // Пытаемся декодировать в нашу модель
                        let event = try decoder.decode(OrderBookStreamUpdate.self, from: data)
                        continuation.yield(event)
                    } catch {
                        // Если пришел системный ответ (например, подтверждение подписки)
                        // или битые данные — просто логируем и пропускаем
                        print("Decoding error subscribeToOrderBook: \(error). Raw data: \(String(data: data, encoding: .utf8) ?? "")")
                    }
                }
                continuation.finish()
            }
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task {
                    await self.wsService.disconnect(urlString: urlString)
                }
            }
        }
    }
    
    
    func subscribeToTradeStreams(urlString: String) async -> AsyncStream<TradeStreams> {
        // Получаем сырой поток из транспортного сервиса
        let rawStream = await wsService.start(urlString: urlString)
        
        return AsyncStream { continuation in
            let task = Task {
                // Подписываемся на сырые данные
                for await data in rawStream {
                    guard !Task.isCancelled else { break }
                    do {
                        // Пытаемся декодировать в нашу модель
                        let event = try decoder.decode(TradeStreams.self, from: data)
                        continuation.yield(event)
                    } catch {
                        // Если пришел системный ответ (например, подтверждение подписки)
                        // или битые данные — просто логируем и пропускаем
                        print("Decoding error subscribeToTradeStreams : \(error). Raw data: \(String(data: data, encoding: .utf8) ?? "")")
                    }
                }
                continuation.finish()
            }
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task {
                    await self.wsService.disconnect(urlString: urlString)
                }
            }
        }
    }
    
    
    func fetchSnapshot() async throws -> OrderBookSnapshot {
        guard let urlString = await APIConfig.shared?.binanceOrderBookURL else { throw ApiError.invalidData }
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ApiError.requestFailed(description: "Invalid response type")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw ApiError.invalidStatusCode(statusCode: httpResponse.statusCode)
        }
        
        let snapshot = try decoder.decode(OrderBookSnapshot.self, from: data)
        
        return snapshot
    }
    
    
    func fetchCandle(symbol: String = "BTCUSDT",
                     interval: String = "15m",
                     limit: Int = 1000,
                     startTime: Int64? = nil,
                     endTime: Int64? = nil) async throws -> [Candle] {
        guard let base = await APIConfig.shared?.binanceKlineURL else { throw ApiError.invalidData }
        guard var components = URLComponents(string: base + "/api/v3/klines") else { throw URLError(.badURL) }
        
        var queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "interval", value: interval),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        
        if let start = startTime { queryItems.append(URLQueryItem(name: "startTime", value: "\(start)")) }
        if let end = endTime { queryItems.append(URLQueryItem(name: "endTime", value: "\(end)")) }
        
        components.queryItems = queryItems
        
        guard let url = components.url else { throw URLError(.badURL) }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ApiError.requestFailed(description: "Invalid response type")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw ApiError.invalidStatusCode(statusCode: httpResponse.statusCode)
        }
        
        let result = try decoder.decode([Candle].self, from: data)
        
        return result
    }
    
    private func generateSignature(query: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(query.utf8), using: key)
        return signature.map { String(format: "%02hhx", $0) }.joined()
    }


    
    func fetchAccountBalance() async throws -> BinanceAccountResponse {
        guard let config = await APIConfig.shared else { throw ApiError.invalidData }
        
        let baseUrl = config.binancefutureURL // https://binancefuture.com
        let path = "/fapi/v2/account"
        
        // 1. Готовим параметры (только timestamp для этого эндпоинта)
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let queryString = "timestamp=\(timestamp)"
        
        // 2. Генерируем подпись на основе queryString
        let signature = generateSignature(query: queryString, secret: config.secretKey)
        
        // 3. Собираем итоговый URL
        let urlString = "\(baseUrl)\(path)?\(queryString)&signature=\(signature)"
        guard let url = URL(string: urlString) else { throw ApiError.invalidData }
        
        // 4. Формируем HTTP запрос
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(config.apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        request.timeoutInterval = 10
        
        // 5. Выполняем запрос
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Проверка на ошибки сервера (например, 401 или 400)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let serverError = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ Binance REST Error: \(serverError)")
            throw ApiError.invalidData
        }
        
        // 6. Декодируем массив балансов прямо из data
        let decoder = JSONDecoder()
        return try decoder.decode(BinanceAccountResponse.self, from: data)
    }

    
    
    func getListenKey() async throws -> String {
        guard let config = await APIConfig.shared else { throw ApiError.invalidData }
        
        let urlString = "\(config.binancefutureURL)/fapi/v1/listenKey"
        
        guard let url = URL(string: urlString) else { throw ApiError.invalidData }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(config.apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // 2. Проверяем статус код (поможет понять, если API ключ неверный)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? ""
            print("❌ Ошибка сервера (\(httpResponse.statusCode)): \(errorMsg)")
            throw ApiError.invalidData
        }

        // 3. Декодируем
        let result = try JSONDecoder().decode([String: String].self, from: data)
        let key = result["listenKey"] ?? ""
        print("🔑 Получен listenKey: \(key)")
        return key
    }
    
    
    func keepAliveListenKey(key: String) async {
        guard let config = await APIConfig.shared else { return }
        let urlString = "\(config.binancefutureURL)/fapi/v1/listenKey?listenKey=\(key)"
        
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "PUT"
        request.addValue(config.apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("🔄 listenKey успешно продлен")
            } else {
                print("⚠️ Не удалось продлить listenKey, возможно он истек")
            }
        } catch {
            print("❌ Ошибка продления: \(error)")
        }
    }


    
    func listenAccountUpdates(listenKey: String) async throws -> AsyncStream<BinanceUserDataEvent> {
        let wsURL = "wss://fstream.binancefuture.com/ws/\(listenKey)"
        let rawStream = await wsService.start(urlString: wsURL)
        
        return AsyncStream { continuation in
            Task {
                let decoder = JSONDecoder()
                for await data in rawStream {
                    guard !data.isEmpty else { continue }
                    
                    // 1. Проверяем тип события (чтобы не парсить лишнее)
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          json["e"] as? String == "ACCOUNT_UPDATE" else {
                        continue
                    }

                    do {
                        // 2. Теперь парсим целиком в нашу модель
                        let response = try decoder.decode(BinanceUserDataEvent.self, from: data)
                        continuation.yield(response)
                    } catch {
                        print("❌ Ошибка парсинга ACCOUNT_UPDATE: \(error)")
                    }
                }
            }
        }
    }


    func subscribeToMarkPrice() async throws -> AsyncStream<MarkPrice> {
        guard let config = await APIConfig.shared else { throw ApiError.invalidData }
        let baseUrl = config.binancefutureWS
        let path = "btcusdt@markPrice"
        let urlString = "\(baseUrl)\(path)"
        let rawStream = await wsService.start(urlString: urlString)
        
        return AsyncStream { continuation in
            let task = Task {
                for await data in rawStream {
                    guard !Task.isCancelled else { break }
                    do {
                        let event = try decoder.decode(MarkPrice.self, from: data)
                        continuation.yield(event)
                    } catch {
                        print("Decoding error subscribeToTradeStreams : \(error). Raw data: \(String(data: data, encoding: .utf8) ?? "")")
                    }
                }
                continuation.finish()
            }
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task {
                    await self.wsService.disconnect(urlString: urlString)
                }
            }
        }
    }
}
