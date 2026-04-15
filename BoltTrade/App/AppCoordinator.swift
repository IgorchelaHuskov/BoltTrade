//
//  AppCordinator.swift
//  TreadingBot
//
//  Created by Igorchela on 22.01.26.
//

import Foundation
import SwiftData

@MainActor // Гарантирует потокобезопасность массива задач и работы с UI
@Observable
final class AppCoordinator {
    private(set) var dataService: DataService!
    private(set) var tradingService: TradingEngine!
    private(set) var bounce: BounceStrategy!
    private(set) var binCalculator: DynamicBinCalculator!
    private(set) var historyService: HistoricalCandleService!
    private(set) var marketStateAnalyzer: MarketStateAnalyzer!
    private(set) var levelStatsManager: LevelStatsManager!
    private(set) var strategyViewModel: StrategyViewModel?
    
    private var tasks: [Task<Void, Never>] = []
    
    init() {}

    func start(with container: ModelContainer) {
        stopTasks()
        print(URL.applicationSupportDirectory.path(percentEncoded: false))

        tasks.append(Task {
            let wsService = WebSocketService()
            let dataProvider = DataProvider(wsService: wsService)
            let dataService = DataService(dataProvider: dataProvider)
            
            self.historyService = HistoricalCandleService(dataProvider: dataProvider, modelContainer: container)
            self.marketStateAnalyzer = MarketStateAnalyzer(modelContainer: container)
            do {
                if !(await self.historyService.hasHistoricalData()) {
                    print("📥 Загрузка исторических данных...")
                    try await self.historyService.fetchAndSaveHistoricalData()
                }
                
                let needsRetrain = await self.marketStateAnalyzer.shouldRetrain()
                
                if needsRetrain {
                    print("🧠 НАЧИНАЕМ ОБУЧЕНИЕ...")
                    let candles = try await self.historyService.getCandlesFromDataBase()
                    await self.marketStateAnalyzer.trainOnHistoricalData(candles: candles)
                    print("✅ ОБУЧЕНИЕ ЗАВЕРШЕНО!")
                } else {
                    // Конфиги свежие - загружаем из БД
                    print("📂 Загрузка сохраненных конфигов...")
                    await self.marketStateAnalyzer.loadConfigsFromDB()
                }
                                                                         
            } catch {
                print("Ошибка загрузки истории: \(error)")
            }

            self.levelStatsManager = LevelStatsManager()
            
            self.bounce = BounceStrategy()
            
            self.strategyViewModel = StrategyViewModel(strategy: self.bounce, dataProvider: dataProvider)
            
            self.binCalculator = DynamicBinCalculator(dataService: dataService,
                                                      marketStateAnalyzer: marketStateAnalyzer,
                                                      historyService: historyService, modelContainer: container)
            
            self.tradingService = TradingEngine(dataService: dataService,
                                                strategies: [bounce],
                                                binCalculator: binCalculator,
                                                marketStateAnalyzer: marketStateAnalyzer,
                                                levelStatsManager: levelStatsManager)
    
            self.dataService = dataService
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.dataService.start() }
                group.addTask { await self.tradingService.start() }
            }
        })
    }


    func stop() async {
        // 2. Отменяем и очищаем задачи
        stopTasks()
        
        // 3. Останавливаем сервисы (ожидаем их внутреннего завершения)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.dataService.stop() }
            group.addTask { await self.tradingService.stop() }
        }
    }
    
    private func stopTasks() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
}

