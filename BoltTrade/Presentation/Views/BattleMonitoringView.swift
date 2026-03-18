//
//  BattleMonitoringView.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct BattleMonitoringView: View {
    let target: TargetClusterInfo
    let message: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("КЛАСТЕР #\(String(format: "%.0f", target.id))")
                    .font(.headline).foregroundColor(.orange)
                Spacer()
                if target.monitoringDuration > 0 {
                    Text(UIUtilities.formatDuration(target.monitoringDuration))
                        .font(.caption).foregroundColor(.gray)
                }
            }
            
            HStack {
                Text("СТАТУС:").foregroundColor(.gray)
                Text(message).foregroundColor(.orange)
                if target.hasTouched {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
                }
            }
            .font(.caption)
            
            if target.monitoringDuration > 0 {
                HStack {
                    Text("Время в наблюдении:").foregroundColor(.gray)
                    Text(UIUtilities.formatDuration(target.monitoringDuration)).foregroundColor(.white)
                }
                .font(.caption)
            }
            
            HStack {
                BoundView(label: "LOWER", value: target.lowerBound)
                Spacer()
                BoundView(label: "UPPER", value: target.upperBound, alignment: .trailing)
            }
            
            Divider().background(Color.gray)
            
            if target.attackerVolume > 0 || target.defenderVolume > 0 {
                BattleStatsView(target: target)
            }
            if target.initialVolume > 0 {
                VolumeDynamicsView(target: target)
            }
            EntryConditionsView(target: target)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }
}
