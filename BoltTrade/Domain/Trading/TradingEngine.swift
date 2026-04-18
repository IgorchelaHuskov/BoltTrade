//
//  TradingEngine.swift
//  TreadingBot
//
//  Created by Igorchela on 19.01.26.
//


import Foundation

actor TradingEngine {
    private var isRunning = false
    private var currentPrice:   Double  = 0.0
    private var currentBinPct:  Double  = 0.0
    private var currentBinAbs:  Double  = 0.0
    
    private var marketMetrics: MarketMetrics?
    private var marketState: MarketStateAnalyzer.MarketState = .flat
    private var currentConfigs: [MarketStateAnalyzer.MarketState: MarketConfig] = [:]
    
    private let dataService: DataService
    private let strategies: [any TradingStrategy]
    private let orderBookClusterer = OrderBookClusterer()
    private let levelStatsManager: LevelStatsManager
    private let marketStateAnalyzer: MarketStateAnalyzer
    private let orderManager: OrderManager
    
    private var tradeTask: Task<Void, Never>?
    private var bookTask: Task<Void, Never>?
    private var binTask: Task<Void, Never>?
    
    var binCalculator: DynamicBinCalculator
    
    private let updatesClusterContinuation: AsyncStream<[Cluster]>.Continuation
    let updatesStreamCluster: AsyncStream<[Cluster]>
    
    
    init(dataService: DataService,
         strategies: [any TradingStrategy],
         binCalculator: DynamicBinCalculator,
         marketStateAnalyzer: MarketStateAnalyzer,
         levelStatsManager: LevelStatsManager,
         orderManager: OrderManager)
    {
        self.dataService = dataService
        self.strategies = strategies
        self.binCalculator = binCalculator
        self.marketStateAnalyzer = marketStateAnalyzer
        self.levelStatsManager = levelStatsManager
        self.orderManager = orderManager
        (self.updatesStreamCluster, self.updatesClusterContinuation) = AsyncStream.makeStream(of: [Cluster].self)
    }
    
    
    func start() async {
        
        Task { try? await binCalculator.start() }
        
        guard !isRunning else { return }
        isRunning = true
        
        print("🚀 TradingEngine: Запуск...")
        
        let bookStream = await dataService.localOrderBookStream()
        let tradeStream = await dataService.tradeStream()
        
        
        
        // Задача обновления рыночных данных - минимизируем количество обновлений
        binTask = Task { [weak self] in
            guard let self = self else { return }
            for await stream in await binCalculator.marketcurrentStream {
                // Вызов метода актора для обновления состояния
                await self.updateMarketData(stream: stream)
            }
        }
        
        
        // Запускаем задачу для распределения сделок по стратегиям
        tradeTask = Task { [weak self] in
            guard let self = self else { return }
            for await trade in tradeStream {
                guard !Task.isCancelled else { break }
                // Отправляем трейд в менеджер статистики
                await levelStatsManager.procesTrade(trade: trade)
            }
        }
        
        
        // Основной цикл по стакану в отдельной задаче
        bookTask = Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            for await newBook in bookStream {
                guard !Task.isCancelled else { break }
                await Task.yield()
                await self.processOrderBook(newBook)
            }
        }
    }
    
    
    func stop() async {
        tradeTask?.cancel()
        tradeTask = nil
        bookTask?.cancel()
        bookTask = nil
        updatesClusterContinuation.finish()
        binTask?.cancel()
        binTask = nil
        isRunning = false
    }
    
    
    
    private func processOrderBook(_ newBook: LocalOrderBook) async {
        guard let bestAsk       =   await newBook.bestAsk,
              let bestBid       =   await newBook.bestBid,
              let marketMetrics =   self.marketMetrics,
              currentBinAbs > 0  else { return }
        
        self.currentPrice = (bestBid.price + bestAsk.price) / 2
        
        let clusters = await orderBookClusterer.clusterOrderBook(localOrderBook: newBook,
                                                                 binSizeAbs: currentBinAbs,
                                                                 currentPrice: currentPrice,
                                                                 marketState: marketState,
                                                                 configs: currentConfigs)
        
        // Обновляем менеджер статистики
        await levelStatsManager.updateClusters(clusters: clusters)
        
        // 3. ЗАБИРАЕМ актуальную статистику боя
        let battleStats = await levelStatsManager.getAllStats()
        let marketSnapshot = MarketSnapshot(timestamp: Date(),
                                            currentPrice: self.currentPrice,
                                            state: self.marketState,
                                            metrics: marketMetrics,
                                            config: self.currentConfigs[self.marketState],
                                            bin: (currentBinPct, currentBinAbs),
                                            clusters: clusters,
                                            book: newBook,
                                            battleStats: battleStats)
        
        await processStrategies(marketSnapshot: marketSnapshot)
    }
    
    
    private func updateMarketData(stream: MarketStateData) async {
        self.currentConfigs = await marketStateAnalyzer.getConfigs()
        self.currentBinAbs = stream.bin.abs
        self.currentBinPct = stream.bin.pct
        self.marketMetrics = stream.metrics
        self.marketState = stream.marketState
    }
    
    
    private func processStrategies(marketSnapshot: MarketSnapshot) async {
        for strategy in strategies {
            if let signal = await strategy.analyze(marketSnapshot: marketSnapshot) {
                
                // Благодаря enum с данными, обработка превращается в сказку:
                switch signal {
                case .buy(_):
                    await orderManager.openPosition(signal: signal)
                    
                case .sell(_):
                    await orderManager.openPosition(signal: signal)
                    
                case .exit(let side):
                    await orderManager.closePosition(side: side)
                }
            }
        }
    }
}

