//
//  BinModeConfig.swift
//  TreadingBot
//
//  Created by Igorchela on 28.01.26.
//

import Foundation
import SwiftData


actor DynamicBinCalculator {
    
    private let dataService: DataService
    private let marketStateAnalyzer: MarketStateAnalyzer
    private let binCalculator: BinCalculator
    private let historyService: HistoricalCandleService
    private let modelContainer: ModelContainer
    
    private let marketcurrentContinuation: AsyncStream<MarketStateData>.Continuation
    private var candleTask: Task<Void, Never>?
    
    let marketcurrentStream: AsyncStream<MarketStateData>
    var errorMessage: String = ""
    
    init(dataService: DataService, marketStateAnalyzer: MarketStateAnalyzer, historyService: HistoricalCandleService, modelContainer: ModelContainer) {
        self.binCalculator = BinCalculator()
        self.dataService = dataService
        self.marketStateAnalyzer = marketStateAnalyzer
        self.historyService = historyService
        self.modelContainer = modelContainer
        (marketcurrentStream, marketcurrentContinuation) = AsyncStream.makeStream(of: MarketStateData.self)
    }
    
    func start() async throws {
        if candleTask != nil { return }
        
        candleTask = Task {
            let candleStream = await dataService.candleStream()
            let context = ModelContext(modelContainer)
            var candleCounter = 0
            let retrainInterval = 100  // каждые 100 свечей (~1 день)
            
            for await candles in candleStream {
                guard let lastCandle = candles.last else { continue }
                
                do {
                    let entity = CandleEntity(dto: lastCandle)
                    context.insert(entity)
                    try context.save()
                } catch {
                    print("Ошибка сохронения последней свечи в базу: \(error)")
                    self.errorMessage = "Ошибка сохронения последней свечи в базу: \(error)"
                }
                
                // 1. Рассчитываем метрики
                let metrics = await calculateMetrics(from: candles, lastPrice: lastCandle.closePrice)
                
                // 2. Определяем состояние рынка
                let marketState = await marketStateAnalyzer.analyzeWithHysteresis(metrics: metrics)
                
                // ПЕРИОДИЧЕСКАЯ ДОНАСТРОЙКА
                candleCounter += 1
                if candleCounter >= retrainInterval {
                    do {
                        let recentCandles = try await historyService.getCandlesFromDataBase(limit: 500)
                        try await marketStateAnalyzer.fineTuneWithRecentData(candles: recentCandles)
                    } catch {
                        self.errorMessage = "Ошибка донастройки: \(error)"
                    }
                    
                    candleCounter = 0
                }
                
                // 3. БЕРЕМ НАСТРОЕННЫЕ КОНФИГИ!
                let configs = await marketStateAnalyzer.getConfigs()
                
                // 4. Рассчитываем bin
                let bin = await binCalculator.calculateBin(
                    metrics: metrics,
                    currentPrice: lastCandle.closePrice,
                    marketState: marketState,
                    configs: configs
                )
                
                // 5. Отправляем результат
                let marketStateData = MarketStateData(
                    metrics: metrics,
                    marketState: marketState,
                    bin: bin
                )
                marketcurrentContinuation.yield(marketStateData)
            }
        }
    }
    
    
    func stop() async {
        candleTask?.cancel()
        candleTask = nil
        await marketStateAnalyzer.reset()
    }
    
    
    private func calculateMetrics(from candles: [Candle], lastPrice: Double) async -> MarketMetrics {
        let highs = candles.map { $0.highPrice }
        let lows = candles.map { $0.lowPrice }
        let closes = candles.map { $0.closePrice }
        
        // Рассчитываем индикаторы
        let atr14 = await TechnicalIndicators.calculateATR(highs: highs, lows: lows, closes: closes, period: 14)
        let atr5 = await TechnicalIndicators.calculateATR(highs: highs, lows: lows, closes: closes, period: 5)
        let adx = await TechnicalIndicators.calculate_adx(highs: highs, lows: lows, closes: closes, period: 14)
        let rvi = await TechnicalIndicators.calculateRVI(highs: highs, lows: lows, atr14: atr14, period: 20)
        let volatilityRatio = await TechnicalIndicators.calculateVolatilityRatio(atr5: atr5, atr14: atr14)
        let sma20 = await TechnicalIndicators.calculateSMA(values: closes, period: 20)
        let priceDeviation = await TechnicalIndicators.calculatePriceDeviation(currentPrice: lastPrice, sma: sma20)
        
        // ========= АНАЛИЗ СТРУКТУРЫ =========
        
        let recentCandles = Array(candles.suffix(30))
        
        // 1. Анализ экстремумов
        var lowerLows = 0
        var higherHighs = 0
        var lowerHighs = 0
        var higherLows = 0
        
        for i in 2..<recentCandles.count {
            let current = recentCandles[i]
            let prev = recentCandles[i-1]
            let prev2 = recentCandles[i-2]
            
            // Поиск локальных минимумов
            if current.lowPrice < prev.lowPrice && prev.lowPrice < prev2.lowPrice {
                lowerLows += 1
            }
            
            // Поиск локальных максимумов
            if current.highPrice > prev.highPrice && prev.highPrice > prev2.highPrice {
                higherHighs += 1
            }
            
            // Более низкие максимумы
            if current.highPrice < prev.highPrice && prev.highPrice < prev2.highPrice {
                lowerHighs += 1
            }
            
            // Более высокие минимумы
            if current.lowPrice > prev.lowPrice && prev.lowPrice > prev2.lowPrice {
                higherLows += 1
            }
        }
        
        // 2. Направление и сила тренда (линейная регрессия)
        let trend = calculateTrendDirectionAndStrength(prices: closes)
        
        // 3. SMA50
        let sma50 = await TechnicalIndicators.calculateSMA(values: closes, period: 50)
        let priceVsSMA50 = (lastPrice - sma50) / sma50
        
        // 4. Тренд объема
        let volumes = recentCandles.map { $0.volume }
        let volumeTrend = calculateTrendDirectionAndStrength(prices: volumes).direction
        
        // 5. Паттерн свечи
        let lastCandle = recentCandles.last!
        let prevCandle = recentCandles[recentCandles.count - 2]
        let candlePattern = await CandleAnalysis.analyzeCandlePattern(current: lastCandle, previous: prevCandle)
        
        
        return MarketMetrics(atr14: atr14,
                             atr5: atr5,
                             adx: adx,
                             rvi: rvi,
                             volatilityRatio: volatilityRatio,
                             sma20: sma20,
                             priceDeviation: priceDeviation,
                             trendDirection: trend.direction,
                             trendStrength: trend.strength,
                             lowerLows: lowerLows,
                             higherHighs: higherHighs,
                             lowerHighs: lowerHighs,
                             higherLows: higherLows,
                             priceVsSMA50: priceVsSMA50,
                             volumeTrend: volumeTrend,
                             candlePattern: candlePattern)
    }
    
    
    private func calculateTrendDirectionAndStrength(prices: [Double]) -> (direction: Double, strength: Double){
        guard prices.count >= 10 else { return (0, 0) }
            
            let indices = Array(0..<prices.count).map(Double.init)
            let meanX = indices.reduce(0, +) / Double(indices.count)
            let meanY = prices.reduce(0, +) / Double(prices.count)
            
            var numerator = 0.0
            var denominator = 0.0
            
            for (x, y) in zip(indices, prices) {
                numerator += (x - meanX) * (y - meanY)
                denominator += pow(x - meanX, 2)
            }
            
            let slope = denominator != 0 ? numerator / denominator : 0
            
            // R-squared для силы тренда
            var ssTot = 0.0
            var ssRes = 0.0
            
            for (x, y) in zip(indices, prices) {
                let yPred = meanY + slope * (x - meanX)
                ssTot += pow(y - meanY, 2)
                ssRes += pow(y - yPred, 2)
            }
            
            let rSquared = ssTot != 0 ? 1 - (ssRes / ssTot) : 0
            
            // Направление от -1 до 1
            let direction = max(-1, min(1, slope * 1000)) // нормализация
            
            return (direction, rSquared)
    }
}

