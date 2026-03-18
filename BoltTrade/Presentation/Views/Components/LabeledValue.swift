//
//  LabeledValue.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import SwiftUI

struct LabeledValue: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label + ":").font(.caption2).foregroundColor(.gray)
            Text(value).font(.caption).foregroundColor(.white)
        }
    }
}
