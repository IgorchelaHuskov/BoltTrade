//
//  BookSnapshotManager.swift
//  TreadingBot
//
//  Created by Igorchela on 26.01.26.
//

import Foundation


actor BookSnapshotManager {
    private let dataProvider: DataProvider
    private var orderBook: OrderBookSnapshot?
    private var loadingTask: Task<OrderBookSnapshot, Error>?
   

    init(dataProvider: DataProvider) {
        self.dataProvider = dataProvider
    }

    
    func getOrderBook(forceUpdate: Bool = false) async throws -> OrderBookSnapshot {
        // 1. Возвращаем кэш, если обновление не принудительное
        if let cached = orderBook, !forceUpdate {
            return cached
        }
        
        // 2. Если загрузка уже идет — ждем её
        if let existingTask = loadingTask {
            return try await existingTask.value
        }
        
        // 3. Создаем новую задачу загрузки
        let task = Task<OrderBookSnapshot, Error> {
            defer { loadingTask = nil } // Сброс задачи по завершении
            
            let snapshot = try await dataProvider.fetchSnapshot()
            
            self.orderBook = snapshot // Сохраняем в кэш
            return snapshot
        }
        
        loadingTask = task
        return try await task.value
    }
}

