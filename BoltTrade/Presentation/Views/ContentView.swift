//
//  ContentView.swift
//  AutomaticTrading
//
//  Created by Igorchela on 21.12.25.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let viewModel = coordinator.strategyViewModel, let uiData = viewModel.ui {
                // Передаем актуальные данные из ViewModel в Widget
                ScaningDashboard(ui: uiData)
            } else {
                VStack {
                    ProgressView()
                    Text("Загрузка данных и обучение модели...")
                        .foregroundColor(.gray)
                        .padding()
                }
            }
        }
    }
}


#Preview {
    ContentView().environment(AppCoordinator())
}

