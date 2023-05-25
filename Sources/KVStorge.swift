//
//  KVStorge.swift
//  Cache-Swift
//
//  Created by 沈庾涛 on 2022/9/17.
//

import Foundation
import SQLite3
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

///  KVStorageItem is used by `KVStorage` to store key-value pair and meta data.
struct KVStorgeItem {
    fileprivate(set) var key: String
    fileprivate(set) var value: Data?
    fileprivate(set) var filename: String?
    fileprivate(set) var size: Int = 0
    fileprivate(set) var modTime: Int = 0
    fileprivate(set) var accessTime: Int = 0
    fileprivate(set) var extendedData: Data?
}

/// Storage type, indicated where the `KVStorageItem.value` stored.
///
/// Typically, write data to sqlite is faster than extern file, but reading performance is dependent on data size.
/// In my(origin authors) test (on iPhone 6 64G), read data from extern file is faster than from sqlite when the data is larger than 20KB.
/// - If you want to store large number of small datas (such as contacts cache),
/// use KVStorageTypeSQLite to get better performance.
/// - If you want to store large files (such as image cache),
/// use KVStorageTypeFile to get better performance.
/// - You can use KVStorageTypeMixed and choice your storage type for each item.
/// See <http://www.sqlite.org/intern-v-extern-blob.html> for more information.
enum KVStorageType: Int {
    /// The `value` is stored as a file in file system.
    case file = 0
    /// The `value` is stored in sqlite with blob type.
    case SQLite = 1
    /// The `value` is stored in file system or sqlite based on your choice.
    case mixed = 2
}


/// KVStorage is a key-value storage based on sqlite and file system.
/// Typically, you should not use this class directly.
///
/// The designated initializer for KVStorage is `initWithPath:type:`.
/// After initialized, a directory is created based on the `path` to hold key-value data.
/// Once initialized you should not read or write this directory without the instance.
///
/// The instance of this class is *NOT* thread safe, you need to make sure
/// that there's only one thread to access the instance at the same time. If you really
/// need to process large amounts of data in multi-thread, you should split the data
/// to multiple KVStorage instance (sharding).
class KVStorage {
    
    /// The path of this storage.
    let path: URL
    
    /// The type of this storage.
    let type: KVStorageType
    
    /// Set `YES` to enable error logs for debug.
    var errorLogsEnabled: Bool
    
    private let trashQueue: DispatchQueue
    private let dbPath: String
    private let dataPath: URL
    private let trashPath: URL
    
    private var db: OpaquePointer?
    private var dbStmtCache: [String: OpaquePointer]?
    private lazy var dbLastOpenErrorTime: TimeInterval = 0
    private lazy var dbOpenErrorCount: UInt = 0
    
    // MARK: without this statement in sqlite3_bind_text, i cannot read text???
    // https://stackoverflow.com/questions/48859139/sqlite-swift-binding-and-retrieving/48870619#48870619
    private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
    
    
    init?(path: URL, type: KVStorageType) {
        self.path = path
        self.type = type
        dataPath = path.appendingPathComponent(KVConstParams.kDataDirectoryName)
        trashPath = path.appendingPathComponent(KVConstParams.kTrashDirectoryName)
        dbPath = path.appendingPathComponent(KVConstParams.kDBFileName).path
        trashQueue = DispatchQueue.init(label: "com.ibireme.cache.disk.trash")
        errorLogsEnabled = true
        do {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dataPath, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trashPath, withIntermediateDirectories: true)
        } catch {
            debugPrint("KVStorage init error: \(error.localizedDescription))")
            return nil
        }
        if !dbOpen() || !dbInitialize() {
            dbClose()
            reset()
            guard dbOpen(), dbInitialize() else {
                dbClose()
                debugPrint("KVStorage init error: fail to open sqlite db.")
                return nil
            }
        }
        fileEmptyTrashInBackground()
    }
    
    convenience init?(path: String, type: KVStorageType) {
        guard path.count > 0, path.count <= KVConstParams.kPathLengthMax else {
            debugPrint("KVStorage init error: invalid path: ", path)
            return nil
        }
        self.init(path: URL(fileURLWithPath: path), type: type)
    }
    
    deinit {
#if canImport(UIKit)
        let taskId = Self.SharedApplication?.beginBackgroundTask(expirationHandler: nil)
        dbClose()
        if let taskId = taskId, taskId != .invalid {
            Self.SharedApplication?.endBackgroundTask(taskId)
        }
#else
        dbClose()
#endif
    }
    
    func saveItem(_ item: KVStorgeItem) -> Bool {
        guard let value = item.value else { return false }
        return saveItem(key: item.key, value: value, filename: item.filename, extendedData: item.extendedData)
    }
    
    func saveItem(key: String, value: Data) -> Bool {
        saveItem(key: key, value: value, filename: nil, extendedData: nil)
    }
    
    func saveItem(key: String, value: Data, filename: String?, extendedData: Data?) -> Bool {
        guard !key.isEmpty, !value.isEmpty else { return false }
        if type == .file && filename?.isEmpty != false { return false }
        if filename?.isEmpty == false {
            if !fileWrite(filename: filename!, data: value) { return false }
            if !dbSave(key: key, value: value, filename: filename, extendedData: extendedData) {
                fileDelete(filename: filename!)
                return false
            }
            return true
        }
        if type != .SQLite {
            if let filename = dbGetFilename(key: key) {
                fileDelete(filename: filename)
            }
        }
        return dbSave(key: key, value: value, filename: nil, extendedData: extendedData)
    }
    
    @discardableResult
    func removeItem(key: String) -> Bool {
        guard !key.isEmpty else { return false }
        if type != .SQLite {
            if let filename = dbGetFilename(key: key) {
                fileDelete(filename: filename)
            }
        }
        return dbDeleteItem(key: key)
    }
    
    @discardableResult
    func removeItems(keys: [String]) -> Bool {
        guard keys.isEmpty == false else { return false }
        if type != .SQLite {
            dbGetFilenames(keys: keys)?.forEach { fileDelete(filename: $0) }
        }
        return dbDeleteItems(keys: keys)
    }
    
    @discardableResult
    func removeItems(largeThanSize size: Int) -> Bool {
        guard size < .max else { return true }
        guard size > 0 else { return removeAllItems() }
        if type != .SQLite {
            dbGetFilenames(sizeLargerThan: size)?.forEach { fileDelete(filename: $0) }
        }
        if dbDeleteItems(sizeLargerThan: size) {
            dbCheckpoint()
            return true
        }
        return false
    }
    
    @discardableResult
    func removeItems(earlierThanTime time: Int) -> Bool {
        guard time > 0 else { return true }
        guard time < .max else { return removeAllItems() }
        if type != .SQLite {
            dbGetFilenames(timeEarlierThan: time)?.forEach { fileDelete(filename: $0) }
        }
        if dbDeleteItems(timeEarlierThan: time) {
            dbCheckpoint()
            return true
        }
        return false
    }
    
    @discardableResult
    func removeItems(toFitSize size: Int) -> Bool {
        guard size < .max else { return true }
        guard size > 0 else { return removeAllItems() }
        var total = dbGetTotalItemSize()
        guard total > size else { return total >= 0 }
        
        var items: [KVStorgeItem]?
        var success = false
        let perCount = 16
        repeat {
            items = dbGetItemSizeInfoOrderByTimeAsc(limit: perCount)
            guard let items else { continue }
            for item in items {
                guard total > size else { break }
                if let filename = item.filename {
                    fileDelete(filename: filename)
                }
                success = dbDeleteItem(key: item.key)
                total -= item.size
                if !success { break }
            }
        } while total > size && items?.isEmpty == false && success
        if success { dbCheckpoint() }
        return success
    }
    
    @discardableResult
    func removeItems(toFitCount count: Int) -> Bool {
        guard count < .max else { return true }
        guard count > 0 else { return removeAllItems() }
        var total = dbGetTotalItemCount()
        guard total > count else { return total >= 0 }
        var items: [KVStorgeItem]?
        var success = false
        let perCount = 16
        repeat {
            items = dbGetItemSizeInfoOrderByTimeAsc(limit: perCount)
            guard let items else { continue }
            for item in items {
                guard total > count else { break }
                if let filename = item.filename {
                    fileDelete(filename: filename)
                }
                success = dbDeleteItem(key: item.key)
                total -= 1
                if !success { break }
            }
        } while total > count && items?.isEmpty == false && success
        if success { dbCheckpoint() }
        return success
    }
    
    @discardableResult
    func removeAllItems() -> Bool {
        guard dbClose() else { return false }
        reset()
        return dbOpen() && dbInitialize()
    }
    
    func removeAllItems(progressClosure: ((_ removedCount: Int, _ totalCount: Int) -> Void)?, completion: ((_ success: Bool) -> Void)?) {
        let total = dbGetTotalItemCount()
        guard total > 0 else {
            completion?(total < 0)
            return
        }
        var left = total
        let perCount = 32
        var items: [KVStorgeItem]?
        var success = false
        repeat {
            items = dbGetItemSizeInfoOrderByTimeAsc(limit: perCount)
            items?.forEach { item in
                guard left > 0, success else { return }
                if let filename = item.filename {
                    fileDelete(filename: filename)
                }
                success = dbDeleteItem(key: item.key)
                left -= 1
            }
            progressClosure?(total - left, total)
        } while left > 0 && items?.isEmpty == false && success
        if success { dbCheckpoint() }
        completion?(success)
    }
    
    func getItem(key: String) -> KVStorgeItem? {
        guard !key.isEmpty,
              let item = dbGetItem(key: key, excludeInlineData: false) else { return nil }
        dbUpdateAccessTime(key: key)
        if let filename = item.filename,
           fileRead(filename: filename) == nil {
            dbDeleteItem(key: key)
            return nil
        }
        return item
    }
    
    func getItemInfo(key: String) -> KVStorgeItem? {
        guard !key.isEmpty else { return nil }
        return dbGetItem(key: key, excludeInlineData: true)
    }
    
    func getItemValue(key: String) -> Data? {
        guard !key.isEmpty else { return nil }
        var value: Data? = nil
        switch type {
            case .file:
                if let filename = dbGetFilename(key: key) {
                    value = fileRead(filename: filename)
                    if value == nil {
                        dbDeleteItem(key: key)
                    }
                }
            case .SQLite:
                value = dbGetValue(key: key)
            case .mixed:
                if let filename = dbGetFilename(key: key) {
                    value = fileRead(filename: filename)
                    if value == nil {
                        dbDeleteItem(key: key)
                    }
                } else {
                    value = dbGetValue(key: key)
                }
        }
        if value != nil {
            dbUpdateAccessTime(key: key)
        }
        return value
    }
    
    func getItems(keys: [String]) -> [KVStorgeItem]? {
        guard !keys.isEmpty else { return nil }
        var items = dbGetItems(keys: keys, excludeInlineData: false)
        if type != .SQLite {
            items = items?.filter { item in
                guard let filename = item.filename else { return true }
                guard fileRead(filename: filename) != nil else { return true }
                dbDeleteItem(key: item.key)
                return false
            }
        }
        if items?.isEmpty == false {
            dbUpdateAccessTimes(keys: keys)
            return items
        }
        return nil
    }
    
    func getItemInfos(keys: [String]) -> [KVStorgeItem]? {
        guard !keys.isEmpty else { return nil }
        return dbGetItems(keys: keys, excludeInlineData: true)
    }
    
    func getItemValues(keys: [String]) -> [String: Data]? {
        let items = getItems(keys: keys)
        var kvResult = [String: Data]()
        items?.forEach { item in
            guard let value = item.value else { return }
            kvResult.updateValue(value, forKey: item.key)
        }
        return kvResult.isEmpty ? nil : kvResult
    }
    
    func contains(key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return dbGetItemCount(key: key) > 0
    }
    
    var count: Int {
        dbGetTotalItemCount()
    }
    
    var size: Int {
        dbGetTotalItemSize()
    }
}


// MARK: db
private extension KVStorage {
    @discardableResult
    func dbOpen() -> Bool {
        guard db == nil else { return true }
        let result = sqlite3_open(dbPath, &db)
        guard result == SQLITE_OK else {
            db = nil
            dbStmtCache = nil
            dbLastOpenErrorTime = CACurrentMediaTime()
            dbOpenErrorCount += 1
            log("sqlite open failed (\(result)).")
            return false
        }
        dbStmtCache = [:]
        dbLastOpenErrorTime = 0
        dbOpenErrorCount = 0
        return true
    }
    
    @discardableResult
    func dbClose() -> Bool {
        guard db != nil else { return true }
        var retry = false
        var stmtFinalized = false
        dbStmtCache = nil
        repeat {
            retry = false
            let result = sqlite3_close(db)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                guard !stmtFinalized else { break }
                stmtFinalized = true
                while let stmt = sqlite3_next_stmt(db, nil) {
                    sqlite3_finalize(stmt)
                    retry = true
                }
            } else if result != SQLITE_OK {
                log("sqlite close failed (\(result)).")
            }
        } while retry
        db = nil
        return true
    }
    
    @discardableResult
    func dbCheck() -> Bool {
        guard db == nil else { return true }
        guard dbOpenErrorCount < KVConstParams.kMaxErrorRetryCount,
              CACurrentMediaTime() - dbLastOpenErrorTime > KVConstParams.kMinRetryTimeInterval else {
            return false
        }
        return dbOpen() && dbInitialize()
    }
    
    @discardableResult
    func dbInitialize() -> Bool {
        let sql = "pragma journal_mode = wal; pragma synchronous = normal; create table if not exists manifest (key text, filename text, size integer, inline_data blob, modification_time integer, last_access_time integer, extended_data blob, primary key(key)); create index if not exists last_access_time_idx on manifest(last_access_time);"
        return dbExecute(sql: sql)
    }
    
    func dbCheckpoint() {
        guard dbCheck() else { return }
        sqlite3_wal_checkpoint(db, nil)
    }
    
    @discardableResult
    func dbExecute(sql: String) -> Bool {
        guard !sql.isEmpty, dbCheck() else {
            return false
        }
        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        if (error != nil) {
            log("sqlite exec error (\(result)): \(String(describing: error))")
            sqlite3_free(error)
        }
        return result == SQLITE_OK
    }
    
    func dbPrepareStmt(sql: String) -> OpaquePointer? {
        guard dbCheck(), !sql.isEmpty, dbStmtCache != nil else { return nil }
        var stmt = dbStmtCache?[sql]
        guard stmt == nil else {
            sqlite3_reset(stmt)
            return stmt
        }
        let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if result != SQLITE_OK {
            log("sqlite stmt prepare error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
            return nil
        }
        dbStmtCache?[sql] = stmt
        return stmt
    }
    
    func dbJoin(keys: [Any]) -> String {
        guard keys.count > 0 else { return "" }
        return String(repeating: "?,", count: keys.count - 1).appending("?")
    }
    
    func dbBindJoin(keys: [String], stmt: OpaquePointer?, fromIndex: Int) {
        keys.enumerated().forEach {
            sqlite3_bind_text(stmt, Int32($0.offset + fromIndex), $0.element, -1, SQLITE_TRANSIENT)
        }
    }
    
    func dbBindBlob<T>(stmt: OpaquePointer!, bindIndex: Int32, data: Data?, completion: () throws -> T) rethrows -> T {
        guard let data = data else {
            sqlite3_bind_blob(stmt, bindIndex, nil, 0, nil)
            return try completion()
        }
        return try data.withUnsafeBytes {
            sqlite3_bind_blob(stmt, bindIndex, $0.baseAddress, Int32(data.count), nil)
            return try completion()
        }
    }
    
    @discardableResult
    func dbSave(key: String, value: Data, filename: String?, extendedData: Data?) -> Bool {
        let sql = "insert or replace into manifest (key, filename, size, inline_data, modification_time, last_access_time, extended_data) values (?1, ?2, ?3, ?4, ?5, ?6, ?7);"
        guard let stmt = dbPrepareStmt(sql: sql) else { return false }
        let timestamp = Int32(time(nil))
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, filename, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(value.count))
        sqlite3_bind_int(stmt, 5, timestamp)
        sqlite3_bind_int(stmt, 6, timestamp)
        let result = dbBindBlob(stmt: stmt, bindIndex: 4,
                              data: filename?.isEmpty == false ? nil : value) {
            dbBindBlob(stmt: stmt, bindIndex: 7, data: extendedData) { sqlite3_step(stmt) }
        }
        if result != SQLITE_DONE {
            log("sqlite insert error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }
    
    @discardableResult
    func dbUpdateAccessTime(key: String) -> Bool {
        let sql = "update manifest set last_access_time = ?1 where key = ?2;";
        guard let stmt = dbPrepareStmt(sql: sql) else { return false }
        sqlite3_bind_int(stmt, 1, Int32(time(nil)))
        sqlite3_bind_text(stmt, 2, key, -1, SQLITE_TRANSIENT)
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            log("sqlite update error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }
    
    @discardableResult
    func dbUpdateAccessTimes(keys: [String]) -> Bool {
        guard dbCheck() else { return false }
        let t = Int32(time(nil))
        let sql = "update manifest set last_access_time = \(t) where key in (\(dbJoin(keys: keys)));"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if prepareResult != SQLITE_OK {
            log("sqlite stmt prepare error (\(prepareResult)): \(String(describing: sqlite3_errmsg(db)))")
            return false
        }
        
        dbBindJoin(keys: keys, stmt: stmt, fromIndex: 1)
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if result != SQLITE_DONE {
            log("sqlite update error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }
    
    @discardableResult
    func dbDeleteItem(key: String) -> Bool {
        let sql = "delete from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql: sql) else { return false }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            log("sqlite delete error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }
    
    func dbDeleteItems(keys: [String]) -> Bool {
        guard dbCheck() else { return false }
        let sql = "delete from manifest where key in (\(dbJoin(keys: keys)));"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if prepareResult != SQLITE_OK {
            log("sqlite stmt prepare error (\(prepareResult)): \(String(describing: sqlite3_errmsg(db)))")
            return false
        }
        dbBindJoin(keys: keys, stmt: stmt, fromIndex: 1)
        let result = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if result == SQLITE_ERROR {
            log("sqlite delete error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }
    
    func dbDeleteItems(sizeLargerThan size: Int) -> Bool {
        let sql = "delete from manifest where size > ?1;"
        guard let stmt = dbPrepareStmt(sql: sql) else { return false }
        sqlite3_bind_int(stmt, 1, Int32(size))
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            log("sqlite delete error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }
    
    func dbDeleteItems(timeEarlierThan time: Int) -> Bool {
        let sql = "delete from manifest where last_access_time < ?1;"
        guard let stmt = dbPrepareStmt(sql: sql) else {
            return false
        }
        sqlite3_bind_int(stmt, 1, Int32(time))
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            log("sqlite delete error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }
    
    

    func dbGetItem(stmt: OpaquePointer!, excludeInlineData: Bool) -> KVStorgeItem? {
        
        guard let keyPointer = sqlite3_column_text(stmt, 0), keyPointer.pointee != 0 else { return nil }
        var item = KVStorgeItem(key: String(cString: keyPointer))
        if let filenamePointer = sqlite3_column_text(stmt, 1) {
            item.filename = String(cString: filenamePointer)
        }
        item.size = Int(sqlite3_column_int(stmt, 2))
        if !excludeInlineData,
           let inlineDataPointer = sqlite3_column_blob(stmt, 3) {
            let inlineDataBytes = sqlite3_column_bytes(stmt, 3)
            if inlineDataBytes > 0 {
                item.value = Data(bytes: inlineDataPointer, count: Int(inlineDataBytes))
            }
        }
        item.modTime = Int(sqlite3_column_int(stmt, 4))
        item.accessTime = Int(sqlite3_column_int(stmt, 5))
        if let extenedDataPointer = sqlite3_column_blob(stmt, 6) {
            let extenedDataBytes = sqlite3_column_bytes(stmt, 6)
            if extenedDataBytes > 0 {
                item.extendedData = Data(bytes: extenedDataPointer, count: Int(extenedDataBytes))
            }
        }
        return item
    }
    
    func dbGetItem(key: String, excludeInlineData: Bool) -> KVStorgeItem? {
        let sql = excludeInlineData ? "select key, filename, size, modification_time, last_access_time, extended_data from manifest where key = ?1;" : "select key, filename, size, inline_data, modification_time, last_access_time, extended_data from manifest where key = ?1;";
        guard let stmt = dbPrepareStmt(sql: sql) else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT);
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW {
            return dbGetItem(stmt: stmt, excludeInlineData: excludeInlineData)
        }
        if result != SQLITE_DONE {
            log("sqlite query error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
        }
        return nil
    }
    
    func dbGetItems(keys: [String], excludeInlineData: Bool) -> [KVStorgeItem]? {
        guard dbCheck() else { return nil }
        let sql = excludeInlineData
            ? "select key, filename, size, modification_time, last_access_time, extended_data from manifest where key in (\(dbJoin(keys: keys)));"
            : "select key, filename, size, inline_data, modification_time, last_access_time, extended_data from manifest where key in (\(dbJoin(keys: keys)))"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if prepareResult != SQLITE_OK {
            log("sqlite stmt prepare error (\(prepareResult)): \(String(describing: sqlite3_errmsg(db)))")
            return nil
        }
        dbBindJoin(keys: keys, stmt: stmt, fromIndex: 1)
        var items: [KVStorgeItem]? = []
        repeat {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                if let item = dbGetItem(stmt: stmt, excludeInlineData: excludeInlineData) {
                    items?.append(item)
                }
            } else if result == SQLITE_DONE {
                break
            } else {
                log("sqlite query error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
                items = nil
                break
            }
        } while true
        sqlite3_finalize(stmt)
        return items
    }

    func dbGetValue(key: String) -> Data? {
        let sql = "select inline_data from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql: sql) else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW {
            let inlineDataPointer  = sqlite3_column_blob(stmt, 0)
            let inlineDataBytes = sqlite3_column_bytes(stmt, 0)
            if let inlineDataPointer = inlineDataPointer, inlineDataBytes > 0 {
                return Data(bytes: inlineDataPointer, count: Int(inlineDataBytes))
            }
        }
        if result != SQLITE_DONE {
            log("sqlite query error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
        }
        return nil
        
    }
    
    func dbGetFilename(key: String) -> String? {
        let sql = "select filename from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql: sql) else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW {
            if let filename = sqlite3_column_text(stmt, 0), filename.pointee != 0 {
                return String(cString: filename)
            }
        } else if result != SQLITE_DONE {
            log("sqlite query error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
        }
        return nil
    }
    
    func dbGetFilenames(keys: [String]) -> [String]? {
        guard dbCheck() else { return nil }
        let sql = "select filename from manifest where key in (\(dbJoin(keys: keys)));"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if prepareResult != SQLITE_OK {
            log("sqlite stmt prepare error (\(prepareResult)): \(String(describing: sqlite3_errmsg(db)))")
            return nil
        }
        dbBindJoin(keys: keys, stmt: stmt, fromIndex: 1)
        var filenames: [String]? = []
        repeat {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                if let filename = sqlite3_column_text(stmt, 0), filename.pointee != 0 {
                    filenames?.append(String(cString: filename))
                }
            } else if result == SQLITE_DONE {
                break
            } else {
                log("sqlite query error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
                filenames = nil
                break
            }
        } while true
        sqlite3_finalize(stmt)
        return filenames
    }
    
    func dbGetFilenames(sizeLargerThan size: Int) -> [String]? {
        let sql = "select filename from manifest where size > ?1 and filename is not null;"
        guard let stmt = dbPrepareStmt(sql: sql) else { return nil }
        sqlite3_bind_int(stmt, 1, Int32(size))
        var filenames: [String]? = []
        repeat {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                if let filename = sqlite3_column_text(stmt, 0), filename.pointee != 0 {
                    filenames?.append(String(cString: filename))
                }
            } else if result == SQLITE_DONE {
                break
            } else {
                log("sqlite query error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
                filenames = nil
                break
            }
        } while true
        return filenames
    }
    
    func dbGetFilenames(timeEarlierThan time: Int) -> [String]? {
        let sql = "select filename from manifest where last_access_time < ?1 and filename is not null;"
        guard let stmt = dbPrepareStmt(sql: sql) else { return nil }
        sqlite3_bind_int(stmt, 1, Int32(time))
        var filenames: [String]? = []
        repeat {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                if let filename = sqlite3_column_text(stmt, 0), filename.pointee != 0 {
                    filenames?.append(String(cString: filename))
                }
            } else if result == SQLITE_DONE {
                break
            } else {
                log("sqlite query error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
                filenames = nil
                break
            }
        } while true
        return filenames
    }
    
    func dbGetItemSizeInfoOrderByTimeAsc(limit: Int) -> [KVStorgeItem]? {
        let sql = "select key, filename, size from manifest order by last_access_time asc limit ?1;"
        guard let stmt = dbPrepareStmt(sql: sql) else { return nil }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        
        var items: [KVStorgeItem]? = []
        repeat {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                guard let keyPointer = sqlite3_column_text(stmt, 0), keyPointer.pointee != 0 else { continue }
                var item = KVStorgeItem(key: String(cString: keyPointer))
                if let filenamePointer = sqlite3_column_text(stmt, 1) {
                    item.filename = String(cString: filenamePointer)
                }
                item.size = Int(sqlite3_column_int(stmt, 2))
                items?.append(item)
            } else if result == SQLITE_DONE {
                break
            } else {
                log("sqlite query error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
                items = nil
                break
            }
        } while true
        return items
    }
    
    func dbGetItemCount(key: String) -> Int {
        let sql = "select count(key) from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql: sql) else { return -1 }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        let result = sqlite3_step(stmt)
        if result != SQLITE_ROW {
            log("sqlite query error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
            return -1
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
    
    func dbGetTotalItemSize() -> Int {
        let sql = "select sum(size) from manifest;"
        guard let stmt = dbPrepareStmt(sql: sql) else { return -1 }
        let result = sqlite3_step(stmt)
        if result != SQLITE_ROW {
            log("sqlite query error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
            return -1
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
    
    func dbGetTotalItemCount() -> Int {
        let sql = "select count(*) from manifest;"
        guard let stmt = dbPrepareStmt(sql: sql) else { return -1 }
        let result = sqlite3_step(stmt)
        if result != SQLITE_ROW {
            log("sqlite query error (\(result)): \(String(describing: sqlite3_errmsg(db)))")
            return -1
        }
        return Int(sqlite3_column_int(stmt, 0))
    }
}

// MARK: file
private extension KVStorage {
    @discardableResult
    func fileWrite(filename: String, data: Data) -> Bool {
        do {
            try data.write(to: dataPath.appendingPathComponent(filename))
        } catch {
            return false
        }
        return true
    }
    
    func fileRead(filename: String) -> Data? {
        try? Data(contentsOf: dataPath.appendingPathComponent(filename))
    }
    
    @discardableResult
    func fileDelete(filename: String) -> Bool {
        do {
            try FileManager.default.removeItem(at: dataPath.appendingPathComponent(filename))
        } catch {
            return false
        }
        return true
    }
    
    @discardableResult
    func fileMoveAllToTrash() -> Bool {
        let tmpPath = trashPath.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: dataPath, to: tmpPath)
            try FileManager.default.createDirectory(at: dataPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return false
        }
        return true
    }
    
    func fileEmptyTrashInBackground() {
        trashQueue.async { [trashPath] in
            let manager = FileManager()
            let directoryContents = try? manager.contentsOfDirectory(at: trashPath, includingPropertiesForKeys: nil)
            directoryContents?.forEach {
                try? manager.removeItem(at: $0)
            }
        }
    }
}

// MARK: private
private extension KVStorage {
    struct KVConstParams {
        static let kMaxErrorRetryCount: UInt = 8
        static let kMinRetryTimeInterval: TimeInterval = 2.0
        static let kPathLengthMax = Int(PATH_MAX - 64)
        static let kDBFileName = "manifest.sqlite"
        static let kDBShmFileName = "manifest.sqlite-shm"
        static let kDBWalFileName = "manifest.sqlite-wal"
        static let kDataDirectoryName = "data"
        static let kTrashDirectoryName = "trash"
    }
    
    func log<T>(_ message: T, filePath: String = #file, line: Int = #line, methodName: String = #function) {
        guard errorLogsEnabled else { return }
        let fileName = (filePath as NSString).lastPathComponent
        let printMsg = "[\(fileName)] [Line\(line)] [\(methodName)]: \(message)"
        debugPrint(printMsg)
    }
    
    func reset() {
        try? FileManager.default.removeItem(at: path.appendingPathComponent(KVConstParams.kDBFileName))
        try? FileManager.default.removeItem(at: path.appendingPathComponent(KVConstParams.kDBShmFileName))
        try? FileManager.default.removeItem(at: path.appendingPathComponent(KVConstParams.kDBWalFileName))
        fileMoveAllToTrash()
        fileEmptyTrashInBackground()
    }
}


#if canImport(UIKit)
private extension KVStorage {
    static var SharedApplication: UIApplication? {
        let isAppExtension = Bundle.main.bundlePath.hasSuffix(".appex")
        return isAppExtension ? nil : UIApplication.shared
    }
}
#endif
