//
//  WeatherCondition.swift
//  Track
//
//  Weather condition enum used as a feature for delay prediction.
//

import Foundation

enum WeatherCondition: String, Codable, CaseIterable {
    case clear
    case rain
    case snow
}
