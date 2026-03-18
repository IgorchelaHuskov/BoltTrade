//
//  TargetClusterView.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct TargetClusterView: View {
    let target: TargetClusterInfo
    let message: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderRow(title: "КЛАСТЕР #\(String(format: "%.0f", target.id))",
                      badge: target.type,
                      badgeColor: target.type == "Поддержка" ? .green : .red)
            
            StatusRow(message: message, color: .yellow)
            
            HStack {
                BoundView(label: "Нижняя граница", value: target.lowerBound)
                Spacer()
                BoundView(label: "Верхняя граница", value: target.upperBound, alignment: .trailing)
            }
            
            Divider().background(Color.gray)
            
            HStack {
                if target.initialVolume > 0 {
                    VolumeDynamicsView(target: target)
                }
                Spacer()
                VStack {
                    Text("СИЛА (Z-SCORE)").font(.caption2).foregroundColor(.gray)
                    Text(String(format: "%.1fσ", target.power))
                        .font(.subheadline)
                        .foregroundColor(target.power > 2.5 ? .green : .yellow)
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.3), lineWidth: 1))
    }
}
