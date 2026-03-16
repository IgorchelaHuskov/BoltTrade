//
//  ScaningDashBoard.swift
//  BoltTrade
//
//  Created by Igorchela on 15.03.26.
//

import Foundation
import SwiftUI


struct ScaningDashboard: View {
    let ui: StrategyUIState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            
            // --- ВЕРХНЯЯ ПАНЕЛЬ ---
            VStack(spacing: 8) {
                HStack {
                    Text("Current Price :")
                    Spacer()
                    Text(String(format: "%.2f", ui.price))
                        .bold()
                }
                HStack {
                    Text("Состояние Рынка :")
                    Spacer()
                    Text(ui.marketStatus.uppercased())
                        .foregroundColor(.blue)
                }
            }
            .font(.system(.body, design: .monospaced))
            
            Divider().background(Color.gray)
            
            // --- ТАБЛИЦА ASK ---
            VStack(alignment: .leading, spacing: 4) {
                Text("ask").font(.caption.bold()).foregroundColor(.red)
                ForEach(ui.asks) { ask in
                    ClusterRowView(row: ask, color: .red)
                }
            }
            
            // --- ТАБЛИЦА BID ---
            VStack(alignment: .leading, spacing: 4) {
                Text("bid").font(.caption.bold()).foregroundColor(.green)
                ForEach(ui.bids) { bid in
                    ClusterRowView(row: bid, color: .green)
                }
            }
            
            Divider().background(Color.gray)
            
            VStack(alignment: .leading, spacing: 5) {
                if let target = ui.targetCluster {
                    Text("Целевой кластер: \(target.id) Тип: \(target.type) ")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.yellow)
                    
                    HStack {
                        Text("Границы: \(target.lowerBound) — \(target.upperBound)")
                        Spacer()
                        Text("\(target.volume) BTC")
                        Spacer()
                        Text("\(target.power) Сила")
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView() // Маленький спиннер
                            .tint(.yellow)
                            .scaleEffect(0.8)
                        
                        Text("ПОИСК ЦЕЛЕВОГО КЛАСТЕРА...")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.yellow)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
                }
                
                //Text("Состояние: \(ui.strategyState)")
                  //  .font(.caption)
                    //.italic()
            }
            .padding(10)
            .background(Color.yellow.opacity(0.1))
            .cornerRadius(8)
            .font(.system(.subheadline, design: .monospaced))
        }
        .padding()
        .background(Color(white: 0.1)) // Темный фон как в терминале
        .cornerRadius(15)
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
        )
        .padding()
    }
}


