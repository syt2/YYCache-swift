//
//  DiskCache.swift
//  Cache-Swift
//
//  Created by 沈庾涛 on 2022/9/18.
//

import Foundation
import CommonCrypto

/// DiskCache is a thread-safe cache that stores key-value pairs backed by SQLite and file system (similar to NSURLCache's disk cache).
///
///  DiskCache has these features:
///  - It use LRU (least-recently-used) to remove objects.
///  - It can be controlled by cost, count, and age.
///  - It can be configured to automatically evict objects when there's no free disk space.
///  - It can automatically decide the storage type (sqlite/file) for each object to get better performance.
public class DiskCache {
    /// The path of the cache.
    public let path: URL
    
    /// If the object's data size (in bytes) is larger than this value, then object will be stored as a file, otherwise the object will be stored in sqlite.
    ///
    /// 0 means all objects will be stored as separated files, .max means all objects will be stored in sqlite.
    /// The default value is 20480 (20KB).
    public let inlineThreshold: UInt
    
    /// When an object needs to be saved as a file, this closure will be invoked to generate
    /// a file name for a specified key. If the block is nil, the cache use SHA256(key) as default file name.
    ///
    /// The default value is nil.
    public var customFileNameClosure: ((String) -> String)?
    
    /// The maximum number of objects the cache should hold.
    ///
    /// The default value is .max, which means no limit.
    ///
    /// This is not a strict limit — if the cache goes over the limit, some objects in the cache could be evicted later in background queue.
    public var countLimit: UInt = .max
    
    /// The maximum total cost that the cache can hold before it starts evicting objects.
    ///
    /// The default value is .max, which means no limit.
    ///
    /// This is not a strict limit — if the cache goes over the limit, some objects in the cache could be evicted later in background queue.
    public var costLimit: UInt = .max
    
    /// The maximum expiry time of objects in cache.
    ///
    /// The default value is .infinity, which means no limit.
    ///
    /// This is not a strict limit — if an object goes over the limit, the objects could be evicted later in background queue.
    public var ageLimit: TimeInterval = .infinity
    
    /// The minimum free disk space (in bytes) which the cache should kept.
    ///
    /// The default value is 0, which means no limit.
    ///
    /// If the free disk space is lower than this value, the cache will remove objects to free some disk space.
    /// This is not a strict limit—if the free disk space goes over the limit, the objects could be evicted later in background queue.
    public var freeDiskSpaceLimit: UInt = 0
    
    /// The auto trim check time interval in seconds. Default is 60 (1 minute).
    ///
    /// The cache holds an internal timer to check whether the cache reaches
    /// its limits, and if the limit is reached, it begins to evict objects.
    public var autoTrimInterval: TimeInterval = 60
    
    private var kvStroage: KVStorage?
    private let lock = UnfairLock()
    private let queue = DispatchQueue(label: "yycacheswift.disk", attributes: .concurrent)

    private init(path: URL, inlineThreshold: UInt) {
        self.path = path
        self.inlineThreshold = inlineThreshold
        NotificationCenter.default.addObserver(self, selector: #selector(_appWillBeTerminated), name: willTerminateNotificationName, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: willTerminateNotificationName, object: nil)
    }
    
    /// get cache instance
    /// - Parameters:
    ///   - path: Full path of a directory in which the cache will write data. Once initialized you should not read and write to this directory.
    ///   - inlineThreshold: The data store inline threshold in bytes. If the object's data
    ///     size (in bytes) is larger than this value, then object will be stored as a
    ///     file, otherwise the object will be stored in sqlite. 0 means all objects will
    ///     be stored as separated files, NSUIntegerMax means all objects will be stored
    ///     in sqlite. If you don't know your object's size, 20480 is a good choice.
    /// - Returns: A new cache object, or nil if an error occurs.
    /// - warning: If the cache instance for the specified path already exists in memory,
    ///     this method will return it directly, instead of creating a new instance.
    public static func instance(path: URL, inlineThreshold: UInt = 20 * 1024) -> DiskCache? {
        if let globalCache = DiskCacheGetGlobal(path: path) {
            return globalCache
        }
        let type: KVStorageType
        switch inlineThreshold {
        case 0:
            type = .file
        case .max:
            type = .SQLite
        default:
            type = .mixed
        }
        guard let kv = KVStorage(path: path, type: type) else {
            return nil
        }
        let instance = DiskCache(path: path, inlineThreshold: inlineThreshold)
        instance.kvStroage = kv
        instance._trimRecursively()
        DiskCacheSetGlobal(cache: instance)
        return instance
    }
}

public extension DiskCache {
    
    /// Returns a boolean value that indicates whether a given key is in cache.
    /// This method may blocks the calling thread until file read finished.
    /// - Parameter key: A string identifying the value.
    /// - Returns: Whether the key is in cache.
    func contains(key: String) -> Bool {
        lock.around(kvStroage?.contains(key: key) ?? false)
    }
    
    /// Returns a boolean value with the block that indicates whether a given key is in cache.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - key: A string identifying the value.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func contains(key: String, completion: @escaping (String, Bool) -> Void) {
        queue.async { [weak self] in
            completion(key, self?.contains(key: key) ?? false)
        }
    }
    
    /// Returns the value associated with a given key.
    /// This method may blocks the calling thread until file read finished.
    /// - Parameters:
    ///   - type: The type of the value you specify.
    ///   - key: A string identifying the value.
    /// - Returns: The value associated with key, or nil if no value is associated with key.
    func get<T>(type: T.Type, key: String) -> T? where T: Decodable {
        guard let item = lock.around(kvStroage?.getItem(key: key)), let data = item.value else { return nil }
        let object = try? JSONDecoder().decode(T.self, from: data)
        if let object = object, let extData = item.extendedData {
            Self.setExtendedData(extData, to: object)
        }
        return object
    }
    
    /// Returns the value associated with a given key.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - type: The type of the value you specify.
    ///   - key: A string identifying the value.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func get<T>(type: T.Type, key: String, completion: @escaping (String, T?) -> Void) where T: Decodable {
        queue.async { [weak self] in
            completion(key, self?.get(type: type, key: key))
        }
    }
    
    /// Sets the value of the specified key in the cache.
    /// This method may blocks the calling thread until file write finished.
    /// - Parameters:
    ///   - key: The key with which to associate the value.
    ///   - value: The object to be stored in the cache. If nil, it calls `remove`.
    func set<T>(key: String, value: T?) where T: Encodable {
        guard let newValue = value else {
            remove(key: key)
            return
        }
        guard let value = try? JSONEncoder().encode(newValue) else { return }
        let extData = Self.getExtendedData(object: newValue)
        var filename: String? = nil
        if kvStroage?.type != .SQLite && value.count > inlineThreshold {
            filename = _filename(key: key)
        }
        lock.around {
            kvStroage?.saveItem(key: key, value: value, filename: filename, extendedData: extData)
        }
    }
    
    /// Sets the value of the specified key in the cache.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - key: The key with which to associate the value.
    ///   - value: The object to be stored in the cache. If nil, it calls `remove`.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func set<T>(key: String, value: T?, completion: (() -> Void)?) where T: Encodable {
        queue.async { [weak self] in
            self?.set(key: key, value: value)
            completion?()
        }
    }
    
    /// Removes the value of the specified key in the cache.
    /// This method may blocks the calling thread until file delete finished.
    /// - Parameter key: The key identifying the value to be removed.
    func remove(key: String) {
        lock.around(kvStroage?.removeItem(key: key))
    }
    
    /// Removes the value of the specified key in the cache.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - key: The key identifying the value to be removed.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func remove(key: String, completion: ((String) -> Void)?) {
        queue.async { [weak self] in
            self?.remove(key: key)
            completion?(key)
        }
    }
    
    /// Empties the cache.
    /// This method may blocks the calling thread until file delete finished.
    func removeAll() {
        lock.around(kvStroage?.removeAllItems())
    }

    /// Empties the cache.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameter completion: A closure which will be invoked in background queue when finished.
    func removeAll(completion: (() -> Void)?) {
        queue.async { [weak self] in
            self?.removeAll()
            completion?()
        }
    }
    
    /// Empties the cache with block.
    /// This method returns immediately and executes the clear operation with block in background.
    /// - Parameters:
    ///   - progressCallback: This closure will be invoked during removing, pass nil to ignore.
    ///   - completion: This closure will be invoked at the end, pass nil to ignore.
    func removeAll(progressCallback: ((Int, Int) -> Void)?, completion: ((Bool) -> Void)?) {
        queue.async { [weak self] in
            guard let self = self else {
                completion?(true)
                return
            }
            self.lock.around {
                self.kvStroage?.removeAllItems {
                    progressCallback?(Int($0), Int($1))
                } completion: {
                    completion?($0)
                }
            }
        }
    }
    
    /// The total objects count in this cache.
    /// This method may blocks the calling thread until file read finished.
    var totalCount: Int {
        Int(lock.around(kvStroage?.count) ?? 0)
    }
    
    /// Get the number of objects in this cache.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameter completion: A closure which will be invoked in background queue when finished.
    func totalCount(completion: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            completion(self?.totalCount ?? 0)
        }
    }
    
    /// The total objects cost (in bytes) of objects in this cache.
    /// This method may blocks the calling thread until file read finished.
    var totalCost: Int {
        Int(lock.around(kvStroage?.size) ?? 0)
    }
    
    ///Get the total cost (in bytes) of objects in this cache.
    ///This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameter completion: A closure which will be invoked in background queue when finished.
    func totalCost(completion: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            completion(self?.totalCost ?? 0)
        }
    }
    
    /// Set `true` to enable error logs for debug.
    var errorLogsEnable: Bool {
        get { lock.around(kvStroage?.errorLogsEnabled ?? false) }
        set { lock.around(kvStroage?.errorLogsEnabled = newValue) }
    }
}


// MARK: objc nscoding get/set
public extension DiskCache {
    
    /// Returns the value associated with a given key.
    /// This method may blocks the calling thread until file read finished.
    /// - Parameters:
    ///   - type: The type of the value you specify.
    ///   - key: A string identifying the value.
    /// - Returns: The value associated with key, or nil if no value is associated with key.
    func get<T>(type: T.Type, key: String) -> T? where T: NSObject, T: NSCoding {
        guard let item = lock.around(kvStroage?.getItem(key: key)), let data = item.value else { return nil }
        let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver?.requiresSecureCoding = false
        let object = unarchiver?.decodeObject(of: T.self, forKey: NSKeyedArchiveRootObjectKey)
        if let object = object, let extData = item.extendedData {
            Self.setExtendedData(extData, to: object)
        }
        return object
    }
    
    /// Returns the value associated with a given key.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - type: The type of the value you specify.
    ///   - key: A string identifying the value.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func get<T>(type: T.Type, key: String, completion: @escaping (String, T?) -> Void) where T: NSObject, T: NSCoding {
        queue.async { [weak self] in
            completion(key, self?.get(type: type, key: key))
        }
    }
    
    /// Sets the value of the specified key in the cache.
    /// This method may blocks the calling thread until file write finished.
    /// - Parameters:
    ///   - key: The key with which to associate the value.
    ///   - value: The object to be stored in the cache. If nil, it calls `remove`.
    func set<T>(key: String, value: T?) where T: NSObject, T: NSCoding {
        guard let newValue = value else {
            remove(key: key)
            return
        }
        guard let value = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: false) else { return }
        let extData = Self.getExtendedData(object: newValue)
        var filename: String? = nil
        if kvStroage?.type != .SQLite && value.count > inlineThreshold {
            filename = _filename(key: key)
        }
        lock.around {
            kvStroage?.saveItem(key: key, value: value, filename: filename, extendedData: extData)
        }
    }
    
    /// Sets the value of the specified key in the cache.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - key: The key with which to associate the value.
    ///   - value: The object to be stored in the cache. If nil, it calls `remove`.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func set<T>(key: String, value: T?, completion: (() -> Void)?) where T: NSObject, T: NSCoding {
        queue.async { [weak self] in
            self?.set(key: key, value: value)
            completion?()
        }
    }
}


// MARK: trim
public extension DiskCache {
    
    /// Removes objects from the cache use LRU, until the `totalCount` is below the specified value.
    /// This method may blocks the calling thread until operation finished.
    /// - Parameter count: The total count allowed to remain after the cache has been trimmed.
    func trim(count: UInt) {
        lock.around {
            _trim(count: count)
        }
    }
    
    /// Removes objects from the cache use LRU, until the `totalCount` is below the specified value.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - count: The total count allowed to remain after the cache has been trimmed.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func trim(count: UInt, completion: (() -> Void)?) {
        queue.async { [weak self] in
            self?._trim(count: count)
            completion?()
        }
    }
    
    /// Removes objects from the cache use LRU, until the `totalCost` is below the specified value.
    /// This method may blocks the calling thread until operation finished.
    /// - Parameter cost: The total cost allowed to remain after the cache has been trimmed.
    func trim(cost: UInt) {
        lock.around {
            _trim(cost: cost)
        }
    }
    
    /// Removes objects from the cache use LRU, until the `totalCost` is below the specified value.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - cost: The total cost allowed to remain after the cache has been trimmed.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func trim(cost: UInt, completion: (() -> Void)?) {
        queue.async { [weak self] in
            self?._trim(cost: cost)
            completion?()
        }
    }
    
    /// Removes objects from the cache use LRU, until all expiry objects removed by the specified value.
    /// This method may blocks the calling thread until operation finished.
    /// - Parameter age: The maximum age of the object.
    func trim(age: TimeInterval) {
        lock.around {
            _trim(age: age)
        }
    }
    
    /// Removes objects from the cache use LRU, until all expiry objects removed by the specified value.
    /// This method returns immediately and invoke the passed block in background queue when the operation finished.
    /// - Parameters:
    ///   - age: The maximum age of the object.
    ///   - completion: A closure which will be invoked in background queue when finished.
    func trim(age: TimeInterval, completion: (() -> Void)?) {
        queue.async { [weak self] in
            self?._trim(age: age)
            completion?()
        }
    }
}


// MARK: extened data
public extension DiskCache {
    private struct AssociateKey {
        static var extendedDataKey = "extendedDataKey"
    }
    
    /// Get extended data from an object.
    ///
    /// See `setExtendedData` for more information.
    /// - Parameter object: An object.
    /// - Returns: The extended data.
    static func getExtendedData(object: Any?) -> Data? {
        guard let object = object else { return nil }
        return objc_getAssociatedObject(object, &AssociateKey.extendedDataKey) as? Data
    }
    
    /// Set extended data to an object.
    ///
    /// You can set any extended data to an object before you save the object to disk cache.
    /// The extended data will also be saved with this object. You can get the extended data later with `getExtendedData()`.
    /// - Parameters:
    ///   - data: The extended data (pass nil to remove).
    ///   - object: The object.
    static func setExtendedData(_ data: Data?, to object: Any?) {
        guard let object = object else { return }
        objc_setAssociatedObject(object, &AssociateKey.extendedDataKey, data, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}


// MARK: global instance
private extension DiskCache {
    static let globalInstancesLock = DispatchSemaphore(value: 1)
    static var globalInstances = [String: () -> DiskCache?]()
    
    static func DiskCacheGetGlobal(path: URL) -> DiskCache? {
        return GlobalInstanceSemaAround(globalInstances[path.absoluteString]?())
    }
    
    static func DiskCacheSetGlobal(cache: DiskCache?) {
        guard let path = cache?.path else { return }
        GlobalInstanceSemaAround {
            guard let cache = cache else {
                globalInstances.removeValue(forKey: path.absoluteString)
                return
            }
            globalInstances[path.absoluteString] = { [weak cache] in cache }
        }
    }
    
    static func StringSHA256(string: String) -> String {
        let data = Data(string.utf8)
        let hash = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [UInt8] in
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
            return hash
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func DiskSpaceFree() -> UInt? {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? fileURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let capacity = values?.volumeAvailableCapacity, capacity >= 0 else { return nil }
        return UInt(capacity)
    }
    
    @discardableResult
    static func GlobalInstanceSemaAround<T>(_ closure: @autoclosure () throws -> T) rethrows -> T {
        globalInstancesLock.wait()
        defer { globalInstancesLock.signal() }
        return try closure()
    }
}


// MARK: private
private extension DiskCache {
    func _trimRecursively() {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + autoTrimInterval) { [weak self] in
            guard let self = self else { return }
            self._trimInBackground()
            self._trimRecursively()
        }
    }
    
    func _trimInBackground() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock.around {
                self._trim(cost: self.costLimit)
                self._trim(count: self.countLimit)
                self._trim(age: self.ageLimit)
                self._trim(freeDiskSpace: self.freeDiskSpaceLimit)
            }
        }
    }
    
    func _trim(cost: UInt) {
        guard costLimit < .max else { return }
        kvStroage?.removeItems(toFitSize: Int(cost))
    }
    
    func _trim(count: UInt) {
        guard countLimit < .max else { return }
        kvStroage?.removeItems(toFitCount: Int(count))
    }
    
    func _trim(age: TimeInterval) {
        guard age > 0 else {
            kvStroage?.removeAllItems()
            return
        }
        let timestamp = TimeInterval(time(nil))
        guard timestamp > ageLimit else { return }
        let age = Int32(timestamp - ageLimit)
        guard age < .max else { return }
        kvStroage?.removeItems(earlierThanTime: Int(age))
    }
    
    func _trim(freeDiskSpace: UInt) {
        guard freeDiskSpace != 0 else { return }
        guard let totalBytes = kvStroage?.size, totalBytes > 0 else { return }
        guard let diskFreeBytes = Self.DiskSpaceFree() else { return }
        let needTrimBytes = freeDiskSpace - diskFreeBytes
        guard needTrimBytes > 0 else { return }
        let costLimit = max(0, UInt(totalBytes) - needTrimBytes)
        _trim(cost: costLimit)
    }
    
    func _filename(key: String) -> String? {
        return customFileNameClosure?(key) ?? Self.StringSHA256(string: key)
    }
    
    @objc func _appWillBeTerminated() {
        lock.around {
            kvStroage = nil
        }
    }
}


// MARK: async functions
#if swift(>=5.5)
@available(iOS 13, *)
public extension DiskCache {
    func contains(key: String) async -> Bool {
        await withUnsafeContinuation { continuation in
            contains(key: key) { continuation.resume(returning: $1) }
        }
    }
    
    func get<T>(type: T.Type, key: String) async -> T? where T: Decodable {
        await withUnsafeContinuation { continuation in
            get(type: type, key: key) { continuation.resume(returning: $1) }
        }
        
    }
    
    func set<T>(key: String, value: T?) async where T: Encodable {
        await withUnsafeContinuation { continuation in
            set(key: key, value: value) { continuation.resume() }
        }
    }

    func remove(key: String) async {
        await withUnsafeContinuation { continuation in
            remove(key: key) { _ in continuation.resume() }
        }
    }

    func removeAll() async {
        await withUnsafeContinuation { continuation in
            removeAll { continuation.resume() }
        }
    }
    
    func totalCount() async -> Int  {
        await withUnsafeContinuation { continuation in
            totalCount { continuation.resume(returning: $0) }
        }
    }
    
    func totalCost() async -> Int {
        await withUnsafeContinuation { continuation in
            totalCost { continuation.resume(returning: $0) }
        }
    }
    
    func get<T>(type: T.Type, key: String) async -> T? where T: NSObject, T: NSCoding {
        await withUnsafeContinuation { continuation in
            get(type: type, key: key) { continuation.resume(returning: $1) }
        }
    }
    
    func set<T>(key: String, value: T?) async where T: NSObject, T: NSCoding {
        await withUnsafeContinuation { continuation in
            set(key: key, value: value) { continuation.resume() }
        }
    }
    
    func trim(count: UInt) async {
        await withUnsafeContinuation { continuation in
            trim(count: count) { continuation.resume() }
        }
    }
    
    func trim(cost: UInt) async {
        await withUnsafeContinuation { continuation in
            trim(cost: cost) { continuation.resume() }
        }
    }
    
    func trim(age: TimeInterval) async {
        await withUnsafeContinuation { continuation in
            trim(age: age) { continuation.resume() }
        }
    }
}
#endif



#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

private extension DiskCache {
    var willTerminateNotificationName: Notification.Name {
#if canImport(UIKit)
        return UIApplication.willTerminateNotification
#endif
#if canImport(AppKit)
        return NSApplication.willTerminateNotification
#endif
    }
}
