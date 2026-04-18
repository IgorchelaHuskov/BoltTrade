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

    
    private let customBackground = Color(red: 36/255, green: 47/255, blue: 77/255)
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let viewModel = coordinator.strategyViewModel, let uiData = viewModel.ui {
                HStack(spacing: 0) {
                    // --- ЛЕВАЯ КОЛОНКА (Аккаунт и История) ---
                    VStack(alignment: .leading, spacing: 25) {
                        AccountWidget(accountInfo: viewModel.accountInfo,
                                      currentAmount: viewModel.currentAmountUSDT,
                                      onAmountConfirmed: { newAmount in viewModel.setAmountUSDT(newAmount) })
                        
                        VStack(alignment: .leading, spacing: 15) {
                            Text("История входов")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white.opacity(0.6))
                            
                            TradeHistoryView(
                                trades: uiData.tradeHistory,
                                selectedTrade: $selectedTrade,
                                showTradeDetail: $showTradeDetail
                            )
                        }
                        Spacer()
                    }
                    .frame(width: 420)
                    .padding(45)
                    
                    // --- ПРАВАЯ ПАНЕЛЬ (Дашборд) ---
                    TradingDashboard(ui: uiData)
                        .frame(maxWidth: .infinity)
                }
                .background(customBackground.ignoresSafeArea())
            } else {
                VStack {
                    ProgressView()
                    Text("Загрузка данных и обучение модели...")
                        .foregroundColor(.gray)
                        .padding()
                }
            }
            
            // Всплывающее окно TradeDetailView поверх всего
            if showTradeDetail, let selectedTrade = selectedTrade {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)
                
                TradeDetailView(trade: selectedTrade, showTradeDetail: $showTradeDetail)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: showTradeDetail)
    }
}



#Preview {
    ContentView().environment(AppCoordinator())
}
