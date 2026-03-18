//
//  UIUtilities.swift
//  BoltTrade
//
//  Created by Igorchela on 18.03.26.
//

import Foundation
import SwiftUI

enum UIUtilities {
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = Int(seconds) / 60 % 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
    
    static func changeColor(_ percent: Double) -> Color {
        if percent > 100 { return .green }
        else if percent > 80 { return .yellow }
        else if percent > 50 { return .orange }
        else { return .red }
    }
}
