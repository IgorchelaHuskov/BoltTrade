//
//  CandleViewModel.swift
//  TreadingBot
//
//  Created by Igorchela on 27.02.26.
//

import Foundation

@Observable
final class CandleViewModel {
    private(set) var chartData: [CandleChart] = []
    
    struct CandleChart: Identifiable{
        var id = UUID()
        var openTime: Date
        var openPrice: Double
        var highPrice: Double
        var lowPrice: Double
        var closePrice: Double
        var closeTime: Date
    }
    
    
    func update(from entities: [Candle]) {
        // Используем map — это быстрее и чище
        // Делим на 1000, если openTime в миллисекундах (как часто бывает в крипто-API)
        self.chartData = entities.map { entity in
            CandleChart(
                openTime: Date(timeIntervalSince1970: TimeInterval(entity.openTime) / 1000),
                openPrice: entity.openPrice,
                highPrice: entity.highPrice,
                lowPrice: entity.lowPrice,
                closePrice: entity.closePrice,
                closeTime: Date(timeIntervalSince1970: TimeInterval(entity.closeTime) / 1000)
            )
        }
        
        for data in chartData {
            print(data.closePrice)
        }
    }
}
