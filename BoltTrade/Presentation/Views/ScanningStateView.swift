//
//  ScanningStateView.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct ScanningStateView: View {
    let message: String
    
    var body: some View {
        VStack(spacing: 15) {
            HStack(spacing: 15) {
                ProgressView().tint(.yellow).scaleEffect(1.2)
                VStack(alignment: .leading) {
                    Text("ПОИСК ЦЕЛИ").font(.headline).foregroundColor(.yellow)
                    Text(message).font(.caption).foregroundColor(.gray)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 30)
        }
        .frame(maxWidth: .infinity)
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.3), lineWidth: 1))
    }
}
