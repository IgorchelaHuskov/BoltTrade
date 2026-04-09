//
//  CandleManager.swift
//  TreadingBot
//
//  Created by Igorchela on 31.01.26.
//

import Foundation
import SwiftData

actor CandleManager {
    private let dataProvider: DataProvider
    private let candleContinuation: AsyncStream<[Candle]>.Continuation
    nonisolated let candleStream: AsyncStream<[Candle]>
    private var task: Task<Void, Never>?
    
    var errorMesage: String = ""

    init(dataProvider: DataProvider) {
        self.dataProvider = dataProvider
        let (stream, continuation) = AsyncStream.makeStream(of: [Candle].self)
        self.candleStream = stream
        self.candleContinuation = continuation
    }

    func start(interval: Int = 60) async throws {
        task = Task {
            while !Task.isCancelled {
                do {
                    let snapshot = try await dataProvider.fetchCandle(limit: 1000)
                    candleContinuation.yield(snapshot)
                    let sleep = secondsUntilNextCandle(intervalMinutes: interval)
                    try await Task.sleep(for: .seconds(sleep))
                    
                } catch is CancellationError {
                    break
                    
                } catch {
                    self.errorMesage = "Ошибка загрузки свечей: \(error.localizedDescription)"
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
    }
    
    func stop() {
        task?.cancel()
        task = nil
        candleContinuation.finish()
    }
    
    
    private func secondsUntilNextCandle(intervalMinutes: Int) -> UInt64 {
        let now = Date().timeIntervalSince1970
        let intervalSeconds = Double(intervalMinutes * 60)
        
        // Находим, сколько секунд прошло с начала текущей свечи
        let remainder = now.truncatingRemainder(dividingBy: intervalSeconds)
        
        // Сколько осталось до начала следующей + 1-2 секунды запаса (чтобы сервер успел сформировать свечу)
        let delay = intervalSeconds - remainder + 2.0
        
        return UInt64(delay)
    }
}
