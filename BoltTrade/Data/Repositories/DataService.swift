//
//  DataService.swift
//  TreadingBot
//
//  Created by Igorchela on 22.01.26.
//

import Foundation


actor DataService {
    private let dataProvider: DataProvider
    private let orderBookManager: OrderBookManager
    private var tradeStreamManager: TradeStreamManager
    private let bookStreamManager: BookStreamManager
    private let candleManager: CandleManager
    
    // Потоки для подписчиков
    private var localOrderBookContinuations: [UUID: AsyncStream<LocalOrderBook>.Continuation] = [:]
    private var multicastLocalOrderBookTask: Task<Void, Never>?
    
    private var tradeContinuations: [UUID: AsyncStream<TradeStreams>.Continuation] = [:]
    private var multicastTradeTask: Task<Void, Never>?
    
    private var candleContinuations: [UUID: AsyncStream<[Candle]>.Continuation] = [:]
    private var multicastCandleTask: Task<Void, Never>?
    
    
    private var loadingTask: Task<OrderBookSnapshot, Error>?
    
    init(dataProvider: DataProvider) {
        self.dataProvider = dataProvider
        self.orderBookManager = OrderBookManager(dataProvider: dataProvider)
        self.tradeStreamManager = TradeStreamManager(dataProvider: dataProvider)
        self.bookStreamManager = BookStreamManager(dataProvider: dataProvider)
        self.candleManager = CandleManager(dataProvider: dataProvider)
    }
    

    func start() async {
        // Запускаем менеджеры
        try? await orderBookManager.start()
        try? await tradeStreamManager.start()
        try? await candleManager.start()

        // Запускаем мультикастинг
        await multicastLocalOrderBook()
        await multicastTrades()
        await multicastCandle()
    }
    

    func stop() async {
        await orderBookManager.stopAll()
        await tradeStreamManager.stop()
        await candleManager.stop()
        
        // Завершаем все продолжения
        for continuation in localOrderBookContinuations.values {
            continuation.finish()
        }
        for continuation in tradeContinuations.values {
            continuation.finish()
        }
        
        for continuation in candleContinuations.values {
            continuation.finish()
        }
        
        
        localOrderBookContinuations.removeAll()
        tradeContinuations.removeAll()
        candleContinuations.removeAll()
        
        multicastLocalOrderBookTask?.cancel()
        multicastLocalOrderBookTask = nil
        
        multicastTradeTask?.cancel()
        multicastTradeTask = nil
        
        multicastCandleTask?.cancel()
        multicastCandleTask = nil
    }
    
    
    
    // Методы для подписки

    func localOrderBookStream() -> AsyncStream<LocalOrderBook> {
        let (stream, continuation) = AsyncStream.makeStream(of: LocalOrderBook.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        localOrderBookContinuations[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeOrderBookContinuation(id: id) }
        }
        
        return stream
    }
    
    
    // Мультикастинг данных из OrderBookManager
    private func multicastLocalOrderBook() async {
        multicastLocalOrderBookTask = Task {
            for await book in orderBookManager.updatesStream {
                for continuation in localOrderBookContinuations.values {
                    continuation.yield(book)
                }
            }
        }
    }

    
    func tradeStream() -> AsyncStream<TradeStreams> {
        AsyncStream { continuation in
            let id = UUID()
            tradeContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeTradeContinuation(id: id) }
            }
        }
    }
    
    
    // Мультикастинг данных из TradeStreamManager
    private func multicastTrades() async {
        multicastTradeTask = Task { [weak self] in
            guard let self = self else { return }
            for await trade in await self.tradeStreamManager.tradeStream {
                for continuation in await tradeContinuations.values {
                    continuation.yield(trade)
                }
            }
        }
    }
    
    
    func candleStream() -> AsyncStream<[Candle]> {
        AsyncStream { continuation in
            let id = UUID()
            candleContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeCandleContinuation(id: id) }
            }
        }
    }
    
    
    private func multicastCandle() async {
        multicastCandleTask = Task { [weak self] in
            guard let self = self else { return }
            for await candle in self.candleManager.candleStream {
                for continuation in await candleContinuations.values {
                    continuation.yield(candle)
                }
            }
        }
    }
    
    
    private func removeOrderBookContinuation(id: UUID) {
        localOrderBookContinuations.removeValue(forKey: id)
    }
    

    private func removeTradeContinuation(id: UUID) {
        tradeContinuations.removeValue(forKey: id)
    }
    
    private func removeCandleContinuation(id: UUID) {
        candleContinuations.removeValue(forKey: id)
    }
    
}
