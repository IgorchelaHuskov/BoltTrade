//
//  MarketStateAnalyzer.swift
//  TreadingBot
//
//  Created by Igorchela on 7.02.26.
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
    
    private let binCalculator: BinCalculator
    private let modelContainer: ModelContainer
    
    private var configs: [MarketState: MarketConfig] = [:]
    private var currentMode: MarketState = .unknown
    private var candidateMode: MarketState = .unknown
    private var confirmations: Int = 0
    private let minConfirmations: Int = 3
    
    // СЧЕТЧИК СИЛЫ ТРЕНДА
    private var trendStrengthCounter: Int = 0
    private let minStrengthConfirmations: Int = 5
    
    var errorMessage: String = ""
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.binCalculator = BinCalculator()
    }
    
    
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
    
  
    func getConfigs() -> [MarketState: MarketConfig] {
        return configs
    }
    
    
    private func percentile(_ array: [Double], _ p: Double) -> Double {
        guard !array.isEmpty else { return 0 }
        let index = Int(Double(array.count - 1) * p)
        return array[index]
    }
    
    
    func reset() {
        currentMode = .unknown
        candidateMode = .unknown
        confirmations = 0
    }
    
    
    private func getTrendDirection(_ state: MarketState) -> Int {
        switch state {
        case .strongUptrend, .weakUptrend: return 1
        case .strongDowntrend, .weakDowntrend: return -1
        default: return 0
        }
    }
    
    
    // MARK: Обучение -Настройка configs (minPct, maxPct, coefficient, пороги)
    func trainOnHistoricalData(candles: [Candle]) async {
        guard candles.count >= 500 else { return }
        print("Обучаюсь на \(candles.count) исторических свечах...")
        
        if configs.isEmpty {
            print("📊 Создаю начальные конфиги...")
            for state in MarketState.allCases {
                configs[state] = createInitialConfig(for: state)
            }
            print("✅ Создано \(configs.count) начальных конфигов")
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
            
            let bin = await binCalculator.calculateBin(metrics: metrics,
                                                       currentPrice: lastCandle.closePrice,
                                                       marketState: state,
                                                       configs: configs)
            
            binPctsByState[state, default: []].append(bin.pct)
            adxValuesByState[state, default: []].append(metrics.adx)
            rviValuesByState[state, default: []].append(metrics.rvi)
            volRatioValuesByState[state, default: []].append(metrics.volatilityRatio)
            
            if i % 8000 == 0 {
                print("   Прогресс: \(i)/\(candles.count)")
            }
        }
        
        // НАСТРАИВАЕМ КОНФИГИ
        for (state, binPcts) in binPctsByState where binPcts.count >= 50 {
            let sorted = binPcts.sorted()
            let minPct = percentile(sorted, 0.10)
            let maxPct = percentile(sorted, 0.90)
            let avgPct = binPcts.reduce(0, +) / Double(binPcts.count)
            let calculatedCoef = avgPct * 100
            if var config = configs[state] {
                config.minPct = minPct * 0.9
                config.maxPct = maxPct * 1.1
                config.coefficient = max(0.3, min(calculatedCoef, 2.0)) // Не меньше 0.3 и не больше 2.0 позже подправить
                
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
    
    
    private func determineMarketState(metrics: MarketMetrics) -> MarketState {
        // ШАГ 1: ПРОВЕРКА НА ПРОРЫВ (самый приоритетный)
        if metrics.volatilityRatio > (configs[.breakout]?.volatilityRatio ?? .infinity) && abs(metrics.priceDeviation) > 0.03 && metrics.candlePattern == .engulfing {
            return .breakout
        }
        
        // ШАГ 2: ПРОВЕРКА НА ВЫСОКУЮ ВОЛАТИЛЬНОСТЬ
        if metrics.volatilityRatio > 2.0 && metrics.trendStrength < 0.3 {
            return .volatile
        }
        
        // ===========================================
        // ШАГ 3: АНАЛИЗ ТРЕНДА
        // ===========================================
        
        // Сильный восходящий тренд
        if metrics.trendDirection > 0.6 && metrics.trendStrength > 0.7 && metrics.higherHighs > 3 &&
            metrics.higherLows > 2 && metrics.priceVsSMA50 > 0.05 && metrics.candlePattern != .bearish {
            return .strongUptrend
        }
        
        // Слабый восходящий тренд
        if metrics.trendDirection > 0.2 && metrics.trendStrength > 0.4 && metrics.higherHighs >= 2 && metrics.priceVsSMA50 > 0 {
            return .weakUptrend
        }
        
        // Сильный нисходящий тренд
        if metrics.trendDirection < -0.6 && metrics.trendStrength > 0.7 && metrics.lowerLows >= 3 &&
            metrics.lowerHighs >= 2 && metrics.priceVsSMA50 < -0.02 && metrics.candlePattern != .bullish {
            return .strongDowntrend
        }
            
        // Слабый нисходящий тренд
        if metrics.trendDirection < -0.2 && metrics.trendStrength > 0.4 && metrics.lowerLows >= 2 && metrics.priceVsSMA50 < 0 {
            return .weakDowntrend
        }
        
        // ШАГ 4: ПРОВЕРКА НА ФЛЭТ
        if abs(metrics.trendDirection) < 0.2 && metrics.trendStrength < 0.3 && metrics.adx < 20 && abs(metrics.priceVsSMA50) < 0.005 &&
            metrics.lowerLows < 2 && metrics.higherHighs < 2 && metrics.volatilityRatio < 1.5 {
            return .flat
        }
        
        // ШАГ 5: ПОГРАНИЧНЫЕ СОСТОЯНИЯ
        // Если ADX показывает тренд, но структура слабая
        if metrics.adx > 25 && metrics.trendStrength < 0.5 {
            return metrics.trendDirection > 0 ? .weakUptrend : .weakDowntrend
        }
        
        // По умолчанию
        return .flat
    }
    
    
    // MARK: - Плавная донастройка на новых данных configs (90% старое / 10% новое)
    func fineTuneWithRecentData(candles: [Candle]) async throws {
        guard candles.count >= 200 else {
            print("⚠️ Недостаточно данных для донастройки: \(candles.count)")
            return
        }
        
        print("🔄 Запуск плавной донастройки на \(candles.count) свечах...")
        
        var binPctsByState: [MarketState: [Double]] = [:]
        
        // Анализируем последние 200 свечей
        let recentCandles = Array(candles.suffix(200))
        
        for i in 50..<recentCandles.count {
            let batch = Array(recentCandles[i-50...i])
            let lastCandle = batch.last!
            
            // Рассчитываем метрики
            let metrics = await calculateMetrics(from: batch, lastPrice: lastCandle.closePrice)
            
            // Определяем состояние
            let state = determineMarketState(metrics: metrics)
            
            // Рассчитываем бин с ТЕКУЩИМИ конфигами
            let bin = await self.binCalculator.calculateBin(
                metrics: metrics,
                currentPrice: lastCandle.closePrice,
                marketState: state,
                configs: configs
            )
            
            let binPct = bin.abs / lastCandle.closePrice
            binPctsByState[state, default: []].append(binPct)
        }
        
        // ПЛАВНАЯ КОРРЕКЦИЯ КОНФИГОВ
        var updatedCount = 0
        
        for (state, binPcts) in binPctsByState where binPcts.count >= 30 {
            let sorted = binPcts.sorted()
            let newMinPct = percentile(sorted, 0.15)
            let newMaxPct = percentile(sorted, 0.85)
            let newAvgPct = binPcts.reduce(0, +) / Double(binPcts.count)
            
            if var config = configs[state] {
                // Сохраняем старые значения для лога
                let oldMin = config.minPct
                let oldMax = config.maxPct
                let oldCoef = config.coefficient
                
                // 🎯 МЯГКАЯ НАСТРОЙКА: 90% старых, 10% новых
                let smoothing: Double = 0.9
                
                config.minPct = config.minPct * smoothing + newMinPct * (1 - smoothing)
                config.maxPct = config.maxPct * smoothing + newMaxPct * (1 - smoothing)
                
                // Коэффициент подстраиваем под средний бин
                let targetCoefficient = newAvgPct * 1.2
                config.coefficient = config.coefficient * smoothing + targetCoefficient * (1 - smoothing)
                
                // Защита от выбросов
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
        
        print("✅ Донастройка завершена. Обновлено \(updatedCount) конфигов")
    }
    
    
    // MARK: СОХРАНЕНИЕ/ЗАГРУЗКА
    private func saveConfigs() async {
        // ... сохраняем в SwiftData ...
        let context = ModelContext(modelContainer)
        
        // Удаляем старые
        let descriptor = FetchDescriptor<MarketConfigEntity>()
        if let old = try? context.fetch(descriptor) {
            print("🗑️ Удаляем \(old.count) старых конфигов")
            old.forEach { context.delete($0) }
        }
        
        // Сохраняем новые
        print("💾 Сохраняем \(configs.count) новых конфигов:")

        for (state, config) in configs {
            let entity = MarketConfigEntity(state: state, config: config)
            entity.lastUpdated = Date()
            context.insert(entity)
            print("   - \(state.rawValue): min=\(config.minPct), max=\(config.maxPct)")
        }
        do {
            try context.save()
            print("✅ Конфиги успешно сохранены!")
        } catch {
            print("Не удалось сохронить настройки состояния рынка")
            self.errorMessage = "Не удалось сохронить настройки состояния рынка"
        }
       
    }
    
    
    func loadConfigsFromDB() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<MarketConfigEntity>()
        
        guard let entities = try? context.fetch(descriptor) else {
            print("⚠️ Нет конфигов в базе")
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
            self.configs = loadedConfigs
            print("✅ Загружено \(loadedConfigs.count) конфигов из БД")
        }
    }
    
    
    // проверка по дате
    func shouldRetrain() async -> Bool {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<MarketConfigEntity>()
        
        guard let entities = try? context.fetch(descriptor),
              !entities.isEmpty else {
            print("📊 Нет сохраненных конфигов - нужно переобучение")
            return true
        }
        
        // Берем самую свежую дату обновления
        let lastUpdate = entities.map { $0.lastUpdated }.max() ?? Date.distantPast
        
        // 7 дней = 604800 секунд
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        let isExpired = Date().timeIntervalSince(lastUpdate) > sevenDays
        
        if isExpired {
            print("📊 Конфиги устарели: \(lastUpdate.formatted())")
        } else {
            print("📊 Конфиги свежие: \(lastUpdate.formatted())")
        }
        
        return isExpired
    }
    
    
    // MARK: АНАЛИЗ РЕАЛ-ТАЙМА** (каждые 15 мин)
    
    func analyzeWithHysteresis(metrics: MarketMetrics) -> MarketState {
        let rawState = determineMarketState(metrics: metrics)
        
        // Группировка состояний по "семействам"
        let trendFamily: [MarketState] = [.strongUptrend, .weakUptrend, .strongDowntrend, .weakDowntrend]
        let isCurrentTrend = trendFamily.contains(currentMode)
        let isRawTrend = trendFamily.contains(rawState)
        
        // ===========================================
        // СЛУЧАЙ 1: Мы в тренде и новый сигнал - тренд
        // ===========================================
        if isCurrentTrend && isRawTrend {
            let currentDirection = getTrendDirection(currentMode)
            let rawDirection = getTrendDirection(rawState)
            
            // Тренд в ту же сторону
            if currentDirection == rawDirection {
                return getStrongerTrendWithMetrics(
                    current: currentMode,
                    raw: rawState,
                    metrics: metrics
                )
            }
            // Смена направления тренда!
            else {
                // Требуем больше подтверждений для смены тренда
                if rawState == candidateMode {
                    confirmations += 1
                    if confirmations >= minConfirmations * 2 { // нужно больше подтверждений
                        currentMode = rawState
                        candidateMode = .unknown
                        confirmations = 0
                        trendStrengthCounter = 0
                    }
                } else {
                    candidateMode = rawState
                    confirmations = 1
                }
                return currentMode
            }
        }
        
        // ===========================================
        // СЛУЧАЙ 2: Выход из тренда в нетренд
        // ===========================================
        if isCurrentTrend && !isRawTrend {
            // Не выходим из тренда сразу
            confirmations += 1
            if confirmations >= minConfirmations * 3 { // нужно еще больше подтверждений
                currentMode = rawState
                candidateMode = .unknown
                confirmations = 0
                trendStrengthCounter = 0
            }
            return currentMode
        }
        
        // ===========================================
        // СЛУЧАЙ 3: Стандартная логика для нетрендовых состояний
        // ===========================================
        if currentMode == .unknown {
            currentMode = rawState
            return currentMode
        }
        
        if rawState == currentMode {
            candidateMode = .unknown
            confirmations = 0
            return currentMode
        }
        
        if rawState == candidateMode {
            confirmations += 1
            if confirmations >= minConfirmations {
                currentMode = rawState
                candidateMode = .unknown
                confirmations = 0
                trendStrengthCounter = 0
            }
            return currentMode
        }
        
        candidateMode = rawState
        confirmations = 1
        return currentMode
    }
    
    
    private func getStrongerTrendWithMetrics(current: MarketState, raw: MarketState, metrics: MarketMetrics) -> MarketState {
        
        // ===========================================
        // ДИНАМИЧЕСКОЕ ОПРЕДЕЛЕНИЕ СИЛЫ ТРЕНДА
        // ===========================================
        
        // Восходящий тренд
        if raw == .strongUptrend || raw == .weakUptrend {
            
            if current == .weakUptrend && raw == .strongUptrend {
                trendStrengthCounter += 1
                
                if trendStrengthCounter >= minStrengthConfirmations {
                    trendStrengthCounter = 0
                    return .strongUptrend
                }
                return .weakUptrend
            }
                    
            if current == .strongUptrend && raw == .weakUptrend {
                trendStrengthCounter -= 1  
                print("⬇️ Слабый сигнал: \(trendStrengthCounter)/\(-minStrengthConfirmations)")
                
                if trendStrengthCounter <= -minStrengthConfirmations {
                    trendStrengthCounter = 0
                    return .weakUptrend
                }
                return .strongUptrend
            }
            
            // Вычисляем силу тренда на основе метрик
            let isStrongByMetrics =
                metrics.trendStrength > 0.7 &&      // сильная линейная зависимость
                metrics.higherHighs >= 3 &&         // 3+ более высоких максимума
                metrics.higherLows >= 2 &&          // 2+ более высоких минимума
                metrics.priceVsSMA50 > 0.03 &&      // цена значительно выше SMA50
                metrics.volumeTrend > 0.3 &&        // объем подтверждает
                metrics.adx > 30                    // сильный ADX
            
            let isWeakByMetrics =
                metrics.trendStrength < 0.5 ||
                metrics.higherHighs < 2 ||
                metrics.priceVsSMA50 < 0.01
            
            if isStrongByMetrics {
                return .strongUptrend
            } else if isWeakByMetrics {
                return .weakUptrend
            }
            
            // Если неопределенно - оставляем как есть
            return current
        }
        
        // Нисходящий тренд
        if raw == .strongDowntrend || raw == .weakDowntrend {
            
            if current == .weakDowntrend && raw == .strongDowntrend {
                trendStrengthCounter += 1  // ← ЭТО НУЖНО ДОБАВИТЬ!
                print("⬇️ Сильный сигнал: \(trendStrengthCounter)/\(minStrengthConfirmations)")
                
                if trendStrengthCounter >= minStrengthConfirmations {
                    trendStrengthCounter = 0
                    return .strongDowntrend
                }
                return .weakDowntrend
            }
                    
            if current == .strongDowntrend && raw == .weakDowntrend {
                trendStrengthCounter -= 1
                print("⬆️ Слабый сигнал: \(trendStrengthCounter)/\(-minStrengthConfirmations)")
                
                if trendStrengthCounter <= -minStrengthConfirmations {
                    trendStrengthCounter = 0
                    return .weakDowntrend
                }
                return .strongDowntrend
            }
            
            let isStrongByMetrics =
                metrics.trendStrength > 0.7 &&
                metrics.lowerLows >= 3 &&           // 3+ более низких минимума (ВАШ СЛУЧАЙ!)
                metrics.lowerHighs >= 2 &&          // 2+ более низких максимума
                metrics.priceVsSMA50 < -0.03 &&     // цена значительно ниже SMA50
                metrics.volumeTrend < -0.3 &&       // объем подтверждает падение
                metrics.adx > 30
            
            let isWeakByMetrics =
                metrics.trendStrength < 0.5 ||
                metrics.lowerLows < 2 ||
                metrics.priceVsSMA50 > -0.01
            
            if isStrongByMetrics {
                return .strongDowntrend
            } else if isWeakByMetrics {
                return .weakDowntrend
            }
            
            return current
        }
        
        return raw
    }
    
    
    // MARK: ТЕХНИЧЕСКИЕ МЕТОДЫ
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
