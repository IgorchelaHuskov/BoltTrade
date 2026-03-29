//
//  MarketStateAnalyzer.swift
//  TreadingBot
//
//  Created by Igorchela on 7.02.26.
//  Refactored with balanced market state detection
//

import Foundation
import SwiftData

actor MarketStateAnalyzer {
    
    enum MarketState: String, Hashable, Sendable, CaseIterable {
        case strongUptrend    = "strongUptrend"     // сильный восходящий тренд
        case weakUptrend      = "weakUptrend"       // слабый восходящий тренд
        case strongDowntrend  = "strongDowntrend"   // сильный нисходящий тренд
        case weakDowntrend    = "weakDowntrend"     // слабый нисходящий тренд
        case flat             = "flat"              // боковик
        case breakout         = "breakout"          // прорыв (импульс)
        case volatile         = "volatile"          // высокая волатильность без направления
        case unknown          = "unknown"
    }
    
    // MARK: - Properties
    private let binCalculator: BinCalculator
    private let modelContainer: ModelContainer
    private var configs: [MarketState: MarketConfig] = [:]
    private var currentMode: MarketState = .unknown
    private var stateConfidence: [MarketState: Int] = [:]
    private let minConfidence: Int = 3
    
    // Для плавного перехода между состояниями
    private var transitionBuffer: [(state: MarketState, timestamp: Date)] = []
    private let transitionWindow: TimeInterval = 5.0  // 5 секунд
    
    var errorMessage: String = ""
    
    // MARK: - Init
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.binCalculator = BinCalculator()
    }
    
    // MARK: - Public Methods
    
    func getConfigs() -> [MarketState: MarketConfig] {
        return configs
    }
    
    func reset() {
        currentMode = .unknown
        stateConfidence.removeAll()
        transitionBuffer.removeAll()
    }
    
    // MARK: - Core State Detection
    
    func analyzeWithHysteresis(metrics: MarketMetrics) -> MarketState {
        let rawState = determineMarketState(metrics: metrics)
        
        // Логирование для отладки
        logStateDiagnostics(rawState: rawState, metrics: metrics)
        
        // Обновляем буфер переходов
        updateTransitionBuffer(with: rawState)
        
        // Получаем сглаженное состояние
        let smoothedState = getSmoothedState()
        
        // Обновляем уверенность
        updateConfidence(for: smoothedState)
        
        // Проверяем, нужно ли менять состояние
        if shouldTransition(to: smoothedState) {
            currentMode = smoothedState
            logStateChange(newState: smoothedState, metrics: metrics)
        }
        
        return currentMode
    }
    
    // MARK: - Private Detection Logic
    
    private func determineMarketState(metrics: MarketMetrics) -> MarketState {
        
        // ===========================================
        // ШАГ 1: ЭКСТРЕМАЛЬНЫЕ СОСТОЯНИЯ
        // ===========================================
        
        // 1.1 ПРОРЫВ (Breakout) — самый сильный сигнал
        if isBreakout(metrics) {
            return .breakout
        }
        
        // 1.2 ВЫСОКАЯ ВОЛАТИЛЬНОСТЬ
        if isHighVolatility(metrics) {
            return .volatile
        }
        
        // ===========================================
        // ШАГ 2: АНАЛИЗ ТРЕНДА
        // ===========================================
        
        let trendAnalysis = analyzeTrend(metrics)
        
        if trendAnalysis.hasTrend {
            if trendAnalysis.isStrong {
                return trendAnalysis.isUp ? .strongUptrend : .strongDowntrend
            } else {
                return trendAnalysis.isUp ? .weakUptrend : .weakDowntrend
            }
        }
        
        // ===========================================
        // ШАГ 3: ФЛЭТ
        // ===========================================
        
        if isFlat(metrics) {
            return .flat
        }
        
        // ===========================================
        // ШАГ 4: ПОГРАНИЧНЫЕ СЛУЧАИ
        // ===========================================
        
        return determineBorderlineState(metrics)
    }
    
    // MARK: - Detection Helpers
    
    private func isBreakout(_ metrics: MarketMetrics) -> Bool {
        // Высокая волатильность
        guard metrics.volatilityRatio > 1.8 else { return false }
        
        // Значительное отклонение от SMA
        guard abs(metrics.priceDeviation) > 0.025 else { return false }
        
        // Паттерн поглощения
        guard metrics.candlePattern == .engulfing else { return false }
        
        // Объём подтверждает
        guard abs(metrics.volumeTrend) > 0.3 else { return false }
        
        return true
    }
    
    private func isHighVolatility(_ metrics: MarketMetrics) -> Bool {
        // Волатильность выше нормы
        guard metrics.volatilityRatio > 1.5 else { return false }
        
        // Нет чёткого направления
        guard abs(metrics.trendDirection) < 0.4 else { return false }
        
        // Сила тренда слабая
        guard metrics.trendStrength < 0.5 else { return false }
        
        return true
    }
    
    private func analyzeTrend(_ metrics: MarketMetrics) -> (hasTrend: Bool, isStrong: Bool, isUp: Bool) {
        let direction = metrics.trendDirection
        let strength = metrics.trendStrength
        let adx = metrics.adx
        
        // Адаптивные пороги
        let adxThreshold = getAdaptiveAdxThreshold(metrics)
        let directionThreshold = getAdaptiveDirectionThreshold(metrics)
        
        // Проверка наличия тренда
        let hasTrend = adx > adxThreshold && abs(direction) > directionThreshold
        
        guard hasTrend else {
            return (false, false, false)
        }
        
        // Определение силы тренда
        let isStrong = strength > 0.6 &&
                       adx > adxThreshold + 10 &&
                       (direction > 0 ? metrics.higherHighs >= 2 : metrics.lowerLows >= 2)
        
        // Направление
        let isUp = direction > 0
        
        return (true, isStrong, isUp)
    }
    
    private func isFlat(_ metrics: MarketMetrics) -> Bool {
        // Нет сильного направления
        guard abs(metrics.trendDirection) < 0.25 else { return false }
        
        // Слабая сила тренда
        guard metrics.trendStrength < 0.35 else { return false }
        
        // Низкий ADX
        guard metrics.adx < 25 else { return false }
        
        // Цена около SMA
        guard abs(metrics.priceVsSMA50) < 0.01 else { return false }
        
        // Нормальная волатильность
        guard metrics.volatilityRatio < 1.4 else { return false }
        
        // Нет сильных структурных движений
        guard metrics.lowerLows < 2 && metrics.higherHighs < 2 else { return false }
        
        return true
    }
    
    private func determineBorderlineState(_ metrics: MarketMetrics) -> MarketState {
        // Если есть лёгкий намёк на тренд
        if abs(metrics.trendDirection) > 0.2 {
            let isUp = metrics.trendDirection > 0
            return isUp ? .weakUptrend : .weakDowntrend
        }
        
        // Если высокая волатильность
        if metrics.volatilityRatio > 1.3 {
            return .volatile
        }
        
        // По умолчанию — флэт
        return .flat
    }
    
    // MARK: - Adaptive Thresholds
    
    private func getAdaptiveAdxThreshold(_ metrics: MarketMetrics) -> Double {
        let baseThreshold = 22.0
        
        // В волатильном рынке ADX выше
        let volatilityFactor = min(1.5, max(0.8, metrics.volatilityRatio))
        
        // В сильном тренде порог ниже
        let trendFactor = metrics.trendStrength > 0.5 ? 0.8 : 1.0
        
        return baseThreshold * volatilityFactor * trendFactor
    }
    
    private func getAdaptiveDirectionThreshold(_ metrics: MarketMetrics) -> Double {
        let baseThreshold = 0.25
        
        // При высокой волатильности сложнее определить направление
        let volatilityFactor = min(1.3, max(0.7, metrics.volatilityRatio))
        
        return baseThreshold * volatilityFactor
    }
    
    // MARK: - State Smoothing
    
    private func updateTransitionBuffer(with state: MarketState) {
        let now = Date()
        transitionBuffer.append((state, now))
        
        // Удаляем старые записи
        transitionBuffer = transitionBuffer.filter {
            now.timeIntervalSince($0.timestamp) < transitionWindow
        }
    }
    
    private func getSmoothedState() -> MarketState {
        guard !transitionBuffer.isEmpty else { return .flat }
        
        // Считаем частоту каждого состояния
        var frequency: [MarketState: Int] = [:]
        for item in transitionBuffer {
            frequency[item.state, default: 0] += 1
        }
        
        // Находим самое частое состояние
        let mostFrequent = frequency.max { $0.value < $1.value }?.key ?? .flat
        let frequencyPercent = Double(frequency[mostFrequent, default: 0]) / Double(transitionBuffer.count)
        
        // Если частоты размыты — возвращаем текущее состояние
        if frequencyPercent < 0.6 {
            return currentMode
        }
        
        return mostFrequent
    }
    
    private func updateConfidence(for state: MarketState) {
        // Увеличиваем уверенность в текущем состоянии
        stateConfidence[state, default: 0] += 1
        
        // Уменьшаем уверенность в других
        for (otherState, _) in stateConfidence {
            if otherState != state {
                stateConfidence[otherState] = max(0, (stateConfidence[otherState] ?? 0) - 1)
            }
        }
    }
    
    private func shouldTransition(to newState: MarketState) -> Bool {
        // Не меняем состояние, если это unknown
        guard newState != .unknown else { return false }
        
        // Если это то же состояние — не меняем
        guard newState != currentMode else { return false }
        
        // Нужно набрать достаточно уверенности
        let confidence = stateConfidence[newState, default: 0]
        
        // Для радикальных смен (тренд → противоположный тренд) нужно больше подтверждений
        let isTrendReversal = isTrendState(currentMode) && isTrendState(newState) &&
                              getTrendDirection(currentMode) != getTrendDirection(newState)
        
        let requiredConfidence = isTrendReversal ? minConfidence + 2 : minConfidence
        
        return confidence >= requiredConfidence
    }
    
    // MARK: - Helpers
    
    private func isTrendState(_ state: MarketState) -> Bool {
        switch state {
        case .strongUptrend, .weakUptrend, .strongDowntrend, .weakDowntrend:
            return true
        default:
            return false
        }
    }
    
    private func getTrendDirection(_ state: MarketState) -> Int {
        switch state {
        case .strongUptrend, .weakUptrend:
            return 1
        case .strongDowntrend, .weakDowntrend:
            return -1
        default:
            return 0
        }
    }
    
    // MARK: - Logging
    
    private func logStateDiagnostics(rawState: MarketState, metrics: MarketMetrics) {
        #if DEBUG
        print("""
        📊 [StateAnalyzer] Diagnostics:
           Raw State: \(rawState.rawValue)
           Current State: \(currentMode.rawValue)
           ADX: \(String(format: "%.1f", metrics.adx))
           Trend Direction: \(String(format: "%.2f", metrics.trendDirection))
           Trend Strength: \(String(format: "%.2f", metrics.trendStrength))
           Volatility Ratio: \(String(format: "%.2f", metrics.volatilityRatio))
           Price vs SMA50: \(String(format: "%.3f", metrics.priceVsSMA50))
           Higher Highs: \(metrics.higherHighs)
           Lower Lows: \(metrics.lowerLows)
           Candle Pattern: \(metrics.candlePattern)
        """)
        #endif
    }
    
    private func logStateChange(newState: MarketState, metrics: MarketMetrics) {
        print("""
        🔄 [StateAnalyzer] State Change:
           \(currentMode.rawValue) → \(newState.rawValue)
           ADX: \(String(format: "%.1f", metrics.adx))
           Trend: \(String(format: "%.2f", metrics.trendDirection))
        """)
    }
    
    // MARK: - Training & Configuration
    
    func trainOnHistoricalData(candles: [Candle]) async {
        guard candles.count >= 500 else { return }
        print("📊 Training on \(candles.count) candles...")
        
        if configs.isEmpty {
            for state in MarketState.allCases {
                configs[state] = createInitialConfig(for: state)
            }
        }
        
        var binPctsByState: [MarketState: [Double]] = [:]
        var adxValuesByState: [MarketState: [Double]] = [:]
        var rviValuesByState: [MarketState: [Double]] = [:]
        var volRatioValuesByState: [MarketState: [Double]] = [:]
        
        for i in 500..<candles.count {
            let batch = Array(candles[i-500...i])
            let lastCandle = batch.last!
            
            let metrics = await calculateMetrics(from: batch, lastPrice: lastCandle.closePrice)
            let state = determineMarketState(metrics: metrics)
            
            let bin = await binCalculator.calculateBin(
                metrics: metrics,
                currentPrice: lastCandle.closePrice,
                marketState: state,
                configs: configs
            )
            
            binPctsByState[state, default: []].append(bin.pct)
            adxValuesByState[state, default: []].append(metrics.adx)
            rviValuesByState[state, default: []].append(metrics.rvi)
            volRatioValuesByState[state, default: []].append(metrics.volatilityRatio)
            
            if i % 8000 == 0 {
                print("   Progress: \(i)/\(candles.count)")
            }
        }
        
        for (state, binPcts) in binPctsByState where binPcts.count >= 50 {
            let sorted = binPcts.sorted()
            let minPct = percentile(sorted, 0.10)
            let maxPct = percentile(sorted, 0.90)
            let avgPct = binPcts.reduce(0, +) / Double(binPcts.count)
            let calculatedCoef = avgPct * 100
            
            if var config = configs[state] {
                config.minPct = minPct * 0.9
                config.maxPct = maxPct * 1.1
                config.coefficient = max(0.3, min(calculatedCoef, 2.0))
                
                if let adxValues = adxValuesByState[state] {
                    config.adxThreshold = percentile(adxValues.sorted(), 0.50)
                }
                
                if let rviValues = rviValuesByState[state] {
                    config.rviThreshold = percentile(rviValues.sorted(), 0.50)
                }
                
                if let volValues = volRatioValuesByState[state] {
                    config.volatilityRatio = percentile(volValues.sorted(), 0.50)
                }
                
                configs[state] = config
            }
        }
        
        await saveConfigs()
        print("✅ Training completed")
    }
    
    func fineTuneWithRecentData(candles: [Candle]) async throws {
        guard candles.count >= 200 else {
            print("⚠️ Not enough data for fine-tuning: \(candles.count)")
            return
        }
        
        print("🔄 Fine-tuning on \(candles.count) candles...")
        
        var binPctsByState: [MarketState: [Double]] = [:]
        let recentCandles = Array(candles.suffix(200))
        
        for i in 50..<recentCandles.count {
            let batch = Array(recentCandles[i-50...i])
            let lastCandle = batch.last!
            
            let metrics = await calculateMetrics(from: batch, lastPrice: lastCandle.closePrice)
            let state = determineMarketState(metrics: metrics)
            
            let bin = await binCalculator.calculateBin(
                metrics: metrics,
                currentPrice: lastCandle.closePrice,
                marketState: state,
                configs: configs
            )
            
            let binPct = bin.abs / lastCandle.closePrice
            binPctsByState[state, default: []].append(binPct)
        }
        
        var updatedCount = 0
        let smoothing: Double = 0.9
        
        for (state, binPcts) in binPctsByState where binPcts.count >= 30 {
            let sorted = binPcts.sorted()
            let newMinPct = percentile(sorted, 0.15)
            let newMaxPct = percentile(sorted, 0.85)
            let newAvgPct = binPcts.reduce(0, +) / Double(binPcts.count)
            
            if var config = configs[state] {
                let oldMin = config.minPct
                let oldMax = config.maxPct
                let oldCoef = config.coefficient
                
                config.minPct = config.minPct * smoothing + newMinPct * (1 - smoothing)
                config.maxPct = config.maxPct * smoothing + newMaxPct * (1 - smoothing)
                
                let targetCoefficient = newAvgPct * 1.2
                config.coefficient = config.coefficient * smoothing + targetCoefficient * (1 - smoothing)
                
                config.minPct = max(config.minPct, 0.0005)
                config.maxPct = min(config.maxPct, 0.015)
                config.coefficient = max(0.3, min(2.0, config.coefficient))
                
                configs[state] = config
                updatedCount += 1
                
                print("""
                📊 \(state.rawValue):
                    min: \(String(format: "%.4f", oldMin)) → \(String(format: "%.4f", config.minPct))
                    max: \(String(format: "%.4f", oldMax)) → \(String(format: "%.4f", config.maxPct))
                    coef: \(String(format: "%.2f", oldCoef)) → \(String(format: "%.2f", config.coefficient))
                """)
            }
        }
        
        await saveConfigs()
        print("✅ Fine-tuning completed. Updated \(updatedCount) configs")
    }
    
    // MARK: - Configuration Management
    
    private func createInitialConfig(for state: MarketState) -> MarketConfig {
        switch state {
        case .flat:
            return MarketConfig(
                coefficient: 0.3,
                minPct: 0.0003,
                maxPct: 0.001,
                adxThreshold: 20,
                rviThreshold: 1.3,
                volatilityRatio: nil
            )
            
        case .weakUptrend, .weakDowntrend:
            return MarketConfig(
                coefficient: 0.6,
                minPct: 0.0008,
                maxPct: 0.003,
                adxThreshold: 25,
                rviThreshold: 1.8,
                volatilityRatio: nil
            )
            
        case .strongUptrend, .strongDowntrend:
            return MarketConfig(
                coefficient: 1.0,
                minPct: 0.0015,
                maxPct: 0.006,
                adxThreshold: 30,
                rviThreshold: 2.0,
                volatilityRatio: nil
            )
            
        case .breakout:
            return MarketConfig(
                coefficient: 1.8,
                minPct: 0.0025,
                maxPct: 0.012,
                adxThreshold: nil,
                rviThreshold: nil,
                volatilityRatio: 2.5
            )
            
        case .volatile:
            return MarketConfig(
                coefficient: 1.2,
                minPct: 0.002,
                maxPct: 0.008,
                adxThreshold: nil,
                rviThreshold: nil,
                volatilityRatio: 2.0
            )
            
        case .unknown:
            return MarketConfig(
                coefficient: 0.5,
                minPct: 0.001,
                maxPct: 0.003,
                adxThreshold: nil,
                rviThreshold: nil,
                volatilityRatio: nil
            )
        }
    }
    
    private func saveConfigs() async {
        let context = ModelContext(modelContainer)
        
        let descriptor = FetchDescriptor<MarketConfigEntity>()
        if let old = try? context.fetch(descriptor) {
            old.forEach { context.delete($0) }
        }
        
        for (state, config) in configs {
            let entity = MarketConfigEntity(state: state, config: config)
            entity.lastUpdated = Date()
            context.insert(entity)
        }
        
        do {
            try context.save()
            print("✅ Configs saved")
        } catch {
            print("❌ Failed to save configs: \(error)")
            errorMessage = "Failed to save configs: \(error)"
        }
    }
    
    func loadConfigsFromDB() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<MarketConfigEntity>()
        
        guard let entities = try? context.fetch(descriptor) else {
            print("⚠️ No configs in database")
            return
        }
        
        var loadedConfigs: [MarketState: MarketConfig] = [:]
        
        for entity in entities {
            if let state = MarketState(rawValue: entity.stateKey) {
                let config = MarketConfig(
                    coefficient: entity.coefficient,
                    minPct: entity.minPct,
                    maxPct: entity.maxPct,
                    adxThreshold: entity.adxThreshold,
                    rviThreshold: entity.rviThreshold,
                    volatilityRatio: entity.volatilityRatio
                )
                loadedConfigs[state] = config
            }
        }
        
        if !loadedConfigs.isEmpty {
            configs = loadedConfigs
            print("✅ Loaded \(loadedConfigs.count) configs from DB")
        }
    }
    
    func shouldRetrain() async -> Bool {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<MarketConfigEntity>()
        
        guard let entities = try? context.fetch(descriptor), !entities.isEmpty else {
            print("📊 No saved configs - need retraining")
            return true
        }
        
        let lastUpdate = entities.map { $0.lastUpdated }.max() ?? Date.distantPast
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        let isExpired = Date().timeIntervalSince(lastUpdate) > sevenDays
        
        if isExpired {
            print("📊 Configs expired: \(lastUpdate.formatted())")
        } else {
            print("📊 Configs fresh: \(lastUpdate.formatted())")
        }
        
        return isExpired
    }
    
    // MARK: - Metrics Calculation
    
    private func calculateMetrics(from candles: [Candle], lastPrice: Double) async -> MarketMetrics {
        let highs = candles.map { $0.highPrice }
        let lows = candles.map { $0.lowPrice }
        let closes = candles.map { $0.closePrice }
        
        let atr14 = await TechnicalIndicators.calculateATR(highs: highs, lows: lows, closes: closes, period: 14)
        let atr5 = await TechnicalIndicators.calculateATR(highs: highs, lows: lows, closes: closes, period: 5)
        let adx = await TechnicalIndicators.calculate_adx(highs: highs, lows: lows, closes: closes, period: 14)
        let rvi = await TechnicalIndicators.calculateRVI(highs: highs, lows: lows, atr14: atr14, period: 20)
        let volatilityRatio = await TechnicalIndicators.calculateVolatilityRatio(atr5: atr5, atr14: atr14)
        let sma20 = await TechnicalIndicators.calculateSMA(values: closes, period: 20)
        let priceDeviation = await TechnicalIndicators.calculatePriceDeviation(currentPrice: lastPrice, sma: sma20)
        
        let recentCandles = Array(candles.suffix(30))
        
        var lowerLows = 0
        var higherHighs = 0
        var lowerHighs = 0
        var higherLows = 0
        
        for i in 2..<recentCandles.count {
            let current = recentCandles[i]
            let prev = recentCandles[i-1]
            let prev2 = recentCandles[i-2]
            
            if current.lowPrice < prev.lowPrice && prev.lowPrice < prev2.lowPrice {
                lowerLows += 1
            }
            
            if current.highPrice > prev.highPrice && prev.highPrice > prev2.highPrice {
                higherHighs += 1
            }
            
            if current.highPrice < prev.highPrice && prev.highPrice < prev2.highPrice {
                lowerHighs += 1
            }
            
            if current.lowPrice > prev.lowPrice && prev.lowPrice > prev2.lowPrice {
                higherLows += 1
            }
        }
        
        let trend = calculateTrendDirectionAndStrength(prices: closes)
        
        let sma50 = await TechnicalIndicators.calculateSMA(values: closes, period: 50)
        let priceVsSMA50 = (lastPrice - sma50) / sma50
        
        let volumes = recentCandles.map { $0.volume }
        let volumeTrend = calculateTrendDirectionAndStrength(prices: volumes).direction
        
        let lastCandle = recentCandles.last!
        let prevCandle = recentCandles[recentCandles.count - 2]
        let candlePattern = await CandleAnalysis.analyzeCandlePattern(current: lastCandle, previous: prevCandle)
        
        return MarketMetrics(
            atr14: atr14,
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
            candlePattern: candlePattern
        )
    }
    
    private func calculateTrendDirectionAndStrength(prices: [Double]) -> (direction: Double, strength: Double) {
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
        
        var ssTot = 0.0
        var ssRes = 0.0
        
        for (x, y) in zip(indices, prices) {
            let yPred = meanY + slope * (x - meanX)
            ssTot += pow(y - meanY, 2)
            ssRes += pow(y - yPred, 2)
        }
        
        let rSquared = ssTot != 0 ? 1 - (ssRes / ssTot) : 0
        let direction = max(-1, min(1, slope * 1000))
        
        return (direction, rSquared)
    }
    
    private func percentile(_ array: [Double], _ p: Double) -> Double {
        guard !array.isEmpty else { return 0 }
        let index = Int(Double(array.count - 1) * p)
        return array[index]
    }
}
