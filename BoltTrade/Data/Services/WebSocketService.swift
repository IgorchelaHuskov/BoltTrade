//
//  WebSocketService.swift
//  Treading
//
//  Created by Igorchela on 9.01.26.
//
/*
 Вариант 2: Один сервис — много потоков
 Если ты хочешь использовать один WebSocketService, он должен уметь создавать разные AsyncStream для каждого URL.
 Проверь свой WebSocketService: если он хранит continuation в одном свойстве, то при втором вызове start() он просто перезаписывает старый, и все данные начинают лететь в одно место.
 Что сделать прямо сейчас:
 Проверь WebSocketService: если внутри него один URLSessionWebSocketTask, то он не может держать два соединения одновременно. Тебе нужно либо два сервиса, либо массив тасков внутри сервиса.
 */


import Foundation

actor WebSocketService {
    // Структура для хранения всего, что относится к одному соединению
    private struct Connection: Sendable {
        let task: URLSessionWebSocketTask
        let continuation: AsyncStream<Data>.Continuation
    }
    
    // Словари для управления несколькими потоками
    private var connections: [String: Connection] = [:]
    private var isRunning: [String: Bool] = [:]
    private var reconnectIntervals: [String: TimeInterval] = [:]

    private let maxReconnectInterval: TimeInterval = 64.0

    func start(urlString: String) -> AsyncStream<Data> {
        return AsyncStream { continuation in
            let url = URL(string: urlString)!
            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: url)
            
            // Сохраняем "канал"
            let connection = Connection(task: task, continuation: continuation)
            self.connections[urlString] = connection
            self.isRunning[urlString] = true
            self.reconnectIntervals[urlString] = 1.0
            
            task.resume()
            print("WebSocket: Connecting to \(urlString)...")

            // Запускаем прослушку в отдельной задаче
            Task { [weak self] in
                await self?.listen(urlString: urlString)
            }
            
            // Если подписчик отменил Task, закрываем именно это соединение
            continuation.onTermination = { _ in
                Task { [weak self] in
                    await self?.disconnect(urlString: urlString)
                }
            }
        }
    }

    private func listen(urlString: String) async {
        while isRunning[urlString] == true {
            guard let connection = connections[urlString] else { break }
            
            do {
                let message = try await connection.task.receive()
                
                // Сбрасываем интервал при успехе
                reconnectIntervals[urlString] = 1.0
                
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let d): data = d
                @unknown default: continue
                }
                
                // Отправляем данные именно в тот стрим, который относится к этому URL
                connection.continuation.yield(data)
                
            } catch {
                print("WebSocket Error [\(urlString)]: \(error.localizedDescription)")
                
                // Если ошибка — закрываем текущий таск и пробуем реконнект
                connection.task.cancel(with: .goingAway, reason: nil)
                if isRunning[urlString] == true {
                    await handleReconnect(urlString: urlString)
                }
                break
            }
        }
    }
    
    func send(urlString: String, data: Data) async {
        guard let connection = connections[urlString] else { return }
        
        // Превращаем JSON-данные в строку
        guard let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        do {
            // Отправляем как СТРОКУ, а не как DATA
            try await connection.task.send(.string(jsonString))
        } catch {
            print("❌ Ошибка отправки: \(error.localizedDescription)")
        }
    }

    private func handleReconnect(urlString: String) async {
        guard isRunning[urlString] == true else { return }
        
        let interval = reconnectIntervals[urlString] ?? 1.0
        print("WebSocket: Reconnecting \(urlString) in \(interval)s...")
        
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        
        // Увеличиваем интервал для следующего раза (экспоненциально)
        reconnectIntervals[urlString] = min(interval * 2, maxReconnectInterval)
        
        // Переподключаемся: создаем новый таск и обновляем словарь
        let url = URL(string: urlString)!
        let newTask = URLSession.shared.webSocketTask(with: url)
        
        if let current = connections[urlString] {
            let newConnection = Connection(task: newTask, continuation: current.continuation)
            connections[urlString] = newConnection
            newTask.resume()
            await listen(urlString: urlString)
        }
    }

    func disconnect(urlString: String) {
        print("WebSocket: Disconnecting \(urlString)")
        isRunning[urlString] = false
        connections[urlString]?.task.cancel(with: .goingAway, reason: nil)
        connections[urlString]?.continuation.finish()
        connections[urlString] = nil
        reconnectIntervals[urlString] = nil
    }
}
