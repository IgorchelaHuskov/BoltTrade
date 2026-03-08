//
//  OrderBookStreamManafer.swift
//  TreadingBot
//
//  Created by Igorchela on 26.01.26.
//

import Foundation

actor BookStreamManager {
    private let dataProvider: DataProvider
    private var task: Task<Void, Never>?
   
    // Поток для трейдов
    private let bookContinuation: AsyncStream<OrderBookStreamUpdate>.Continuation
    nonisolated let bookStream: AsyncStream<OrderBookStreamUpdate>

    init(dataProvider: DataProvider) {
        self.dataProvider = dataProvider
        (bookStream, bookContinuation) = AsyncStream.makeStream(of: OrderBookStreamUpdate.self)
    }

    
    func start() async throws {
        task = Task {
            guard let urlString = await APIConfig.shared?.binanceOrderBookWebsocketURL else { return }
            let stream = await dataProvider.subscribeToOrderBook(urlString: urlString)
            for await bookEvent in stream {
                if Task.isCancelled { break }
                self.bookContinuation.yield(bookEvent)
            }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        bookContinuation.finish()
    }

}
