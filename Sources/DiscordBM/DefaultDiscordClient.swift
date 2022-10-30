import Foundation
import AsyncHTTPClient
import Logging
import struct NIOPosix.NIOConnectionError
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOCore
import Atomics

/// The fact that this could be used by multiple different `DiscordClient`s with
/// different `token`s should not matter because buckets are random anyway.
private let rateLimiter = HTTPRateLimiter(label: "DiscordClientRateLimiter")

//MARK: - DefaultDiscordClient
public struct DefaultDiscordClient: DiscordClient {
    
    let client: HTTPClient
    public let token: Secret
    public let appId: String?
    let configuration: ClientConfiguration
    private let cache: ClientCache?
    let logger = DiscordGlobalConfiguration.makeLogger("DefaultDiscordClient")
    
    private static let requestIdGenerator = ManagedAtomic(UInt(0))
    
    /// If you provide no app id, you'll need to pass it to some functions on call site.
    public init(
        httpClient: HTTPClient,
        token: Secret,
        appId: String?,
        configuration: ClientConfiguration = .init()
    ) {
        self.client = httpClient
        self.token = token
        self.appId = appId
        self.configuration = configuration
        if configuration.cachingBehavior.isDisabled {
            self.cache = nil
        } else {
            /// So each token has its own cache, because
            /// answers might be different for different tokens.
            self.cache = ClientCacheStorage.shared.cache(for: token)
        }
    }
    
    /// If you provide no app id, you'll need to pass it to some functions on call site.
    public init(
        httpClient: HTTPClient,
        token: String,
        appId: String?,
        configuration: ClientConfiguration = .init()
    ) {
        self.init(
            httpClient: httpClient,
            token: Secret(token),
            appId: appId,
            configuration: configuration
        )
    }
    
    func checkRateLimitsAllowRequest(to endpoint: Endpoint) async throws {
        if await !rateLimiter.shouldRequest(to: endpoint) {
            throw DiscordClientError.rateLimited(url: "\(endpoint.url)")
        }
    }
    
    func includeInRateLimits(
        endpoint: Endpoint,
        headers: HTTPHeaders,
        status: HTTPResponseStatus
    ) async {
        await rateLimiter.include(endpoint: endpoint, headers: headers, status: status)
    }
    
    func getFromCache(
        identity: CacheableEndpointIdentity?,
        queries: [(String, String?)]
    ) async -> DiscordHTTPResponse? {
        guard let identity = identity else { return nil }
        return await cache?.get(item: .init(
            identity: identity,
            queries: queries
        ))
    }
    
    func saveInCache(
        response: DiscordHTTPResponse,
        identity: CacheableEndpointIdentity?,
        queries: [(String, String?)]
    ) async {
        guard let identity = identity,
              (200..<300).contains(response.status.code),
              let ttl = self.configuration.cachingBehavior.getTTL(for: identity)
        else { return }
        if let cache = cache {
            logger.debug("Saved response in cache", metadata: [
                "endpointIdentity": .stringConvertible(identity),
                "queries": .stringConvertible(queries)
            ])
            await cache.add(
                response: response,
                item: .init(
                    identity: identity,
                    queries: queries
                ), ttl: ttl
            )
        }
    }
    
    func execute(_ request: HTTPClient.Request) async throws -> DiscordHTTPResponse {
        DiscordHTTPResponse(
            _response: try await self.client.execute(
                request: request,
                deadline: .now() + configuration.requestTimeout,
                logger: configuration.enableLoggingForRequests
                ? DiscordGlobalConfiguration.makeLogger("DBM+HTTPClient")
                : Logger(label: "DBM-no-op-logger", factory: { _ in SwiftLogNoOpLogHandler() })
            ).get()
        )
    }
    
    /// Waits for the next retry if needed, and increases the retry counter.
    func waitForRetryAndIncreaseRetryCount(
        retriesSoFar: inout Int,
        headers: HTTPHeaders,
        requestId: UInt
    ) async throws {
        let retryWait = self.configuration.shouldWaitBeforeRetry(
            retriesSoFar: retriesSoFar,
            headers: headers
        )
        logger.warning("Will soon retry a request", metadata: [
            "request-id": .stringConvertible(requestId),
            "retriesWithoutThis": .stringConvertible(retriesSoFar),
            "waitSecondsBeforeRetry": .stringConvertible(retryWait ?? 0)
        ])
        if let retryWait = retryWait {
            try await Task.sleep(nanoseconds: UInt64(retryWait * 1_000_000_000))
        }
        retriesSoFar += 1
        logger.debug("Will retry a request right now", metadata: [
            "request-id": .stringConvertible(requestId),
            "retriesWithoutThis": .stringConvertible(retriesSoFar)
        ])
    }
    
    /// Sends requests and retries if needed.
    func sendWithRetries(
        endpoint: Endpoint,
        queries: [(String, String?)],
        sendRequest: (CacheableEndpointIdentity?, Int, UInt) async throws -> (DiscordHTTPResponse, Bool)
    ) async throws -> DiscordHTTPResponse {
        
        let identity = CacheableEndpointIdentity(endpoint: endpoint)
        let requestId = Self.requestIdGenerator.wrappingIncrementThenLoad(ordering: .relaxed)
        
        var (response, cached): (DiscordHTTPResponse, Bool)
        var retriesSoFar = 0
        
        do {
            (response, cached) = try await sendRequest(identity, retriesSoFar, requestId)
        } catch {
            guard let policy = configuration.retryPolicy,
                  policy.shouldRetryConnectionErrors else {
                throw error
            }
            switch error {
            case let ahcError as HTTPClientError where ahcError == .remoteConnectionClosed:
                fallthrough
            case is NIOConnectionError:
                try await waitForRetryAndIncreaseRetryCount(
                    retriesSoFar: &retriesSoFar,
                    headers: [:],
                    requestId: requestId
                )
                (response, cached) = try await sendRequest(identity, retriesSoFar, requestId)
            default:
                throw error
            }
        }
        
        while configuration.shouldRetry(status: response.status, retriesSoFar: retriesSoFar) {
            try await waitForRetryAndIncreaseRetryCount(
                retriesSoFar: &retriesSoFar,
                headers: response.headers,
                requestId: requestId
            )
            (response, cached) = try await sendRequest(identity, retriesSoFar, requestId)
        }
        
        if !cached {
            await self.saveInCache(
                response: response,
                identity: identity,
                queries: queries
            )
        }
        
        return response
    }
    
    public func send(
        to endpoint: Endpoint,
        queries: [(String, String?)] = []
    ) async throws -> DiscordHTTPResponse {
        try await self.sendWithRetries(endpoint: endpoint, queries: queries) {
            identity, retryCounter, requestId in
            
            if let cached = await self.getFromCache(identity: identity, queries: queries) {
                logger.debug("Got cached response", metadata: [
                    "endpoint": .string(endpoint.urlSuffix),
                    "queries": .stringConvertible(queries),
                    "retry": .stringConvertible(retryCounter)
                ])
                return (cached, true)
            }
            
            try await self.checkRateLimitsAllowRequest(to: endpoint)
            var request = try HTTPClient.Request(
                url: endpoint.url + queries.makeForURLQuery(),
                method: endpoint.httpMethod
            )
            request.headers = ["Authorization": "Bot \(token._storage)"]
            
            logger.debug("Will send a request to Discord", metadata: [
                "url": .stringConvertible(request.url),
                "method": .string(request.method.rawValue),
                "body-bytes": "nil",
                "retry": .stringConvertible(retryCounter),
                "request-id": .stringConvertible(requestId)
            ])
            let response = try await self.execute(request)
            logger.debug("Received a response from Discord", metadata: [
                "response": .stringConvertible(response),
                "retry": .stringConvertible(retryCounter),
                "request-id": .stringConvertible(requestId)
            ])
            
            await self.includeInRateLimits(
                endpoint: endpoint,
                headers: response.headers,
                status: response.status
            )
            
            return (response, false)
        }
    }
    
    public func send<E: Encodable>(
        to endpoint: Endpoint,
        queries: [(String, String?)] = [],
        payload: E
    ) async throws -> DiscordHTTPResponse {
        try await self.sendWithRetries(endpoint: endpoint, queries: queries) {
            identity, retryCounter, requestId in
            
            let identity = CacheableEndpointIdentity(endpoint: endpoint)
            if let cached = await self.getFromCache(identity: identity, queries: queries) {
                return (cached, true)
            }
            if let cached = await self.getFromCache(identity: identity, queries: queries) {
                logger.debug("Got cached response", metadata: [
                    "endpoint": .string(endpoint.urlSuffix),
                    "queries": .stringConvertible(queries),
                    "retry": .stringConvertible(retryCounter)
                ])
                return (cached, true)
            }
            
            try await self.checkRateLimitsAllowRequest(to: endpoint)
            let data = try DiscordGlobalConfiguration.encoder.encode(payload)
            var request = try HTTPClient.Request(
                url: endpoint.url + queries.makeForURLQuery(),
                method: endpoint.httpMethod
            )
            request.headers = [
                "Authorization": "Bot \(token._storage)",
                "Content-Type": "application/json"
            ]
            request.body = .bytes(data)
            
            logger.debug("Will send a request to Discord", metadata: [
                "url": .stringConvertible(request.url),
                "method": .string(request.method.rawValue),
                "body-bytes": .stringConvertible(data),
                "retry": .stringConvertible(retryCounter),
                "request-id": .stringConvertible(requestId)
            ])
            let response = try await self.execute(request)
            logger.debug("Received a response from Discord", metadata: [
                "response": .stringConvertible(response),
                "retry": .stringConvertible(retryCounter),
                "request-id": .stringConvertible(requestId)
            ])
            
            await self.includeInRateLimits(
                endpoint: endpoint,
                headers: response.headers,
                status: response.status
            )
            
            return (response, false)
        }
    }
}

//MARK: - ClientConfiguration
public struct ClientConfiguration {
    
    public struct CachingBehavior {
        
        /// [ID: TTL]
        @usableFromInline
        var storage = [CacheableEndpointIdentity: Double]()
        /// This instance's default TTL for all endpoints.
        public var defaultTTL = 5.0
        public var isDisabled = false
        
        /// Caches all cacheable endpoints for 5 seconds,
        /// except for `getGateway` which is cached for an hour.
        public static var enabled: CachingBehavior {
            var behavior = CachingBehavior()
            behavior.modifyBehavior(of: .getGateway, ttl: 3600)
            return behavior
        }
        /// Doesn't allow caching at all.
        public static var disabled: CachingBehavior {
            CachingBehavior(isDisabled: true)
        }
        
        @inlinable
        public mutating func modifyBehavior(
            of identity: CacheableEndpointIdentity,
            ttl: Double? = nil
        ) {
            guard !self.isDisabled else { return }
            self.storage[identity] = ttl ?? 0
        }
        
        @inlinable
        func getTTL(for identity: CacheableEndpointIdentity) -> Double? {
            guard !self.isDisabled else { return nil }
            guard let ttl = self.storage[identity] else { return self.defaultTTL }
            return ttl == 0 ? nil : ttl
        }
    }
    
    public struct RetryPolicy {
        
        public indirect enum Backoff {
            /// How many seconds.
            case constant(Double)
            /// `upToTimes` indicates how many times at maximum this should linearly increase
            /// the backoff. Does not indicate how many times the retrial will happen.
            /// Assuming `backoff = a + bx` is the linear equation, then: `a == base`, `b == coefficient`.
            /// `base` and `coefficient` are in seconds.
            case linear(base: Double, coefficient: Double, upToTimes: UInt)
            /// `upToTimes` indicates how many times at maximum this should linearly increase
            /// the backoff. Does not indicate how many times the retrial will happen.
            /// Assuming `backoff = a + b(c^x)` is the exponential equation, then: `a == base`, `b == coefficient`, `c == rate`.
            /// Make sure to keep `rate` above 1.
            /// `base` and `rate` are in seconds.
            case exponential(
                base: Double,
                coefficient: Double = 1,
                rate: Double = 2,
                upToTimes: UInt
            )
            /// Based on the `Retry-After` header.
            ///
            /// Parameters:
            /// - `maxAllowed`: Max allowed amount in `Retry-After`. In seconds.
            /// - `retryIfGreater`: Retry or not even if the header time is greater than
            ///  `maxAllowed`. If yes, the retry will happen after `maxAllowed` amount of time.
            /// - `else`: If the `Retry-After` header did not exist.
            case basedOnTheRetryAfterHeader(
                maxAllowed: Double?,
                retryIfGreater: Bool = false,
                else: Backoff?
            )
            
            public static var `default`: Backoff = .basedOnTheRetryAfterHeader(
                maxAllowed: 5,
                retryIfGreater: false,
                else: .exponential(base: 0.2, coefficient: 0.5, rate: 2, upToTimes: 10)
            )
            
            /// Returns the time needed to wait before the next retry, if any.
            func waitTimeBeforeRetry(retriesSoFar times: Int, headers: HTTPHeaders) -> Double? {
                switch self {
                case let .constant(constant):
                    return constant
                case let .linear(base, coefficient, upToTimes):
                    let multiplyFactor = min(Int(upToTimes), times)
                    let time = coefficient * Double(multiplyFactor) + base
                    return time
                case let .exponential(base, coefficient, rate, upToTimes):
                    let exponent = min(Int(upToTimes), times)
                    let time = base + coefficient * pow(rate, Double(exponent))
                    return time
                case let .basedOnTheRetryAfterHeader(maxAllowed, retryIfGreater, elseBackoff):
                    if let retryAfterString = headers.first(name: "Retry-After"),
                       let retryAfter = Double(retryAfterString) {
                        if retryAfter <= (maxAllowed ?? 0) {
                            return retryAfter
                        } else {
                            if retryIfGreater {
                                return maxAllowed
                            } else {
                                return nil
                            }
                        }
                    } else {
                        return elseBackoff?.waitTimeBeforeRetry(retriesSoFar: times, headers: headers)
                    }
                }
            }
        }
        
        var _statuses: [HTTPResponseStatus]
        
        public var statuses: [HTTPResponseStatus] {
            get { self._statuses }
            set {
                precondition(newValue.allSatisfy({ $0.code >= 400 }), "Status codes less than 400 do not need retrying. This would cause problems")
                self._statuses = newValue
            }
        }
        
        /// Max amount of times to retry any eligible requests.
        public var maxRetries: Int
        
        /// Whether to retry some `HTTPClient` errors and all `NIOConnectionError` errors.
        /// This retry can happen only once for each request.
        public var shouldRetryConnectionErrors: Bool
        
        /// The backoff configuration, to wait a some amount of time _after_ a failed request.
        public var backoff: Backoff?
        
        /// Only retries status code 429 and 500 once.
        @inlinable
        public static var `default`: RetryPolicy {
            RetryPolicy(statuses: [.tooManyRequests, .internalServerError])
        }
        
        /// - Parameters:
        ///   - shouldRetryConnectionErrors: Whether to retry some `HTTPClient` errors and all
        ///    `NIOConnectionError` errors. This retry can happen only once for each request.
        ///   - backoff: The backoff configuration, to wait a some amount of time
        ///   _after_ a failed request.
        public init(
            statuses: [HTTPResponseStatus],
            maxRetries: Int = 1,
            shouldRetryConnectionErrors: Bool = false,
            backoff: Backoff? = .default
        ) {
            self._statuses = []
            self.maxRetries = maxRetries
            self.shouldRetryConnectionErrors = shouldRetryConnectionErrors
            self.backoff = backoff
            self.statuses = statuses
        }
        
        /// Should retry a request or not.
        func shouldRetry(status: HTTPResponseStatus, retriesSoFar times: Int) -> Bool {
            maxRetries > times && self.statuses.contains(status)
        }
    }
    
    /// The behavior used for caching requests.
    public let cachingBehavior: CachingBehavior
    /// How much for the `HTTPClient` to wait for a connection before failing.
    public var requestTimeout: TimeAmount
    /// Ask `HTTPClient` to log when needed. Defaults to no logging.
    public var enableLoggingForRequests: Bool
    /// Retries failed requests based on this policy.
    public var retryPolicy: RetryPolicy?
    
    func shouldRetry(status: HTTPResponseStatus, retriesSoFar times: Int) -> Bool {
        self.retryPolicy?.shouldRetry(status: status, retriesSoFar: times) ?? false
    }
    
    /// Returns the amount of time that the client should wait before the next retry, if any.
    func shouldWaitBeforeRetry(retriesSoFar times: Int, headers: HTTPHeaders) -> Double? {
        switch self.retryPolicy?.backoff {
        case let .some(backoff):
            return backoff.waitTimeBeforeRetry(retriesSoFar: times, headers: headers)
        case .none:
            return nil
        }
    }
    
    public init(
        cachingBehavior: CachingBehavior = .disabled,
        requestTimeout: TimeAmount = .seconds(30),
        enableLoggingForRequests: Bool = false,
        retryPolicy: RetryPolicy? = .default
    ) {
        self.cachingBehavior = cachingBehavior
        self.requestTimeout = requestTimeout
        self.enableLoggingForRequests = enableLoggingForRequests
        self.retryPolicy = retryPolicy
    }
}

//MARK: - ClientCacheStorage
private final class ClientCacheStorage {
    
    /// [Token: ClientCache]
    private var storage = [String: ClientCache]()
    private let lock = NIOLock()
    
    private init() { }
    
    static let shared = ClientCacheStorage()
    
    func cache(for token: Secret) -> ClientCache {
        self.lock.lock()
        defer { self.lock.unlock() }
        let token = token._storage
        if let cache = self.storage[token] {
            return cache
        } else {
            let cache = ClientCache()
            self.storage[token] = cache
            return cache
        }
    }
}

//MARK: - ClientCache

/// This doesn't use the `Cache-Control` header because I couldn't find a 2xx response with a `Cache-Control` header returned by Discord.
private actor ClientCache {
    
    struct CacheableItem: Hashable {
        let identity: CacheableEndpointIdentity
        let queries: [(String, String?)]
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(identity.rawValue)
            for (key, value) in queries {
                hasher.combine(key)
                hasher.combine(value)
            }
        }
        
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.identity == rhs.identity &&
            lhs.queries.elementsEqual(rhs.queries, by: {
                $0.0 == $1.0 &&
                $0.1 == $1.1
            })
        }
    }
    
    /// [ID: ExpirationTime]
    private var timeTable = [CacheableItem: Double]()
    /// [ID: Response]
    private var storage = [CacheableItem: DiscordHTTPResponse]()
    
    init() {
        Task {
            await self.setupGarbageCollector()
        }
    }
    
    func add(response: DiscordHTTPResponse, item: CacheableItem, ttl: Double) {
        self.timeTable[item] = Date().timeIntervalSince1970 + ttl
        self.storage[item] = response
    }
    
    func get(item: CacheableItem) -> DiscordHTTPResponse? {
        if let time = self.timeTable[item] {
            if time > Date().timeIntervalSince1970 {
                return storage[item]
            } else {
                self.timeTable[item] = nil
                self.storage[item] = nil
                return nil
            }
        } else {
            return nil
        }
    }
    
    private func setupGarbageCollector() async {
        /// Quit in case of task cancelation.
        guard (try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)) != nil else { return }
        let now = Date().timeIntervalSince1970
        for (item, expirationDate) in self.timeTable {
            if expirationDate < now {
                self.timeTable[item] = nil
                self.storage[item] = nil
            }
        }
        await setupGarbageCollector()
    }
}

//MARK: Sendable
extension DefaultDiscordClient: Sendable { }
extension ClientConfiguration: Sendable { }
extension ClientConfiguration.CachingBehavior: Sendable { }
extension ClientConfiguration.RetryPolicy: Sendable { }
extension ClientConfiguration.RetryPolicy.Backoff: Sendable { }