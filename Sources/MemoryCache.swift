//
//  MemoryCache.swift
//  Cache-Swift
//
//  Created by 沈庾涛 on 2022/9/18.
//

import Foundation
import QuartzCore
import UIKit


///  MemoryCache is a fast in-memory cache that stores key-value pairs.
///
/// - It uses LRU (least-recently-used) to remove objects;
/// - It can be controlled by cost, count and age;
/// - It can be configured to automatically evict objects when receive memory warning or app enter background.
/// The time of `Access Methods` in MemoryCache is typically in constant time (O(1)).
public class MemoryCache {
    
    /// The name of the cache. Default is nil.
    public var name: String?
    
    /// The maximum number of objects the cache should hold.
    ///
    /// The default value is .max, which means no limit.
    /// This is not a strict limit—if the cache goes over the limit,
    /// some objects in the cache could be evicted later in backgound thread.
    public var countLimit: UInt = .max
    
    /// The maximum total cost that the cache can hold before it starts evicting objects.
    ///
    /// The default value is .max, which means no limit.
    /// This is not a strict limit—if the cache goes over the limit,
    /// some objects in the cache could be evicted later in backgound thread.
    public var costLimit: UInt = .max
    
    /// The maximum expiry time of objects in cache.
    ///
    /// The default value is .infinity, which means no limit.
    /// This is not a strict limit—if an object goes over the limit,
    /// the object could be evicted later in backgound thread.
    public var ageLimit: TimeInterval = .infinity
    
    /// The auto trim check time interval in seconds. Default is 5.0.
    ///
    /// The cache holds an internal timer to check whether the cache reaches its limits,
    /// and if the limit is reached, it begins to evict objects.
    public var autoTrimInterval: TimeInterval = 5
    
    /// If `true`, the cache will remove all objects when the app receives a memory warning.
    /// The default value is `true`.
    public var shouldRemoveAllObjectsOnMemoryWarning: Bool = true
    
    /// If `true`, The cache will remove all objects when the app enter background.
    /// The default value is `true`.
    public var shouldRemoveAllObjectsWhenEnteringBackground: Bool = true
    
    /// A closure to be executed when the app receives a memory warning.
    /// The default value is nil.
    public var didReceiveMemoryWarningClosure: ((MemoryCache) -> Void)?
    
    /// A closure to be executed when the app enter background.
    /// The default value is nil.
    public var didEnterBackgroundClosure: ((MemoryCache) -> Void)?
    
    private let lock = UnfairLock()
    private let lru = LinkMap()
    private let queue = DispatchQueue(label: "yycacheswift.memory")

    public init() {
        NotificationCenter.default.addObserver(self, selector: #selector(_appDidReceiveMemoryWarningNotification), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(_appDidEnterBackgroundNotification), name: UIApplication.didEnterBackgroundNotification, object: nil)
        _trimRecursively()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
}

// MARK: public
public extension MemoryCache {
    ///  The number of objects in the cache.
    var count: UInt {
        lock.around(lru.totalCount)
    }
    
    /// The total cost of objects in the cache.
    var cost: UInt {
        lock.around(lru.totalCost)
    }
    
    /// Returns a Boolean value that indicates whether a given key is in cache.
    /// - Parameter key: An object identifying the value.
    /// - Returns: Whether the key is in cache.
    func contains(key: AnyHashable) -> Bool {
        lock.around(lru.dict.index(forKey: key) != nil)
    }

    subscript(key: AnyHashable) -> Any? {
        set { update(value: newValue, forKey: key) }
        get { get(key: key) }
    }
    
    /// Returns the value associated with a given key.
    /// - Parameter key: An object identifying the value
    /// - Returns: The value associated with key, or nil if no value is associated with key.
    func get(key: AnyHashable) -> Any? {
        lock.around {
            guard let node = lru.dict[key] else { return nil }
            node.time = CACurrentMediaTime()
            lru.bringToHead(node: node)
            return node.value
        }
    }
    
    /// Sets the value of the specified key in the cache (0 cost).
    /// - Parameters:
    ///   - value: The object to be stored in the cache. If nil, it calls `remove(forKey:)`.
    ///   - key: The key with which to associate the value
    ///   - cost:  The cost with which to associate the key-value pair.
    func update(value: Any?, forKey key: AnyHashable, cost: UInt = 0) {
        guard let value = value else {
            remove(forKey: key)
            return
        }
        lock.around {
            let now = CACurrentMediaTime()
            if let node = lru.dict[key] {
                lru.totalCost -= node.cost
                lru.totalCost += cost
                node.cost = cost
                node.time = now
                node.value = value
                lru.bringToHead(node: node)
            } else {
                let node = LinkedMapNode(key: key, value: value, cost: cost, time: now)
                lru.insertAtHead(node: node)
            }
            if lru.totalCost > costLimit {
                queue.async { self._trim(cost: self.costLimit) }
            }
            if lru.totalCount > countLimit {
                guard let node = lru.removeTail() else { return }
                if lru.releaseAsynchronously {
                    (lru.releaseOnMainThread ? DispatchQueue.main : .global())
                        .async { _ = node }
                } else if lru.releaseOnMainThread && pthread_main_np() != 0 {
                    DispatchQueue.main.async { _ = node }
                }
            }
        }
    }
    
    /// Removes the value of the specified key in the cache.
    /// - Parameter key: The key identifying the value to be removed.
    func remove(forKey key: AnyHashable) {
        lock.around {
            guard let node = lru.dict[key] else { return }
            lru.remove(node: node)
            
            if lru.releaseAsynchronously {
                let queue = lru.releaseOnMainThread ? DispatchQueue.main : .global()
                queue.async {
                    _ = node
                }
            } else if lru.releaseOnMainThread && pthread_main_np() != 0 {
                DispatchQueue.main.async { _ = node }
            }
        }
    }
    
    /// Empties the cache immediately.
    func removeAll() {
        lock.around(lru.removeAll())
    }
    
    
    /// If `true`, the key-value pair will be released asynchronously to avoid blocking the access methods,
    /// otherwise it will be released in the access method (such as remove). Default is YES.
    var releaseAsynchronously: Bool {
        get { lock.around(lru.releaseAsynchronously) }
        set { lock.around(lru.releaseAsynchronously = newValue) }
    }
    
    /// If `true`, the key-value pair will be released on main thread,
    /// otherwise on background thread. Default is false.
    /// You may set this value to `true` if the key-value object contains
    /// the instance which should be released in main thread (such as UIView/CALayer).
    var releaseOnMainThread: Bool {
        get { lock.around(lru.releaseOnMainThread) }
        set { lock.around(lru.releaseOnMainThread = newValue)}
    }
    
}

// MARK: trim
public extension MemoryCache {
    
    /// Removes objects from the cache with LRU, until the `count` is below or equal to the specified value.
    /// - Parameter count: The total count allowed to remain after the cache has been trimmed.
    func trim(count: UInt) {
        _trim(count: count)
    }
    
    /// Removes objects from the cache with LRU, until the `totalCost` is or equal to the specified value.
    /// - Parameter cost: The total cost allowed to remain after the cache has been trimmed.
    func trim(cost: UInt) {
        _trim(cost: cost)
    }
    
    /// Removes objects from the cache with LRU, until all expiry objects removed by the specified value.
    /// - Parameter age: The maximum age (in seconds) of objects.
    func trim(age: TimeInterval) {
        _trim(age: age)
    }
}


private extension MemoryCache {
    func _trimRecursively() {
        DispatchQueue.global().asyncAfter(deadline: .now() + autoTrimInterval) { [weak self] in
            guard let self = self else { return }
            self._trimInBackground()
            self._trimRecursively()
        }
    }
    
    func _trimInBackground() {
        queue.async {
            self._trim(cost: self.costLimit)
            self._trim(count: self.countLimit)
            self._trim(age: self.ageLimit)
        }
    }
    
    func _trim(cost: UInt) {
        var finish: Bool = lock.around {
            guard costLimit > 0 else {
                lru.removeAll()
                return true
            }
            return lru.totalCost <= costLimit
        }
        
        if finish { return }
        var holder = [Any]()
        repeat {
            lock.tryAround {
                if lru.totalCost > costLimit {
                    if let tail = lru.removeTail() { holder.append(tail) }
                } else {
                    finish = true
                }
            }
        } while !finish
        if holder.isEmpty { return }
        (lru.releaseOnMainThread ? DispatchQueue.main : .global())
            .async { _ = holder }
    }
    
    func _trim(count: UInt) {
        var finish: Bool = lock.around {
            guard countLimit > 0 else {
                lru.removeAll()
                return true
            }
            return lru.totalCount <= countLimit
        }
        
        if finish { return }
        var holder = [Any]()
        repeat {
            lock.tryAround {
                if lru.totalCount > countLimit {
                    if let tail = lru.removeTail() { holder.append(tail) }
                } else {
                    finish = true
                }
            }
        } while !finish
        if holder.isEmpty { return }
        (lru.releaseOnMainThread ? DispatchQueue.main : .global())
            .async { _ = holder }
    }

    func _trim(age: TimeInterval) {
        let now = CACurrentMediaTime()
        var finish: Bool = lock.around {
            guard ageLimit > 0 else {
                lru.removeAll()
                return true
            }
            guard let tail = lru.tail else { return true }
            return now - tail.time <= ageLimit
        }
        
        if finish { return }
        var holder = [Any]()
        repeat {
            lock.tryAround {
                if let tail = lru.tail, now - tail.time > ageLimit {
                    if let tail = lru.removeTail() { holder.append(tail) }
                } else {
                    finish = true
                }
            }
        } while !finish
        if holder.isEmpty { return }
        (lru.releaseOnMainThread ? DispatchQueue.main : .global())
            .async { _ = holder }
    }
    
    @objc func _appDidReceiveMemoryWarningNotification() {
        didReceiveMemoryWarningClosure?(self)
        if shouldRemoveAllObjectsOnMemoryWarning {
            removeAll()
        }
    }
    
    @objc func _appDidEnterBackgroundNotification() {
        didEnterBackgroundClosure?(self)
        if shouldRemoveAllObjectsWhenEnteringBackground {
            removeAll()
        }
    }
}


fileprivate class LinkedMapNode {
    weak var prev: LinkedMapNode?
    weak var next: LinkedMapNode?
    var key: AnyHashable
    var value: Any
    var cost: UInt
    var time: TimeInterval
    
    init(key: AnyHashable, value: Any, cost: UInt = 0, time: TimeInterval = CACurrentMediaTime()) {
        self.key = key
        self.value = value
        self.cost = cost
        self.time = time
    }
}

extension LinkedMapNode: Hashable {
    static func == (lhs: LinkedMapNode, rhs: LinkedMapNode) -> Bool {
        lhs.key == rhs.key
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}


fileprivate class LinkMap {
    var dict: [AnyHashable: LinkedMapNode] = [:]
    var totalCost: UInt = 0
    var totalCount: UInt = 0
    weak var head: LinkedMapNode?
    weak var tail: LinkedMapNode?
    
    var releaseOnMainThread: Bool = false
    var releaseAsynchronously: Bool = true

    init() { }

    func insertAtHead(node: LinkedMapNode) {
        dict[node.key] = node
        totalCost += node.cost
        totalCount += 1
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    func bringToHead(node: LinkedMapNode) {
        guard head != node else { return }
        node.next?.prev = node.prev
        node.prev?.next = node.next
        if tail == node { tail = node.prev }
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
    }

    func remove(node: LinkedMapNode) {
        dict.removeValue(forKey: node.key)
        totalCost -= node.cost
        totalCount -= 1
        node.next?.prev = node.prev
        node.prev?.next = node.next
        if head == node { head = node.next }
        if tail == node { tail = node.prev }
    }

    @discardableResult
    func removeTail() -> LinkedMapNode? {
        guard let tail = tail else { return nil }
        remove(node: tail)
        return tail
    }

    func removeAll() {
        totalCost = 0
        totalCount = 0
        head = nil
        tail = nil
        guard dict.count > 0 else { return }
        let holder = dict
        dict = [:]
        if releaseAsynchronously {
            (releaseOnMainThread ? DispatchQueue.main : .global())
                .async { _ = holder }
        } else if releaseOnMainThread && pthread_main_np() != 0 {
            DispatchQueue.main.async { _ = holder }
        }
    }
}
