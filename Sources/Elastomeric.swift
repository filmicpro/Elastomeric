//
//  Elastomeric.swift
//  Elastomeric
//
//  Created by Christopher Cohen on 5/25/18.
//

import Foundation
import Photos

//MARK: Elastomeric Type Aliases

public typealias ElastomericEqualityEvaluation = ((_ lhs:Any?, _ rhs:Any?)->Bool)
public typealias ElastomericTypeViabilityEvaluation = ((_ value:Any?)->Bool)
public typealias ObserverBlock = ((_ mutation:ElastomericMutation)->Void)?
public typealias ObserverReceipt = UUID

//MARK: ElastomericObserver

public struct ElastomericObserver {
    public let receipt:ObserverReceipt
    public var inceptQueue:DispatchQueue, block:ObserverBlock
    
    public init(receipt:ObserverReceipt = UUID(), inceptQueue:DispatchQueue, block:ObserverBlock) {
        self.receipt = receipt
        self.inceptQueue = inceptQueue
        self.block = block
    }
}

//MARK: ElastomericMutation

public struct ElastomericMutation {
    public var elastomer:Elastomer
    public var observerReceipt:ObserverReceipt
    public var oldValue:Any?, newValue:Any?
    public let timestamp:TimeInterval = CACurrentMediaTime()
}

//MARK: Elastomer

public struct Elastomer {
    
    public let name:String
    private var nameHashValue:Int // only used for equality check
    fileprivate let evaluateForEquality:ElastomericEqualityEvaluation
    fileprivate let evaluateForAssociatedType:ElastomericTypeViabilityEvaluation
    
    public init<T: Equatable>(associatedType:T.Type, name:String) {
        self.nameHashValue = name.hashValue
        self.name = name
        self.evaluateForEquality = { lhs, rhs in return (lhs as? T) == (rhs as? T) }
        self.evaluateForAssociatedType = { value in return value is T }
    }
    
    public static func ==(lhs: Elastomer, rhs: Elastomer) -> Bool {
        return lhs.nameHashValue == rhs.nameHashValue
    }
    
    ///Add or Replace a value in the model
    public func stageValue(_ value:Any?, discardingRedundancy discardRedundant:Bool = true) {
        ElastomericArchive.stageValue(value, associatedWithElastomer: self, discardingRedundancy:discardRedundant)
    }
    
    ///Add or Replace a value in the model
    public func stageValue(_ value:Any?, afterDelay delay:TimeInterval, discardingRedundancy discardRedundant:Bool = true) {
        DispatchQueue.underlying.asyncAfter(deadline: .now() + delay) {
            ElastomericArchive.stageValue(value, associatedWithElastomer: self, discardingRedundancy:discardRedundant)
        }
    }

    ///Express the current value associated with the elastomer
    public func expressValue(_ result:((Any?)->Void)?) {
        ElastomericArchive.expressValue(associatedWithElastomer: self, result: result)
    }
    
    ///Associate an observer with an Elastomer. A receipt will be returned
    public func registerObserver(_ block:ObserverBlock) -> ObserverReceipt {
        return ElastomericArchive.observeValue(associatedWithElastomer: self, observerBlock: block)
    }
    
    ///Retire associated observers
    public func retireObserver(_ receipt:ObserverReceipt?) {
        guard let receipt = receipt else { return }
        ElastomericArchive.observers[self]?[receipt] = nil
    }
    
    ///Post value to all observers after a delay
    public func post(afterDelay delay:TimeInterval = 0) {
        DispatchQueue.underlying.asyncAfter(deadline: .now() + delay) {
            ElastomericArchive.postValue(associatedWithElastomer: self)
        }
    }
}

extension Elastomer: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.nameHashValue)
    }
}

//MARK: ElastomericArchive

fileprivate struct ElastomericArchive {
    
    fileprivate static let interleaveQueue:OperationQueue = {
        let queue = OperationQueue()
        queue.name = "interleaveQueue"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = QualityOfService(rawValue: 45) ?? QualityOfService.userInteractive
        return queue
    }()
    
    fileprivate static var model = [Elastomer:Any]()
    fileprivate static var observers = [Elastomer:[ObserverReceipt:ElastomericObserver]]()
    
    @inline(__always) private static func reportMutationToObservers(associatedWithElastomer elastomer: Elastomer, oldValue: Any?, newValue:Any?) {
        
        //Interate through all elastomer-associated observers and post value
        self.observers[elastomer]?.forEach({ receipt, observer in
            
            //Report mutation on the observer's incept queue
            observer.inceptQueue.async {
                
                //Create mutation package
                let mutation = ElastomericMutation(elastomer: elastomer, observerReceipt: receipt, oldValue: oldValue, newValue: newValue)
                
                //Report to observers
                observer.block?(mutation)
            }
        })
    }
    
    @inline(__always) fileprivate static func postValue(associatedWithElastomer elastomer:Elastomer) {
        
        //Aquire elastomer-associated value from model
        self.interleaveQueue.addOperation {
            let value = self.model[elastomer]
            reportMutationToObservers(associatedWithElastomer: elastomer, oldValue: value, newValue: value)
        }
    }
    
    @inline(__always) fileprivate static func stageValue(_ value:Any?, associatedWithElastomer elastomer:Elastomer, discardingRedundancy discardRedundant:Bool) {
        
        //If the value is not the expected type, abort
        guard elastomer.evaluateForAssociatedType(value) else { return }
        
        //Add value to model
        self.interleaveQueue.addOperation {
            
            //Capture old value
            let oldValue = self.model[elastomer]
            
            //Determine redundancy
            let redundantAssignment:Bool = elastomer.evaluateForEquality(oldValue, value)
            
            //Abort if assignment is redundant and redundancy filter is active
            if discardRedundant && redundantAssignment { return }
            
            //Assign new value to model
            self.model[elastomer] = value
            
            //Notify observers of change
            reportMutationToObservers(associatedWithElastomer: elastomer, oldValue: oldValue, newValue: value)
        }
    }
    
    @inline(__always) fileprivate static func observeValue(associatedWithElastomer elastomer:Elastomer, observerBlock:ObserverBlock) -> ObserverReceipt {
        
        //Attempt to capture incept queue
        let inceptQueue = DispatchQueue.underlying
        
        //Create a UUID receipt for the observer
        let receipt = ObserverReceipt()
        
        //Register observer on the interleave Queue
        interleaveQueue.addOperation {
            observers[elastomer] = observers[elastomer] ?? [ObserverReceipt:ElastomericObserver]()
            let observer = ElastomericObserver(receipt: receipt, inceptQueue: inceptQueue, block: observerBlock)
            observers[elastomer]?[observer.receipt] = observer
        }
        
        //Return the observer's ObserverReceipt
        return receipt
    }
    
    @inline(__always) fileprivate static func retireObserver(associatedWithElastomer elastomer:Elastomer, receipt:ObserverReceipt) {
        
        self.interleaveQueue.addOperation {
            observers[elastomer]?[receipt] = nil
        }
    }
    
    @inline(__always) fileprivate static func expressValue(associatedWithElastomer elastomer:Elastomer, result:((Any?)->Void)?) {
        
        //Attempt to capture incept queue
        let inceptQueue = DispatchQueue.underlying
        
        //On interleave queue, query value
        self.interleaveQueue.addOperation {
            
            //Attempt to aquire value from model
            let value:Any? = self.model[elastomer]
            
            //Report result on incept queue in param block
            inceptQueue.async {
                result?(value) //Result
            }
        }
    }
}

public extension DispatchQueue {
    static var underlying:DispatchQueue { return OperationQueue.current?.underlyingQueue ?? DispatchQueue.main }
}

//MARK: Elastomeric Batch Operations

public extension Sequence where Element == Elastomer {
    
    ///Pull a group of Elastomer-associated values
    func expressValues(_ result:(([Elastomer:Any])->Void)?) {
        
        //Capture incept queue
        let inceptQueue = DispatchQueue.underlying
        
        //Populate dictionary with results
        ElastomericArchive.interleaveQueue.addOperation {
            
            //Create empty dictionary that will contain response
            var dict = [Elastomer:Any]()
            
            //Populate dictionary from Archive model
            for elastomer in self { dict[elastomer] = ElastomericArchive.model[elastomer] }
            
            //Publish result on incept queue
            inceptQueue.async { result?(dict) }
        }
    }
    
    func registerObservers(_ block:ObserverBlock) -> [Elastomer:ObserverReceipt] {
        var receipts = [Elastomer:ObserverReceipt]()
        for elastomer in self {
            receipts[elastomer] = ElastomericArchive.observeValue(associatedWithElastomer: elastomer, observerBlock: block)
        }
        return receipts
    }
}

public extension Dictionary where Key == Elastomer, Value == ObserverReceipt {
    func retireAll() {
        self.forEach { elastomer, receipt in
            ElastomericArchive.retireObserver(associatedWithElastomer: elastomer, receipt: receipt)
        }
    }
}

public extension Dictionary where Key == Elastomer, Value == Any {
    func stage() {
        self.forEach { elastomer, value in
            ElastomericArchive.stageValue(value, associatedWithElastomer: elastomer, discardingRedundancy:true)
        }
    }
}
