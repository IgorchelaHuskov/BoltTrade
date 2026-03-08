//
//  BoltTradeApp.swift
//  BoltTrade
//
//  Created by Igorchela on 9.03.26.
//

import SwiftUI
import SwiftData

@main
struct BoltTradeApp: App {
    @State private var coordinator = AppCoordinator()
    
    // Создаем контейнер для нашей модели свечей
    let container: ModelContainer = {
        let schema = Schema([CandleEntity.self, MarketConfigEntity.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coordinator)
                .modelContainer(container)
                .task {
                    // Автозапуск при открытии приложения
                    coordinator.start(with: container)
                }
                .onDisappear {
                    Task {
                        // Автоостановка при закрытии
                        await coordinator.stop()
                    }
                }
        }
        
    }
}
