//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Network)
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOConcurrencyHelpers
import Dispatch
import Network
import Atomics

/// Listener channels do not have active substates: they are either active or they
/// are not.
enum ListenerActiveSubstate: ActiveChannelSubstate {
    case active

    init() {
        self = .active
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
enum ProtocolOptions {
    case tcp(NWProtocolTCP.Options)
    case udp(NWProtocolUDP.Options)
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal class StateManagedListenerChannel<ChildChannel: StateManagedChannel>: StateManagedChannel {
    typealias ActiveSubstate = ListenerActiveSubstate
    /// The `ByteBufferAllocator` for this `Channel`.
    public let allocator = ByteBufferAllocator()

    /// An `EventLoopFuture` that will complete when this channel is finally closed.
    public var closeFuture: EventLoopFuture<Void> {
        self.closePromise.futureResult
    }

    /// The parent `Channel` for this one, if any.
    public let parent: Channel? = nil

    /// The `EventLoop` this `Channel` belongs to.
    internal let tsEventLoop: NIOTSEventLoop

    // This is really a constant (set in .init) but needs `self` to be constructed and therefore a `var`.
    // *Do not change* as this needs to accessed from arbitrary threads.
    internal var _pipeline: ChannelPipeline! = nil

    internal let closePromise: EventLoopPromise<Void>

    /// The underlying `NWListener` that this `Channel` wraps. This is only non-nil
    /// after the initial connection attempt has been made.
    internal var nwListener: NWListener?

    /// The TLS options for this listener.
    internal let tlsOptions: NWProtocolTLS.Options?

    /// A customization point for this listener's `NWParameters`.
    internal let nwParametersConfigurator: (@Sendable (NWParameters) -> Void)?

    /// The `DispatchQueue` that socket events for this connection will be dispatched onto.
    internal let connectionQueue: DispatchQueue

    /// An `EventLoopPromise` that will be succeeded or failed when a bind attempt succeeds or fails.
    internal var bindPromise: EventLoopPromise<Void>?

    /// The state of this connection channel.
    internal var state: ChannelState<ListenerActiveSubstate> = .idle

    /// The kinds of channel activation this channel supports
    internal let supportedActivationType: ActivationType = .bind

    /// The active state, used for safely reporting the channel state across threads.
    internal var isActive0 = ManagedAtomic(false)

    /// Whether a call to NWListener.receive has been made, but the completion
    /// handler has not yet been invoked.
    private var outstandingRead: Bool = false

    /// Whether autoRead is enabled for this channel.
    internal var autoRead: Bool = true

    /// The value of SO_REUSEADDR.
    internal var reuseAddress = false

    /// The value of SO_REUSEPORT.
    internal var reusePort = false

    /// The value of the allowLocalEndpointReuse option.
    internal var allowLocalEndpointReuse = false

    /// Whether to enable peer-to-peer connectivity when using Bonjour services.
    internal var enablePeerToPeer = false

    /// The default multipath service type.
    internal var multipathServiceType = NWParameters.MultipathServiceType.disabled

    /// The event loop group to use for child channels.
    internal let childLoopGroup: EventLoopGroup

    /// The QoS to use for child channels.
    internal let childChannelQoS: DispatchQoS?

    /// The TLS options to use for child channels.
    internal let childTLSOptions: NWProtocolTLS.Options?

    /// A customization point for each child's `NWParameters`.
    internal let childNWParametersConfigurator: (@Sendable (NWParameters) -> Void)?

    /// The cache of the local and remote socket addresses. Must be accessed using _addressCacheLock.
    internal var addressCache = AddressCache(local: nil, remote: nil)

    /// A lock that guards the _addressCache.
    internal let _addressCacheLock = NIOLock()

    /// The protocol level options for this listener.
    var protocolOptions: ProtocolOptions

    /// The protocol level options to use for child channels.
    var childProtocolOptions: ProtocolOptions

    internal init(
        eventLoop: NIOTSEventLoop,
        qos: DispatchQoS? = nil,
        protocolOptions: ProtocolOptions,
        tlsOptions: NWProtocolTLS.Options?,
        nwParametersConfigurator: (@Sendable (NWParameters) -> Void)?,
        childLoopGroup: EventLoopGroup,
        childChannelQoS: DispatchQoS?,
        childProtocolOptions: ProtocolOptions,
        childTLSOptions: NWProtocolTLS.Options?,
        childNWParametersConfigurator: (@Sendable (NWParameters) -> Void)?
    ) {
        self.tsEventLoop = eventLoop
        self.closePromise = eventLoop.makePromise()
        self.connectionQueue = eventLoop.channelQueue(label: "nio.transportservices.listenerchannel", qos: qos)
        self.protocolOptions = protocolOptions
        self.tlsOptions = tlsOptions
        self.nwParametersConfigurator = nwParametersConfigurator
        self.childLoopGroup = childLoopGroup
        self.childChannelQoS = childChannelQoS
        self.childProtocolOptions = childProtocolOptions
        self.childTLSOptions = childTLSOptions
        self.childNWParametersConfigurator = childNWParametersConfigurator

        // Must come last, as it requires self to be completely initialized.
        self._pipeline = ChannelPipeline(channel: self)
    }

    internal convenience init(
        wrapping listener: NWListener,
        eventLoop: NIOTSEventLoop,
        qos: DispatchQoS? = nil,
        protocolOptions: ProtocolOptions,
        tlsOptions: NWProtocolTLS.Options?,
        nwParametersConfigurator: (@Sendable (NWParameters) -> Void)?,
        childLoopGroup: EventLoopGroup,
        childChannelQoS: DispatchQoS?,
        childProtocolOptions: ProtocolOptions,
        childTLSOptions: NWProtocolTLS.Options?,
        childNWParametersConfigurator: (@Sendable (NWParameters) -> Void)?
    ) {
        self.init(
            eventLoop: eventLoop,
            qos: qos,
            protocolOptions: protocolOptions,
            tlsOptions: tlsOptions,
            nwParametersConfigurator: nwParametersConfigurator,
            childLoopGroup: childLoopGroup,
            childChannelQoS: childChannelQoS,
            childProtocolOptions: childProtocolOptions,
            childTLSOptions: childTLSOptions,
            childNWParametersConfigurator: childNWParametersConfigurator
        )
        self.nwListener = listener
    }

    func newConnectionHandler(connection: NWConnection) {
        fatalError("This function must be overridden by the subclass")
    }

    // This needs to be declared here to make sure the child classes can override
    // the behaviour.
    internal var syncOptions: NIOSynchronousChannelOptions? {
        nil
    }

}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension StateManagedListenerChannel {
    /// The `ChannelPipeline` for this `Channel`.
    public var pipeline: ChannelPipeline {
        self._pipeline
    }

    /// The local address for this channel.
    public var localAddress: SocketAddress? {
        self.addressCache.local
    }

    /// The remote address for this channel.
    public var remoteAddress: SocketAddress? {
        self.addressCache.remote
    }

    /// Whether this channel is currently writable.
    public var isWritable: Bool {
        // TODO: implement
        true
    }

    public var _channelCore: ChannelCore {
        self
    }

    public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        if self.eventLoop.inEventLoop {
            return self.eventLoop.makeCompletedFuture(Result { try setOption0(option: option, value: value) })
        } else {
            return self.eventLoop.submit { try self.setOption0(option: option, value: value) }
        }
    }

    internal func setOption0<Option: ChannelOption>(option: Option, value: Option.Value) throws {
        self.eventLoop.preconditionInEventLoop()

        guard !self.closed else {
            throw ChannelError.ioOnClosedChannel
        }

        // TODO: Many more channel options, both from NIO and Network.framework.
        switch option {
        case is ChannelOptions.Types.AutoReadOption:
            // AutoRead is currently mandatory for TS listeners.
            if value as! ChannelOptions.Types.AutoReadOption.Value == false {
                throw ChannelError.operationUnsupported
            }
        case let optionValue as ChannelOptions.Types.SocketOption:
            // SO_REUSEADDR and SO_REUSEPORT are handled here.
            switch (optionValue.level, optionValue.name) {
            case (SOL_SOCKET, SO_REUSEADDR):
                self.reuseAddress = (value as! SocketOptionValue) != Int32(0)
            case (SOL_SOCKET, SO_REUSEPORT):
                self.reusePort = (value as! SocketOptionValue) != Int32(0)
            default:
                // We can set it here like this, because these are reference types
                switch protocolOptions {
                case .tcp(let protocolOptions):
                    try protocolOptions.applyChannelOption(option: optionValue, value: value as! SocketOptionValue)
                case .udp(let protocolOptions):
                    try protocolOptions.applyChannelOption(option: optionValue, value: value as! SocketOptionValue)
                }
            }
        case is NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption:
            self.enablePeerToPeer = value as! NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption.Value
        case is NIOTSChannelOptions.Types.NIOTSAllowLocalEndpointReuse:
            self.allowLocalEndpointReuse = value as! NIOTSChannelOptions.Types.NIOTSAllowLocalEndpointReuse.Value
        case is NIOTSChannelOptions.Types.NIOTSMultipathOption:
            self.multipathServiceType = value as! NIOTSChannelOptions.Types.NIOTSMultipathOption.Value
        default:
            fatalError("option \(option) not supported")
        }
    }

    public func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value> {
        if eventLoop.inEventLoop {
            return self.eventLoop.makeCompletedFuture(Result { try getOption0(option: option) })
        } else {
            return eventLoop.submit { try self.getOption0(option: option) }
        }
    }

    internal func getOption0<Option: ChannelOption>(option: Option) throws -> Option.Value {
        self.eventLoop.preconditionInEventLoop()

        guard !self.closed else {
            throw ChannelError.ioOnClosedChannel
        }

        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            switch option {
            case is NIOTSChannelOptions.Types.NIOTSListenerOption:
                return self.nwListener as! Option.Value
            default:
                // Fallthrough to non-restricted options
                ()
            }
        }

        switch option {
        case is ChannelOptions.Types.AutoReadOption:
            return autoRead as! Option.Value
        case let optionValue as ChannelOptions.Types.SocketOption:
            // SO_REUSEADDR and SO_REUSEPORT are handled here.
            switch (optionValue.level, optionValue.name) {
            case (SOL_SOCKET, SO_REUSEADDR):
                return Int32(self.reuseAddress ? 1 : 0) as! Option.Value
            case (SOL_SOCKET, SO_REUSEPORT):
                return Int32(self.reusePort ? 1 : 0) as! Option.Value
            default:
                switch protocolOptions {
                case .tcp(let protocolOptions):
                    return try protocolOptions.valueFor(socketOption: optionValue) as! Option.Value
                case .udp(let protocolOptions):
                    return try protocolOptions.valueFor(socketOption: optionValue) as! Option.Value
                }
            }
        case is NIOTSChannelOptions.Types.NIOTSEnablePeerToPeerOption:
            return self.enablePeerToPeer as! Option.Value
        case is NIOTSChannelOptions.Types.NIOTSAllowLocalEndpointReuse:
            return self.allowLocalEndpointReuse as! Option.Value
        case is NIOTSChannelOptions.Types.NIOTSMultipathOption:
            return self.multipathServiceType as! Option.Value
        default:
            fatalError("option \(option) not supported")
        }
    }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension StateManagedListenerChannel {
    internal func alreadyConfigured0(promise: EventLoopPromise<Void>?) {
        guard let listener = nwListener else {
            promise?.fail(NIOTSErrors.NotPreConfigured())
            return
        }

        guard case .setup = listener.state else {
            promise?.fail(NIOTSErrors.NotPreConfigured())
            return
        }
        self.bindPromise = promise
        listener.stateUpdateHandler = self.stateUpdateHandler(newState:)
        listener.newConnectionHandler = self.newConnectionHandler(connection:)
        listener.start(queue: self.connectionQueue)
    }

    public func localAddress0() throws -> SocketAddress {
        guard let listener = self.nwListener else {
            throw ChannelError.ioOnClosedChannel
        }

        guard let localEndpoint = listener.parameters.requiredLocalEndpoint else {
            throw NIOTSErrors.UnableToResolveEndpoint()
        }

        var address = try SocketAddress(fromNWEndpoint: localEndpoint)

        // If we were asked to bind port 0, we need to update that.
        if let port = address.port, port == 0 {
            // We were. Let's ask Network.framework what we got. Nothing is an unacceptable answer.
            guard let actualPort = listener.port else {
                throw NIOTSErrors.UnableToResolveEndpoint()
            }
            address.newPort(actualPort.rawValue)
        }

        return address
    }

    public func remoteAddress0() throws -> SocketAddress {
        throw ChannelError.operationUnsupported
    }

    internal func beginActivating0(to target: NWEndpoint, promise: EventLoopPromise<Void>?) {
        assert(self.bindPromise == nil)
        self.bindPromise = promise

        let parameters: NWParameters

        switch protocolOptions {
        case .tcp(let tcpOptions):
            parameters = .init(tls: self.tlsOptions, tcp: tcpOptions)
        case .udp(let udpOptions):
            parameters = .init(dtls: self.tlsOptions, udp: udpOptions)
        }

        // If we have a target that is not for a Bonjour service, we treat this as a request for
        // a specific local endpoint. That gets configured on the parameters. If this is a bonjour
        // endpoint, we deal with that later, though if it has requested a specific interface we
        // set that now.
        switch target {
        case .hostPort, .unix:
            parameters.requiredLocalEndpoint = target
        case .service(_, _, _, let interface):
            parameters.requiredInterface = interface
        default:
            // We can't use `@unknown default` and explicitly list cases we know about since they
            // would require availability checks within the switch statement (`.url` was added in
            // macOS 10.15).
            ()
        }

        // Network.framework munges REUSEADDR and REUSEPORT together, so we turn this on if we need
        // either or it's been explicitly set.
        parameters.allowLocalEndpointReuse = self.reuseAddress || self.reusePort || self.allowLocalEndpointReuse

        parameters.includePeerToPeer = self.enablePeerToPeer

        parameters.multipathServiceType = self.multipathServiceType

        self.nwParametersConfigurator?(parameters)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            self.close0(error: error, mode: .all, promise: nil)
            return
        }

        if case .service(let name, let type, let domain, _) = target {
            // Ok, now we deal with Bonjour.
            listener.service = NWListener.Service(name: name, type: type, domain: domain)
        }

        listener.stateUpdateHandler = self.stateUpdateHandler(newState:)
        listener.newConnectionHandler = self.newConnectionHandler(connection:)

        // Ok, state is ready. Let's go!
        self.nwListener = listener
        listener.start(queue: self.connectionQueue)
    }

    public func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.operationUnsupported)
    }

    public func flush0() {
        // Flush is not supported on listening channels.
    }

    /// Perform a read from the network.
    ///
    /// This method has a slightly strange semantic, because we do not allow multiple reads at once. As a result, this
    /// is a *request* to read, and if there is a read already being processed then this method will do nothing.
    public func read0() {
        // AutoRead is currently mandatory, so this method does nothing.
    }

    public func doClose0(error: Error) {
        // Step 1: tell the networking stack (if created) that we're done.
        if let listener = self.nwListener {
            listener.cancel()
        }

        // Step 2: fail any pending bind promise.
        if let pendingBind = self.bindPromise {
            self.bindPromise = nil
            pendingBind.fail(error)
        }
    }

    public func doHalfClose0(error: Error, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.operationUnsupported)
    }

    public func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case let x as NIOTSNetworkEvents.BindToNWEndpoint:
            self.bind0(to: x.endpoint, promise: promise)
        default:
            promise?.fail(ChannelError.operationUnsupported)
        }
    }

    public func channelRead0(_ data: NIOAny) {
        self.eventLoop.assertInEventLoop()

        let channel = self.unwrapData(data, as: ChildChannel.self)
        let p: EventLoopPromise<Void> = channel.eventLoop.makePromise()
        channel.eventLoop.execute {
            channel.registerAlreadyConfigured0(promise: p)
            p.futureResult.whenFailure { (_: Error) in
                channel.close(promise: nil)
            }
        }
    }

    public func errorCaught0(error: Error) {
        // Currently we don't do anything with errors that pass through the pipeline
        return
    }

    /// A function that will trigger a socket read if necessary.
    internal func readIfNeeded0() {
        // AutoRead is currently mandatory, so this does nothing.
    }
}

// MARK:- Implementations of the callbacks passed to NWListener.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension StateManagedListenerChannel {
    /// Called by the underlying `NWListener` when its internal state has changed.
    private func stateUpdateHandler(newState: NWListener.State) {
        switch newState {
        case .setup:
            preconditionFailure("Should not be told about this state.")
        case .waiting:
            break
        case .ready:
            // Transitioning to ready means the bind succeeded. Hooray!
            self.bindComplete0()
        case .cancelled:
            // This is the network telling us we're closed. We don't need to actually do anything here
            // other than check our state is ok.
            assert(self.closed)
            self.nwListener = nil
        case .failed(let err):
            // The connection has failed for some reason.
            self.close0(error: err, mode: .all, promise: nil)
        default:
            // This clause is here to help the compiler out: it's otherwise not able to
            // actually validate that the switch is exhaustive. Trust me, it is.
            fatalError("Unreachable")
        }
    }
}

// MARK:- Implementations of state management for the channel.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension StateManagedListenerChannel {
    /// Make the channel active.
    private func bindComplete0() {
        let promise = self.bindPromise
        self.bindPromise = nil

        // Before becoming active, update the cached addresses. Remote is always nil.
        let localAddress = try? self.localAddress0()

        self._addressCacheLock.withLock {
            self.addressCache = AddressCache(local: localAddress, remote: nil)
        }

        self.becomeActive0(promise: promise)
    }
}

// We inherit from StateManagedListenerChannel in NIOTSDatagramListenerChannel, so we can't mark
// it as Sendable safely.
@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension StateManagedListenerChannel: @unchecked Sendable {}

#endif
