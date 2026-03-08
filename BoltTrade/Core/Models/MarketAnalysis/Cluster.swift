//
//  Cluster.swift
//  Treading
//
//  Created by Igorchela on 12.01.26.
//

import Foundation

struct Cluster {
    let id: Double
    var trackingId: Double = 0      // Для внешнего отслеживания
    let price: Double               // 99900.0 (центр бина)
    let totalVolume: Double         // 6.3 BTC (общий объём кластера)
    let strength: Double            // zScore * pressure * share * trustFactor
    let strengthZScore: Double      // 3.2 (Сила по Z-score, статистическая аномалия)
    let distancePercent: Double     // 0.01% (Расстояние в процентах от текущей цены)
    let side: Side                  // .bid / .ask
    let cumulativeVolume: Double    // Объем всего рынка до этого уровня
    let volumeShare: Double
    let binSize: Double
    let lowerBound: Double
    let upperBound: Double
}

nonisolated enum Side { case bid, ask }

