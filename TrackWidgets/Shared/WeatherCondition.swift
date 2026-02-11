//
//  WeatherCondition.swift
//  Track
//
//  Weather condition enum used as a feature for delay prediction.
//
//  NOTE: Shared copy — must stay in sync with Track/Models/WeatherCondition.swift

import Foundation

enum WeatherCondition: String, Codable, CaseIterable {
    case clear
    case rain
    case snow
}
