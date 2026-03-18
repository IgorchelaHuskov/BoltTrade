//
//  ContentView.swift
//  AutomaticTrading
//
//  Created by Igorchela on 21.12.25.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showTradeDetail = false
    @State private var selectedTrade: TradeHistoryItem?
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let viewModel = coordinator.strategyViewModel, let uiData = viewModel.ui {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        // Левая панель - 30% от окна
                        TradeHistoryView(trades: uiData.tradeHistory, selectedTrade: $selectedTrade, showTradeDetail: $showTradeDetail)
                            .frame(width: geometry.size.width * 0.3)
                            .background(Color.gray.opacity(0.2))
                        
                        // Правая панель - 70%
                        TradingDashboard(ui: uiData)
                            .frame(width: geometry.size.width * 0.7)
                    }
                }
            } else {
                VStack {
                    ProgressView()
                    Text("Загрузка данных и обучение модели...")
                        .foregroundColor(.gray)
                        .padding()
                }
            }
            
            // Всплывающее окно TradeDetailView
            if showTradeDetail, let selectedTrade = selectedTrade {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)
                
                TradeDetailView(trade: selectedTrade, showTradeDetail: $showTradeDetail)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showTradeDetail)
    }
}


#Preview {
    ContentView().environment(AppCoordinator())
}
