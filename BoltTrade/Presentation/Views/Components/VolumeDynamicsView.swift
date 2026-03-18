//
//  VolumeDynamicsView.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct VolumeDynamicsView: View {
    let target: TargetClusterInfo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "ДИНАМИКА ОБЪЕМА", color: .orange)
            VolumeBar(current: target.currentVolume,
                      initial: target.initialVolume,
                      percent: target.volumeRetainedPercent)
                .frame(height: 60)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledValue(label: "Начальный:", value: String(format: "%.3f BTC", target.initialVolume))
                    LabeledValue(label: "Текущий:", value: String(format: "%.3f BTC", target.currentVolume))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Изменение").font(.caption2).foregroundColor(.gray)
                    HStack(spacing: 4) {
                        Image(systemName: target.volumeRetainedPercent > 100 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundColor(UIUtilities.changeColor(target.volumeRetainedPercent))
                            .font(.system(size: 16))
                        Text("\(abs(target.volumeRetainedPercent - 100), specifier: "%.1f")%")
                            .font(.headline)
                            .foregroundColor(UIUtilities.changeColor(target.volumeRetainedPercent))
                    }
                }
            }
            .font(.caption)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
}
