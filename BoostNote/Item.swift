//
//  Item.swift
//  BoostNote
//
//  Created by Marco Zamboni on 10/08/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
