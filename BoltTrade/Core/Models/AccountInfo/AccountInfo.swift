//
//  AccountInfo.swift
//  BoltTrade
//
//  Created by Igorchela on 12.04.26.
//

import Foundation

nonisolated struct AccountInfo {
    var totalBalance: String = "0.00"           // Всего (Wallet Balance)
    var available: String = "0.00"              // Доступно (cw)
    var availableToWithdraw: String = "0.00"    // max для вывода
    var inPosition: String = "0.00"             // В сделках (iw)
    var pnl: String = "0.00"                    // Профит в $ (up)
    var pnlPercentage: String = "0.00"          // Профит в %
}
