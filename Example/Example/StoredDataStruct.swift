//
//  StoredDataStruct.swift
//  YYCache-Swift
//
//  Created by syt on 2023/3/2.
//

import Foundation

struct StoreCodable: Codable {
    var date: Date? = Date()
}

extension StoreCodable: CustomStringConvertible {
    var description: String {
        "Create @ \(date?.description ?? "unknown")"
    }
}

class StoreCoding: NSObject, NSCoding {
    func encode(with coder: NSCoder) {
        coder.encode(date, forKey: "date")
    }
    
    required init?(coder: NSCoder) {
        date = coder.decodeObject(of: NSDate.self, forKey: "date") as? Date
    }
    
    var date: Date? = Date()
    
    override init() {
        super.init()
    }
}

extension StoreCoding {
    override var description: String {
        "Create @ \(date?.description ?? "unknown")"
    }
}
