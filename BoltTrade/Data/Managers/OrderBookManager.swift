//
//  OrderBookManager.swift
//  Treading
//
//  Created by Igorchela on 9.01.26.
//

/*
  Шаг 1-2: Открываем WebSocket и буферизуем события
  Шаг 3: Получаем снимок через REST
  Шаг 4: Если lastUpdateId < U, перезагружаем снимок
  Шаг 5: Отбрасываем события, где u <= lastUpdateId
  Шаг 6: Проверяем условие U <= lastUpdateId+1 <= u
  Шаг 7: Устанавливаем локальную книгу из снимка
  Шаг 8: Применяем отфильтрованные события
  Шаг 9: Для каждого нового события:
         Игнорируем если u <= lastUpdateId
         Пересинхронизируемся если U > lastUpdateId + 1
         Применяем обновления если условия выполнены
 */

import Foundation

actor OrderBookManager {
    
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case synchronizing
        case synchronized
    }

    private var connectionState: ConnectionState = .disconnected
    private var streamTask: Task<Void, Never>?
    private var errorMessage: String?
    private var reconnectAttempt = 0
    private var lastNotifyTime: ContinuousClock.Instant = .now
    private let dataProvider: DataProvider
    private let bookStreamManager: BookStreamManager
    private let bookSnapshotManager: BookSnapshotManager
    
    private var bidsDict: [Int : Double] = [:]
    private var asksDict: [Int : Double] = [:]
    private var lastUpdateId: Int = 0

    private var buffer: [OrderBookStreamUpdate] = []
    
    // Механизм для трансляции обновлений
    private let updatesContinuation: AsyncStream<LocalOrderBook>.Continuation
    let updatesStream: AsyncStream<LocalOrderBook>
    
    init(dataProvider: DataProvider){
        self.dataProvider = dataProvider
        self.bookStreamManager = BookStreamManager(dataProvider: dataProvider)
        self.bookSnapshotManager = BookSnapshotManager(dataProvider: dataProvider)
        (self.updatesStream, self.updatesContinuation) = AsyncStream.makeStream(of: LocalOrderBook.self)
    }
    
    
    // Основной метод запуска
    func start() async throws {
        if streamTask != nil {
            return
        }
        
        connectionState = .connecting
        
        //reconnectAttempt = 0 // Сбрасываем счетчик попыток
        
        try await self.bookStreamManager.start()
        
        // 2. Открываем WebSocket соединение
        startStream()
    }
    
    
    // Метод остановки
    func stopAll() async {
        streamTask?.cancel()
        streamTask = nil
        buffer.removeAll()
        updatesContinuation.finish()
        connectionState = .disconnected
        await self.bookStreamManager.stop()
    }
    
    
    private func broadcast(book: LocalOrderBook) {
        updatesContinuation.yield(book)
    }
    
    
    // MARK: Шаг 1-2: Открытие WebSocket и буферизация событий
    private func startStream()  {
        streamTask?.cancel()
        
        streamTask = Task {
            while !Task.isCancelled {
                // 1. Сброс состояния перед попыткой
                self.buffer.removeAll()
                self.connectionState = .connecting
                
                let stream = bookStreamManager.bookStream
                
                for await update in stream {
                    if Task.isCancelled { break }
                    
                    // Переходим в статус .connected только при получении данных
                    if self.connectionState == .connecting {
                        self.connectionState = .connected
                        self.reconnectAttempt = 0
                        print("✅ WebSocket данные пошли...")
                    }
                    
                    // Шаг 8: Если синхронизированы — применяем сразу
                    if self.connectionState == .synchronized {
                        self.applyUpdate(update)
                        continue
                    }
                  
                    self.buffer.append(update)
                    
                    // Шаг 3: Запуск синхронизации (REST Snapshot)
                    // Используем проверку на .connected, чтобы не запускать повторно,
                    // если мы уже в процессе (.synchronizing)
                    if self.connectionState == .connected && !self.buffer.isEmpty {
                        await self.synchronizeOrderBook()
                        // После успешного synchronizeOrderBook состояние станет .synchronized
                    }
                }
                
                // Если вышли из стрима — проверяем причину
                if Task.isCancelled { break }
                self.connectionState = .disconnected
                self.errorMessage = "Связь прервана."
                self.buffer.removeAll()
                break
            }
        }
    }
    
    // MARK: Шаги 3-7: Синхронизация с REST snapshot
    private func synchronizeOrderBook() async{
        if self.connectionState == .synchronizing { return }
        
        self.connectionState = .synchronizing
        
        // MARK: Шаг 3: Получаем снимок глубины
        var snapshot: OrderBookSnapshot?
        var retryCount = 0
        let maxRetries = 3
        
        while snapshot == nil && retryCount < maxRetries && !Task.isCancelled {
            do {
                let force = retryCount > 0
                let result = try await bookSnapshotManager.getOrderBook(forceUpdate: force)
                snapshot = result
                
            } catch {
                retryCount += 1
                self.errorMessage = "Ошибка загрузки снимка: \(error.localizedDescription)"
                
                if Task.isCancelled { break }
                if retryCount < maxRetries {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        
        guard var currentSnapshot = snapshot,
              !Task.isCancelled else {
            self.errorMessage = "Не удалось загрузить снимок стакана"
            self.connectionState = .connected
            return
        }
        
        // Ждем, пока в буфере будет хотя бы одно событие
        while buffer.isEmpty && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        guard let firstBufferedEvent = buffer.first, !Task.isCancelled else {
            self.errorMessage = "Нет событий в буфере для синхронизации"
            self.connectionState = .connected
            return
        }
        
        // MARK: Шаг 4: Если lastUpdateId < U, загружаем новый снимок
        while currentSnapshot.lastUpdateId < firstBufferedEvent.firstUpdateID && !Task.isCancelled {
            do {
                let newSnapshot = try await bookSnapshotManager.getOrderBook(forceUpdate: true)
                currentSnapshot = newSnapshot
            } catch {
                self.errorMessage = "Ошибка при перезагрузке снимка: \(error.localizedDescription)"
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        
        guard !Task.isCancelled else { return }
        
        // MARK: Шаг 5: Фильтруем буферизованные события (отбрасываем те, где u <= lastUpdateId)
        let filteredBuffer = buffer.filter { $0.finalUpdateID > currentSnapshot.lastUpdateId }

        // ОСОБЫЙ СЛУЧАЙ: если фильтрованный буфер пуст
        if filteredBuffer.isEmpty {
            // Устанавливаем локальную книгу из снимка
            self.bidsDict = Dictionary(uniqueKeysWithValues: currentSnapshot.bids.map {(Int(($0.price * 100).rounded()), $0.quantity) })
            self.asksDict = Dictionary(uniqueKeysWithValues: currentSnapshot.asks.map {(Int(($0.price * 100).rounded()), $0.quantity) })
            self.lastUpdateId = currentSnapshot.lastUpdateId
            self.buffer.removeAll()
            self.connectionState = .synchronized

            return
        }
        
        // СТАНДАРТНЫЙ СЛУЧАЙ: есть события после снимка
        guard let firstEventAfterSnapshot = filteredBuffer.first else {
            self.errorMessage = "Нет подходящих событий после фильтрации"
            self.connectionState = .connected
            return
        }
        
        // MARK: Проделываем Шаг 6: Проверяем условие U <= lastUpdateId+1 <= u
        let condition = firstEventAfterSnapshot.firstUpdateID <= currentSnapshot.lastUpdateId+1 && currentSnapshot.lastUpdateId+1 <= firstEventAfterSnapshot.finalUpdateID
        
        guard condition else {
            self.errorMessage = "Условие синхронизации не выполнено. Начинаем заново..."
            self.connectionState = .connected
            self.buffer.removeAll()
            return
        }
        
        // MARK: Шаг 7: Устанавливаем локальную книгу на основе снимка
        var bidLevels: [OrderBookLevel] = []
        for bid in currentSnapshot.bids {
            let level = OrderBookLevel(price: bid.price, quantity: bid.quantity)
            bidLevels.append(level)
        }

        
        var askLevels: [OrderBookLevel] = []
        for ask in currentSnapshot.asks {
            let level = OrderBookLevel(price: ask.price, quantity: ask.quantity)
            askLevels.append(level)
        }

        self.bidsDict = Dictionary(uniqueKeysWithValues: currentSnapshot.bids.map {(Int(($0.price * 100).rounded()), $0.quantity) })
        self.asksDict = Dictionary(uniqueKeysWithValues: currentSnapshot.asks.map {(Int(($0.price * 100).rounded()), $0.quantity) })
        self.lastUpdateId = currentSnapshot.lastUpdateId
        

        
        // MARK: Шаг 8: Применяем все отфильтрованные буферизованные события
        for event in filteredBuffer {
             applyUpdate(event)
        }
        
        self.buffer.removeAll()
        self.connectionState = .synchronized
    }
    
    
    // MARK: Шаг 9: Применение обновлений к локальной книге
    private func applyUpdate(_ update: OrderBookStreamUpdate) {
        // 1. Проверки ID (твои 9.1 и 9.2) - оставляем как есть
        if update.finalUpdateID <= self.lastUpdateId { return }
        if update.firstUpdateID > self.lastUpdateId + 1 {
            self.connectionState = .connected
            self.buffer.removeAll()
            return
        }

        // 2. Обновляем СЛОВАРИ (это почти бесплатно, O(1))
        updateSide(&bidsDict, with: update.bids)
        updateSide(&asksDict, with: update.asks)
        self.lastUpdateId = update.finalUpdateID

        // 3. ТРОТТЛИНГ: Сортируем и рассылаем только если прошло 100мс
        let now = ContinuousClock.Instant.now
        if now - lastNotifyTime >= .milliseconds(250) {
            let bookToBroadcast = self.createSnapshot() // Вызываем тяжелый метод РЕДКО
            self.broadcast(book: bookToBroadcast)
            self.lastNotifyTime = now
        }
    }

    private func createSnapshot() -> LocalOrderBook {
        // 1. Находим экстремумы (они теперь Int)
        guard let maxBidKey = bidsDict.keys.max(),
              let minAskKey = asksDict.keys.min() else {
            return LocalOrderBook(bids: [], asks: [], lastUpdateId: lastUpdateId)
        }

        // 2. Считаем midPrice в Double для точности
        let bestBidPrice = Double(maxBidKey) / 100.0
        let bestAskPrice = Double(minAskKey) / 100.0
        let midPrice = (bestBidPrice + bestAskPrice) / 2
        
        // 3. Переводим границы фильтрации в Int (один раз!)
        // Используем 0.05 для 5%
        let rangeDouble = midPrice * 0.05
        let lowerBoundKey = Int(((midPrice - rangeDouble) * 100).rounded())
        let upperBoundKey = Int(((midPrice + rangeDouble) * 100).rounded())

        // 4. Фильтруем (сравнение Int против Int — это очень быстро)
        let filteredBids = bidsDict
            .filter { $0.key >= lowerBoundKey }
            .map { OrderBookLevel(price: Double($0.key) / 100.0, quantity: $0.value) }
            .sorted { $0.price > $1.price }
                
        let filteredAsks = asksDict
            .filter { $0.key <= upperBoundKey }
            .map { OrderBookLevel(price: Double($0.key) / 100.0, quantity: $0.value) }
            .sorted { $0.price < $1.price }
        return LocalOrderBook(bids: filteredBids, asks: filteredAsks, lastUpdateId: lastUpdateId)
    }


    private func updateSide(_ dict: inout [Int: Double], with updates: [OrderBookEntryStream]) {
        for update in updates {
            let priceKey = Int((update.price * 100).rounded())
            if update.quantity == 0 {
                dict.removeValue(forKey: priceKey) // O(1)
            } else {
                dict[priceKey] = update.quantity // O(1)
            }
        }
    }
    
    
}
