//
//  BoundView.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct BoundView: View {
    let label: String
    let value: Double
    var alignment: Alignment = .leading
    
    var body: some View {
        VStack(alignment: alignment == .leading ? .leading : .trailing) {
            Text(label).font(.caption2).foregroundColor(.gray)
            Text(String(format: "%.2f", value)).font(.subheadline).bold()
        }
    }
}
