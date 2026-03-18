//
//  StateDependentView.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct StateDependentView: View {
    let ui: StrategyUIState
    
    var body: some View {
        if let position = ui.positionInfo {
            OpenPositionView(position: position, currentPrice: ui.price)
        } else if let target = ui.targetCluster {
            if target.hasTouched {
                BattleMonitoringView(target: target, message: ui.statusMessage)
            } else {
                TargetClusterView(target: target, message: ui.statusMessage)
            }
        } else {
            ScanningStateView(message: ui.statusMessage)
        }
    }
}
