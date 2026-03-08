//
//   DataProvider.swift
//  Treading
//
//  Created by Igorchela on 9.01.26.
//

import Foundation

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
            Task {
                // Подписываемся на сырые данные
                for await data in rawStream {
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
        }
    }
    
    
    func subscribeToTradeStreams(urlString: String) async -> AsyncStream<TradeStreams> {
        // Получаем сырой поток из транспортного сервиса
        let rawStream = await wsService.start(urlString: urlString)
        
        return AsyncStream { continuation in
            Task {
                // Подписываемся на сырые данные
                for await data in rawStream {
                    
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
}
