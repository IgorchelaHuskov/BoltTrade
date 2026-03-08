//
//  ApiError.swift
//  AutomaticTrading
//
//  Created by Igorchela on 22.12.25.
//

import Foundation

enum ApiError: Error {
    case invalidData
    case jsonParsingFailure
    case requestFailed(description: String)
    case invalidStatusCode(statusCode: Int)
    case unknownError(error: Error)
    
    var customDescription: String {
        switch self {
        case .invalidData: return "Неверные данные"
        case .jsonParsingFailure: return "Не удалось выполнить синтаксический анализ JSON"
        case let .requestFailed(description): return "Запрос не выполнен \(description)"
        case let .invalidStatusCode(statusCode): return "неверный код состояния \(statusCode)"
        case let .unknownError(error): return "Произошла неизвестная ошибка \(error.localizedDescription)"
        }
    }
}



