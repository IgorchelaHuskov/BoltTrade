//
//  ArmorIndicator.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct ArmorIndicator: View {
    let ratio: Double
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<6) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(ratio > Double(i) * 0.5 ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 12)
            }
        }
        .padding(.leading, 5)
    }
}
