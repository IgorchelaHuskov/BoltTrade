//
//  TradeHistoryItemView.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct TradeHistoryItemView: View {
    let trade: TradeHistoryItem
    @State private var isHovered = false // Состояние для анимации
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. Верхний ряд: Название и Дата
            HStack {
                // Тип сделки (LONG/SHORT) и иконка
                HStack(spacing: 4) {
                    Text(trade.side == .bid ? "🟢 LONG" : "🔴 SHORT")
                        .font(.system(size: 13, weight: .semibold))
                    
                    Image(systemName: "bitcoinsign.circle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 16))
                }
                
                Text("BTC/USDT")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Text(trade.entryDate, style: .date)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            
            // 2. Средний ряд: Вход и Выход
            HStack {
                Text(String(format: "Вход: $%.2f", trade.entryPrice))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                
                Spacer()
                
                if let exit = trade.exitPrice {
                    Text(String(format: "Выход: $%.2f", exit))
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    Text("В позиции")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.cyan)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(8)
    
            
            // 3. Нижний ряд: P/L и Процент
            HStack {
                Text(String(format: "P/L: $%.2f", trade.profitLoss))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(trade.profitLoss >= 0 ? Color(red: 0.4, green: 1.0, blue: 0.7) : Color(red: 1.0, green: 0.3, blue: 0.5))
                
                Spacer()
                
                Text(String(format: "%.2f%%", trade.profitLossPercent))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(trade.profitLossPercent >= 0 ? Color(red: 0.4, green: 1.0, blue: 0.7) : Color(red: 1.0, green: 0.3, blue: 0.5))
            }
        }
        .padding(55)
        // ФОН: Полупрозрачный как на скрине
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(isHovered ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
                .background(BlurView()) // Добавляем размытие заднего фона
        )
        // ЭФФЕКТЫ: Увеличение и рамка
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(isHovered ? Color.white.opacity(0.2) : Color.clear, lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.03 : 1.0) // Увеличение на 3%
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .padding(.horizontal, 5)
    }
}

// Вспомогательный элемент для размытия (Blur) на macOS
struct BlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
