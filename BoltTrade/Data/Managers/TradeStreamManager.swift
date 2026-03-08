//
//  TradeStreamManager.swift
//  TreadingBot
//
//  Created by Igorchela on 22.01.26.
//

import Foundation

actor TradeStreamManager {
    private let dataProvider: DataProvider
    private var task: Task<Void, Never>?
   
    // Поток для трейдов
    private let tradeContinuation: AsyncStream<TradeStreams>.Continuation
    let tradeStream: AsyncStream<TradeStreams>

    init(dataProvider: DataProvider) {
        self.dataProvider = dataProvider
        (tradeStream, tradeContinuation) = AsyncStream.makeStream(of: TradeStreams.self)
    }

    
    func start() async throws {
        task = Task {
            guard let urlString = await APIConfig.shared?.binanceTradeWebsocketURL else { return }
            let stream = await dataProvider.subscribeToTradeStreams(urlString: urlString)
            for await tradeEvent in stream {
                if Task.isCancelled { break }
                self.tradeContinuation.yield(tradeEvent)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        tradeContinuation.finish()
    }
}
