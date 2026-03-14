//
//  BounceStrategy.swift
//  TreadingBot
//
//  Created by Igorchela on 19.01.26.
//

import Foundation

actor BounceStrategy: TradingStrategy, Resettable {
    // MARK: - Константы стратегии
    private enum Constants {
        static let thinPathThreshold                = 3.3     // максимальное отношение cumulativeVolume / totalVolume
        static let volumeStabilityThreshold         = 0.9     // минимальная доля от начального объема
        static let maxDistanceToCluster             = 0.01    // 1% от текущей цены
        static let volatilitySpikeRadius            = 0.002   // +- 0.2% вокруг цены кластера
        static let volatilityConcentrationThreshold = 0.4
        static let maxSpreadPercent                 = 0.001   // 0.1%
        static let attackerMinVolume                = 0.5     // минимальный объем агрессоров для входа
        static let requiredLimitToAttackRatio       = 1.5     // лимитный объем должен превышать атаку в 1.5 раза
        static let maxDistancePercentForTarget      = 1.0     // максимальное удаление цели при сканировании (%)
        static let maxClusterAge                    = 60.0
    }
    
    // MARK: - Вспомогательные типы
    struct MonitoringContext {
        let cluster: Cluster
        let startTime: ContinuousClock.Instant
        let initialVolume: Double
        var hasTouched: Bool = false
    }
    
    
    struct Position {
        let entryPrice: Double
        let sourceClusterId: Double
        let initialVolume: Double
        let side: Side
        var stopLoss: Double
        var monitoringCluster: MonitoringContext? = nil      // текущий отслеживаемый встречный кластер
        var processedClusterIds: Set<Double> = []            // уже обработанные кластеры
    }
    
    enum StrategyState {
        case scanning
        case monitoring(MonitoringContext)
        case positionOpen(Position)
    }
    
    // Результат мониторинга встречного кластера
    private enum EncounterMonitoringResult {
        case continueMonitoring(MonitoringContext)   // продолжаем наблюдение
        case exitPosition                            // закрываем позицию
        case stopMonitoring                          // успешно завершили, забываем кластер
    }
    
    // Ожидаемый исход битвы для встречного кластера
    private enum ExpectedOutcome {
        case shouldBeStrong   // хотим, чтобы лимиты устояли (отскок)
        case shouldBeWeak     // хотим, чтобы лимиты проиграли (пробой)
    }
    
    // MARK: - Свойства
    private var state: StrategyState = .scanning
    
    
    // MARK: - Протокол TradingStrategy
    func analyze(marketSnapshot: MarketSnapshot) async -> Signal? {
        switch state {
        case .scanning:
            return await handleScanning(snapshot: marketSnapshot)
            
        case .monitoring(let monitoringContext):
            return await handleMonitoring(context: monitoringContext, snapshot: marketSnapshot)
            
        case .positionOpen(let position):
            return await handlePositionOpen(position: position, snapshot: marketSnapshot)
        }
    }
    
    
    func reset() async {
        self.state = .scanning
    }
    
    
    // MARK: - Обработка состояний
    private func handleScanning(snapshot: MarketSnapshot) async -> Signal? {
        guard let targetCluster = findTargetCluster(in: snapshot) else { return nil }
        let initialVolume = findCurrentVolume(cluster: targetCluster, book: snapshot.book)
        let context = MonitoringContext(cluster: targetCluster,
                                        startTime: .now,
                                        initialVolume: initialVolume)
        
        print("""
            🎯 Цель захвачена:
            ID: \(targetCluster.trackingId)
            Границы: \(targetCluster.lowerBound) ... \(targetCluster.upperBound)
            Дистанция: \(targetCluster.distancePercent)%
            Сторона: \(targetCluster.side)
            Сила (Z‑score): \(targetCluster.strengthZScore)
            Начальный объем: \(initialVolume) BTC
            Состояния рынка \(snapshot.state)
            """)
        
        state = .monitoring(context)
        return nil
    }
    
    
    private func handleMonitoring(context: MonitoringContext, snapshot: MarketSnapshot) async -> Signal? {
        var context = context
        let cluster = context.cluster
        let price = snapshot.currentPrice
        
        // 1. Проверка существования
        guard snapshot.clusters.contains(where: { $0.trackingId == cluster.trackingId }) else {
            print("❌ [\(cluster.trackingId)] Цель удалена из списка активных кластеров")
            await reset(); return nil
        }
        
        // 2. Валидация условий
        guard isDistanceAcceptable(price: price, cluster: cluster), isThinPath(cluster: cluster) else {
            print("❌ [\(cluster.trackingId)] Базовые условия нарушены (Цена: \(price) | ThinPath: \(isThinPath(cluster: cluster)))")
            await reset(); return nil
        }
        
        // 3. Проверка ПРОБОЯ
        let isBrokenThrough = (cluster.side == .bid && price < cluster.lowerBound) ||
                              (cluster.side == .ask && price > cluster.upperBound)
        if isBrokenThrough {
            print("💀 [\(cluster.trackingId)] ПРОБОЙ! Цена \(price) прошила уровень \(cluster.side == .bid ? cluster.lowerBound : cluster.upperBound)")
            await reset(); return nil
        }

        // 4. Проверка СТАБИЛЬНОСТИ объема
        let currentVol = findCurrentVolume(cluster: cluster, book: snapshot.book)
        let volumeRatio = currentVol / context.initialVolume
        if volumeRatio < Constants.volumeStabilityThreshold {
            
            let stats = snapshot.battleStats[cluster.trackingId]
            let attackerVol = stats?.attackerVolume ?? 0
            let volumeLost = context.initialVolume - currentVol
            
            if attackerVol < (volumeLost * 0.5) {
                if volumeRatio < 0.4 {
                    print("💥 [\(cluster.trackingId)] КРИТИЧЕСКИЙ СБРОС: Объем рухнул до \(Int(volumeRatio * 100))% (Атака: \(attackerVol) BTC)")
                    await reset(); return nil
                } else {
                    print("⏳ [\(cluster.trackingId)] ПАУЗА: Объем мерцает (\(Int(volumeRatio * 100))%). Ждем восстановления...")
                    return nil
                }
            }
        }
        
        // 5. Фиксация КАСАНИЯ
        if !context.hasTouched && didPriceTouchCluster(price: price, cluster: cluster) {
            context.hasTouched = true
            self.state = .monitoring(context)
            print("🎯 [\(cluster.trackingId)] КАСАНИЕ! Цена \(price) вошла в зону уровня. Начинаю анализ битвы...")
        }
        
        guard context.hasTouched else {
            // Не спамим принтом, пока цена просто летит к уровню
            return nil
        }
        
        // 6. Защита от спуфинга (Volatility Spike)
        guard await noVolatilitySpike(currentCluster: cluster, price: snapshot.currentPrice, book: snapshot.book) else {
            print("⚠️ [\(cluster.trackingId)] Обнаружен всплеск волатильности (спуфинг). Отмена.")
            await reset()
            return nil
        }
        
        // 7. Анализ БИТВЫ
        guard let battleStats = snapshot.battleStats[cluster.trackingId] else {
            print("⚔️ [\(cluster.trackingId)] Ждем первых рыночных ударов в кластер...")
            return nil
        }
        
        let battleResult = await checkBattleConditions(stats: battleStats, cluster: cluster, book: snapshot.book, initialVolume: context.initialVolume)
        
        if battleResult == false {
            print("🚩 [\(cluster.trackingId)] БИТВА ПРОИГРАНА: Агрессоры сильнее лимитов. Отмена.")
            await reset(); return nil
        }
        
        guard battleResult == true else {
            print("⚔️ [\(cluster.trackingId)] Идет борьба... Агрессия: \(battleStats.attackerVolume) BTC | Лимиты: \(currentVol) BTC")
            return nil
        }
        
        // 8. ФИНАЛЬНЫЙ ШТРИХ: Пружина
        let isBouncing = (cluster.side == .bid && price > cluster.upperBound) ||
                         (cluster.side == .ask && price < cluster.lowerBound)
        
        if isBouncing {
            let position = updatePosition(cluster: cluster, price: price, context: context)
            let now = Date()
            let timeString = now.formatted(date: .omitted, time: .standard) // Результат: 14:30:15
            print("""
            🚀🚀🚀 [\(cluster.trackingId)] СИГНАЛ СФОРМИРОВАН!
            Состояния рынка \(snapshot.state)
            Сторона: \(cluster.side)
            Позиция открыта по цене \(position.entryPrice) в \(timeString)
            Итоговый объем кластера: \(currentVol)
            Объем поглощенной атаки: \(battleStats.attackerVolume)
            """)
            state = .positionOpen(position)
            return (cluster.side == .bid) ? .buy : .sell
        } else {
            print("🛡️ [\(cluster.trackingId)] Лимиты устояли! Ждем выхода цены из зоны для входа...")
        }
        
        return nil
    }

    
    private func handlePositionOpen(position: Position, snapshot: MarketSnapshot) async -> Signal? {
        var position = position
        let price = snapshot.currentPrice
        let side = position.side
        
        // 1. Проверка STOP LOSS (цена пересекла линию)
        let isStopHit = (side == .bid && price <= position.stopLoss) ||
                        (side == .ask && price >= position.stopLoss)
        
        if isStopHit {
            print("🛑 [STOP LOSS] Позиция закрыта по цене \(price). Убыток зафиксирован.")
            await reset()
            return .exit
        }
        
        // 2. ПРОВЕРКА РОДНОГО КЛАСТЕРА (Защита тыла)
        if let myCluster = snapshot.clusters.first(where: { $0.trackingId == position.sourceClusterId }) {
            let isHealthy = await checkLevelHealth(cluster: myCluster, snapshot: snapshot, initialVol: position.initialVolume)
            if !isHealthy {
                let now = Date()
                let timeString = now.formatted(date: .omitted, time: .standard) // Результат: 14:30:15
                print("🧨 [BACKSTAB] Наш защитный уровень ослаб. Закрываемся по цене \(price) в \(timeString)")
                await reset()
                return .exit
            }
        }
        
        // 3. Работа с встречными кластерами
        if let monitoringContext = position.monitoringCluster {
            // Есть активный мониторинг
            let result = await monitorEncounterCluster(context: monitoringContext, snapshot: snapshot, positionSide: position.side)
            
            switch result {
                
            case .continueMonitoring(let updatedContext):
                position.monitoringCluster = updatedContext
                self.state = .positionOpen(position)
                return nil
                
            case .exitPosition:
                await reset()
                return .exit
                
            case .stopMonitoring:
                // Успешно завершили мониторинг – забываем кластер
                position.monitoringCluster = nil
                position.processedClusterIds.insert(monitoringContext.cluster.trackingId)
                self.state = .positionOpen(position)
                return nil
            }
            
        } else {
            // Нет активного мониторинга, ищем новый кластер для касания
            guard let candidate = findEncounterCluster(in: snapshot, position: position) else {
                return nil
            }
            
            let initialVolume = findCurrentVolume(cluster: candidate, book: snapshot.book)
            let context = MonitoringContext(cluster: candidate, startTime: .now, initialVolume: initialVolume, hasTouched: true)
            position.monitoringCluster = context
            self.state = .positionOpen(position)
            print("🔄 [\(candidate.trackingId)] Начат мониторинг встречного кластера.")
            return nil
        }
    }
    
    
    // MARK: Вспомогательные методы scaning-monitoring-position
    
    // Ожидаемый исход сражения
    private func expectedBattleOutcome(for cluster: Cluster, positionSide: Side) -> ExpectedOutcome {
        switch (positionSide, cluster.side) {
        case(.bid, .ask):   // long встречает сопротивление → хотим пробой (слабый)
            return .shouldBeWeak
        case(.bid, .bid):   // long встречает поддержку → хотим отскок (сильный)
            return .shouldBeStrong
        case(.ask, .bid):   // short встречает поддержку → хотим пробой (слабый)
            return .shouldBeWeak
        case(.ask, .ask):   // short встречает сопротивление → хотим отскок (сильный)
            return .shouldBeStrong
        }
    }
    
    
    // Поиск нового встречного кластера, которого коснулась цена
    private func findEncounterCluster(in snapshot: MarketSnapshot, position: Position) -> Cluster? {
        let currentPrice = snapshot.currentPrice
        return snapshot.clusters.filter { cluster in
                // Исключаем исходный кластер и уже обработанные
                cluster.trackingId != position.sourceClusterId &&
                !position.processedClusterIds.contains(cluster.trackingId) &&
                didPriceTouchCluster(price: currentPrice, cluster: cluster)
            }
            .sorted { abs($0.price - currentPrice) < abs($1.price - currentPrice) }
            .first
    }
    
    
    // Мониторинг встречного кластера
    private func monitorEncounterCluster(context: MonitoringContext, snapshot: MarketSnapshot, positionSide: Side) async -> EncounterMonitoringResult {
        let context = context
        let cluster = context.cluster
        let currentPrice = snapshot.currentPrice
        
        // 1. Проверка существования
        guard snapshot.clusters.contains(where: { $0.trackingId == cluster.trackingId }) else {
            print("❌ [\(cluster.trackingId)] Встречный кластер исчез")
            return .stopMonitoring
        }
        
        // 2. Базовые условия
        guard isDistanceAcceptable(price: currentPrice, cluster: cluster), isThinPath(cluster: cluster) else {
            print("❌ [\(cluster.trackingId)] Базовые условия нарушены для встречного кластер")
            return .exitPosition
        }
        
        // 3. Проверка пробоя в нежелательную сторону
        let isBrokenThrough = (cluster.side == .bid && currentPrice < cluster.lowerBound) ||
                              (cluster.side == .ask && currentPrice > cluster.upperBound)
        if isBrokenThrough {
            print("💀 [\(cluster.trackingId)] Встречный кластер пробит в нежелательную сторону. Выход.")
            return .exitPosition
        }
        
        // 4. Стабильность объёма
        let currentVol = findCurrentVolume(cluster: cluster, book: snapshot.book)
        let volumeRatio = currentVol / context.initialVolume // ???????????????????????????????????/
        let expected = expectedBattleOutcome(for: cluster, positionSide: positionSide)
        
        if volumeRatio < Constants.volumeStabilityThreshold {
            let stats = snapshot.battleStats[cluster.trackingId]
            let attackerVol = stats?.attackerVolume ?? 0
            let volumeLost = context.initialVolume - currentVol
            
            if attackerVol < (volumeLost * 0.5) {
                if volumeRatio < 0.4 {
                    if expected == .shouldBeStrong {
                        print("💥 [\(cluster.trackingId)] Критический сброс объёма на встречном кластере (ожидалась сила). Выход.")
                        return .exitPosition
                    } else {
                        print("📉 [\(cluster.trackingId)] Критический сброс объёма (помогает пробою). Продолжаем.")
                    }
                } else {
                    print("⏳ [\(cluster.trackingId)] Пауза: объём мерцает на встречном кластере")
                    return .continueMonitoring(context)
                }
            }
        }

        // 5. Защита от спуфинга
        guard await noVolatilitySpike(currentCluster: cluster, price: currentPrice, book: snapshot.book) else {
            print("⚠️ [\(cluster.trackingId)] Обнаружен всплеск волатильности на встречном кластере. Выход.")
            return .exitPosition
        }
        
        // 6. Анализ битвы
        guard let battleStats = snapshot.battleStats[cluster.trackingId] else {
            print("⚔️ [\(cluster.trackingId)] Ждём первых рыночных ударов во встречный кластер...")
            return .continueMonitoring(context)
        }
        let battleResult = await checkBattleConditions(stats: battleStats, cluster: cluster, book: snapshot.book, initialVolume: context.initialVolume)
        if let result = battleResult {
            let isExpected = (result == (expected == .shouldBeStrong))
            if !isExpected {
                print("🚩 [\(cluster.trackingId)] Битва на встречном кластере идёт против ожиданий. Выход.")
                return .exitPosition
            }
        }
        
        // 7. Проверка выхода в сторону позиции (желаемое событие)
        let isMovingInFavor = (positionSide == .bid && currentPrice > cluster.upperBound) ||
                              (positionSide == .ask && currentPrice < cluster.lowerBound)
        if isMovingInFavor {
            print("✅ [\(cluster.trackingId)] Цена вышла из встречного кластера в сторону позиции. Продолжаем.")
            return .stopMonitoring
        }
        
        return .continueMonitoring(context)
    }
    
    
    private func checkLevelHealth(cluster: Cluster, snapshot: MarketSnapshot, initialVol: Double) async -> Bool {
        let price = snapshot.currentPrice
        
        // 1. Пробой - сразу FALSE (выходим)
        let isBroken = (cluster.side == .bid && price < cluster.lowerBound) ||
                       (cluster.side == .ask && price > cluster.upperBound)
        if isBroken {
            print("Уровень пробит!!! Выходим из рынка")
            return false
        }
        
        // 2. Объем (без пауз, если рухнул - выходим)
        /*let currentVol = findCurrentVolume(cluster: cluster, book: snapshot.book)
        if (currentVol / initialVol) < 0.4 {
            print("Объем рухнул до \(Int((currentVol / initialVol) * 100))% Выходим из рынка")
            return false
        }*/
        
        // 3. Битва (если есть данные)
        if let stats = snapshot.battleStats[cluster.trackingId] {
            // Если битва проиграна - FALSE
            let battleResult = await checkBattleConditions(stats: stats, cluster: cluster, book: snapshot.book, initialVolume: initialVol)
            if battleResult == false {
                print("БИТВА ПРОИГРАНА: Агрессоры сильнее лимитов. Выходим из рынка.")
                return false
            }
        }
        
        return true // Уровень всё еще живой
    }

    
    private func updatePosition(cluster: Cluster, price: Double, context: MonitoringContext) -> Position {
        let offset = price * 0.001 // Тот самый 0.1% "запас" на шум

        let stopLoss = (cluster.side == .bid)
            ? (cluster.lowerBound - offset) // Для Лонга: ниже нижней границы
            : (cluster.upperBound + offset) // Для Шорта: выше верхней границы
        return Position(entryPrice: price,
                        sourceClusterId: cluster.trackingId,
                        initialVolume: context.initialVolume,
                        side: cluster.side,
                        stopLoss: stopLoss
        )
    }
    

    private func findTargetCluster(in snapshot: MarketSnapshot) -> Cluster? {
        let currentPrice = snapshot.currentPrice
        return snapshot.clusters
            .filter { cluster in
                // 1. Фильтр по направлению (мы должны быть СНАРУЖИ уровня)
                let isValidDirection = cluster.side == .bid
                ? currentPrice > cluster.upperBound  // Мы сверху, падаем на поддержку
                : currentPrice < cluster.lowerBound  // Мы снизу, растем в сопротивление
                
                guard isValidDirection else { return false }
                
                // 2. Фильтр по "свежести" и дистанции
                let stats = snapshot.battleStats[cluster.trackingId]
                let isOld = Date().timeIntervalSince(stats?.firstSeen ?? Date()) > Constants.maxClusterAge
                let isClose = cluster.distancePercent < Constants.maxDistancePercentForTarget // Не берем слишком далекие цели
                
                // 3. Фильтр по силе
                let isStrong = cluster.strengthZScore > 4.5
                
                return isOld && isClose && isStrong
            }
            .sorted { $0.distancePercent < $1.distancePercent }
            .first
    }
    
    
    private func findCurrentVolume(cluster: Cluster, book: LocalOrderBook) -> Double {
        switch cluster.side {
        case .bid:
            // Считаем объем только в лимитках на покупку
            return book.bids
                .filter { $0.price >= cluster.lowerBound && $0.price <= cluster.upperBound }
                .reduce(0) { $0 + $1.quantity }
                
        case .ask:
            // Считаем объем только в лимитках на продажу
            return book.asks
                .filter { $0.price >= cluster.lowerBound && $0.price <= cluster.upperBound }
                .reduce(0) { $0 + $1.quantity }
        }
    }
    
    
    private func noVolatilitySpike(currentCluster: Cluster, price: Double, book: LocalOrderBook) async -> Bool {
        
        // 1. Исправляем фильтрацию - применяем ко всем ордерам
        let clusterLevels = (book.bids + book.asks).filter { level in
            abs(level.price - currentCluster.price) / currentCluster.price < Constants.volatilitySpikeRadius
        }
        
        let clusterVolume = clusterLevels.reduce(0) { $0 + $1.quantity }
        let totalVolume = book.bids.reduce(0) { $0 + $1.quantity } +
                          book.asks.reduce(0) { $0 + $1.quantity }
        
        let concentration = totalVolume > 0 ? clusterVolume / totalVolume : 0
        
        let suddenConcentration = concentration > Constants.volatilityConcentrationThreshold
        
        // 3. Исправляем расчет спреда
        guard let bestAsk = await book.bestAsk, let bestBid = await book.bestBid else {
            return true // Нет данных - считаем что всё ок
        }
        
        let spread = bestAsk.price - bestBid.price
        let spreadPercent = spread / price
        let spreadSpike = spreadPercent > Constants.maxSpreadPercent
        
        // 4. Добавляем отладочный вывод
        /*print("""
            📊 Анализ волатильности:
               Концентрация объема в кластере: \(String(format: "%.1f", concentration * 100))% (порог \(Constants.volatilityConcentrationThreshold * 100)%)
               Спред: \(String(format: "%.3f", spread)) (\(String(format: "%.3f", spreadPercent * 100))%)
               Статус: \(suddenConcentration || spreadSpike ? "⚠️ ПОДОЗРИТЕЛЬНО" : "✅ НОРМА")
            """)*/
        
        // Возвращаем true если НЕТ всплеска (нет концентрации И спред нормальный)
        return !suddenConcentration && !spreadSpike
    }
    
    
    private func checkBattleConditions(stats: LevelBattleStats, cluster: Cluster, book: LocalOrderBook, initialVolume: Double) async -> Bool? {
        let attackerVol = stats.attackerVolume
        let defenderVolume = stats.defenderVolume
        let currentLimit = findCurrentVolume(cluster: cluster, book: book)
        
        // Суммарная мощь обороны = Лимиты + Рыночные покупки защитников
        let totalDefensePower = currentLimit + defenderVolume
        
        if attackerVol < Constants.attackerMinVolume {
            print("⏳ Уровень чист. Ждем активности агрессоров (сейчас: \(attackerVol) BTC)")
            return nil
        }
        
        // Абсолютный минимум лимитов (чтобы не заходить в пустой стакан)
        let minRequiredLimit = initialVolume * 0.3 // Хотя бы 30% от начальной плиты должно остаться
        if currentLimit < minRequiredLimit {
            print("🚩 Лимиты истощены (осталось < 30%). Риск проскальзывания слишком высок.")
            return false
        }
        
        // Коэффициент выживаемости (Armor)
        let armorRatio = totalDefensePower / (attackerVol > 0 ? attackerVol : 1.0)
        
        // ВИЗУАЛИЗАЦИЯ С ПОДДЕРЖКОЙ (🛡️)
        let healthIcons = Int(min(max(armorRatio, 0), 10))
        let bar = String(repeating: "🟦", count: healthIcons) + String(repeating: "⬜", count: 10 - healthIcons)
        
        print("""
        ⚔️ [БИТВА] ID: \(cluster.trackingId)

        | HP: [\(bar)] \(String(format: "%.2f", armorRatio))x
        | Атака (Market): \(String(format: "%.2f", attackerVol)) BTC
        | Лимиты: \(String(format: "%.2f", currentLimit)) BTC
        | Поддержка (Market): \(String(format: "%.2f", defenderVolume)) BTC 🛡️
        """)
        
        // ЛОГИКА ВХОДА С УЧЕТОМ ЗАЩИТНИКОВ
        // Если защитники активны (stats.isStrong), мы можем входить даже при меньшем лимите
        if await stats.isStrong {
            print("⚡ [СИЛЬНЫЙ УРОВЕНЬ] Защитники активно выкупают агрессию!")
            return true
        }
        
        if armorRatio < Constants.requiredLimitToAttackRatio {
            print("🚩 Защита пробита. Слишком много продаж.")
            return false
        }
        
        return true
    }
    
    
    // MARK: - Вспомогательные проверки
    private func isThinPath(cluster: Cluster) -> Bool {
        return cluster.cumulativeVolume < cluster.totalVolume * Constants.thinPathThreshold
    }
    
    
    private func didPriceTouchCluster(price: Double, cluster: Cluster) -> Bool {
        switch cluster.side {
        case .bid:
            return price <= cluster.upperBound
        case .ask:
            return price >= cluster.lowerBound
        }
    }
    
    
    private func isDistanceAcceptable(price: Double, cluster: Cluster) -> Bool {
        let distance = abs(cluster.price - price) / price
        return distance <= Constants.maxDistanceToCluster
    }
}

