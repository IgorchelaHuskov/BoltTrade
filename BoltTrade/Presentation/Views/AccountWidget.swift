//
//  AccountWidget.swift
//  UIBOT
//
//  Created by Igorchela on 15.02.26.
//

import Foundation
import SwiftUI

// MARK: - Виджет аккаунта
struct AccountWidget: View {
    @State private var isShowingPopover = false
    @State private var tempAmount: Double = 0.0

    let accountInfo: AccountInfo
    let currentAmount: Double                   // текущая сумма из стратегии
    let onAmountConfirmed: (Double) -> Void     // колбэк при подтверждении
    
    let gradientColors = [
        Color(red: 63/255, green: 73/255, blue: 110/255), // Синий
        Color(red: 177/255, green: 65/255, blue: 126/255), // Пурпур
        Color(red: 219/255, green: 48/255, blue: 104/255)  // Розовый
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Верхний блок: Total + Pay
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.8))
                    
                    HStack(alignment: .center, spacing: 10) {
                        Text("$\(String(describing: accountInfo.totalBalance))")
                            .font(.system(size: 34, weight: .bold))
                        
                        // Зеленый бейдж
                        Text("$\(accountInfo.pnl)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Color(red: 0.2, green: 1.0, blue: 0.2))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                
                Spacer()
                
                // Иконка кошелька
                Button(action: {
                    isShowingPopover.toggle()
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "wallet.pass.fill")
                            .font(.system(size: 20))
                        Text("Pay")
                            .font(.system(size: 10))
                    }
                    .padding(4)
                    .contentShape(Rectangle()) // Чтобы кликалось по всей области
                }
                .buttonStyle(.plain) // Убирает стандартную серую обертку кнопки macOS
                
                .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Дост. \(accountInfo.available) USDT")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        
                        Text("Сумма для торговли")
                            .font(.system(size: 12, weight: .medium))
                        
                        HStack {
                            TextField("", value: $tempAmount, format: .number)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14, weight: .semibold))
                            
                            Divider().frame(height: 14)
                            
                            HStack(spacing: 4) {
                                Text("USDT")
                                    .fontWeight(.bold)
                                Image(systemName: "arrowtriangle.down.fill")
                                    .font(.system(size: 8))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.yellow.opacity(0.8), lineWidth: 1)
                        )
                        
                        Button("Подтвердить") {
                            onAmountConfirmed(tempAmount)
                            isShowingPopover = false
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding()
                    .frame(width: 220)
                    .onAppear {
                        tempAmount = currentAmount  // инициализируем текущим значением
                    }
                }
                
                
            }
            
            // Заголовок аккаунта
            HStack(spacing: 6) {
                Text("Binance Futures")
                    .font(.system(size: 20, weight: .semibold))
                Image(systemName: "info.circle") // Символ (i) как на фото
                    .font(.system(size: 14))
            }
            .padding(.top, 5)
            
            // Нижние показатели
            HStack(alignment: .top) {
                InfoColumn(label: "Available", value: accountInfo.available)
                Spacer()
                InfoColumn(label: "To With draw", value: accountInfo.availableToWithdraw)
                Spacer()
                // Правая колонка с иконкой замка
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                        Text("In positions")
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    
                    Text("$\(String(describing: accountInfo.inPosition))")
                        .font(.system(size: 18, weight: .semibold))
                }
            }
        }
        .padding(25)
        .foregroundColor(.white)
        .background(
            LinearGradient(
                gradient: Gradient(colors: gradientColors),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(25)
    }
}

// Вспомогательный вью для колонок внизу
struct InfoColumn: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))
            Text(value)
                .font(.system(size: 18, weight: .semibold))
        }
    }
}
