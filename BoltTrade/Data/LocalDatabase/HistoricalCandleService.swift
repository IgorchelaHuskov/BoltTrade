//
//  HistoricalDataService.swift
//  TreadingBot
//
//  Created by Igorchela on 12.02.26.
//

import Foundation
import SwiftData

actor HistoricalCandleService {
    private let dataProvider: DataProvider
    private let modelContainer: ModelContainer
    var errorMessage: String = ""
    
    init(dataProvider: DataProvider, modelContainer: ModelContainer) {
        self.dataProvider = dataProvider
        self.modelContainer = modelContainer
    }
    
    func fetchAndSaveHistoricalData() async throws {
        let context = ModelContext(modelContainer)
        // 1. Пытаемся найти самую свежую запись в базе
        var descriptor = FetchDescriptor<CandleEntity>(sortBy: [SortDescriptor(\.openTime, order: .reverse)])
        descriptor.fetchLimit = 1
        
        let lastStoredCandle = try? context.fetch(descriptor).first
        
        let limit = 1000
        let endTime = Int64(Date().timeIntervalSince1970 * 1000)
        let startTime = endTime - Int64(90 * 24 * 60 * 60 * 1000)
        
        // 2. Если в базе что-то есть, начинаем оттуда. Если нет — отсчитываем 90 дней.
        var currentStartTime = lastStoredCandle != nil ? (lastStoredCandle!.closeTime + 1) : startTime
        if currentStartTime >= endTime {
            print("Данные уже актуальны")
            return
        }
        
        while currentStartTime < endTime && !Task.isCancelled {
            do {
                let candles = try await dataProvider.fetchCandle(limit: limit, startTime: currentStartTime)
                
                guard !candles.isEmpty else { break }
                
                for dto in candles {
                    let newCandle = CandleEntity(dto: dto)
                    context.insert(newCandle)
                }
                
                try context.save()
                
                // 2. Рассчитываем время для следующего шага
                if let lastCloseTime = candles.last?.closeTime {
                    currentStartTime = lastCloseTime + 1
                }
                
                // 3. Если пришло меньше лимита — мы дошли до текущего момента
                if candles.count < limit { break }
                
                // Пауза, чтобы не получить бан от Binance по IP
                try await Task.sleep(for: .milliseconds(100))
                
            } catch {
                self.errorMessage = "Ошибка загрузки исторических данных: \(error.localizedDescription)"
                print("Ошибка загрузки исторических данных: \(error.localizedDescription)")
                try await Task.sleep(for: .seconds(2)) // Анти-спам при ошибке
            }
        }
    }
    
    
    // Получить свечи из БД
    func getCandlesFromDataBase(limit: Int = 8000) throws -> [Candle] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CandleEntity> (sortBy: [SortDescriptor(\.openTime, order: .forward)])
        
        let entities = try context.fetch(descriptor)
        
        guard !entities.isEmpty else {
            self.errorMessage = "База данных свечей пуста"
            print("База данных свечей пуста")
            return []
        }
        
        let count = entities.count

        // Берем последние limit свечей
        let startIndex = max(0, count-limit)
        let selectedEntities = entities[startIndex..<count]
        
        return selectedEntities.map { $0.toCandle() }
    }
    
    
    // Проверить, есть ли данные
    func hasHistoricalData() async -> Bool {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CandleEntity>()
        guard let count = try? context.fetchCount(descriptor) else { return false }
        return count > 1000  // минимум 1000 свечей
    }
}
