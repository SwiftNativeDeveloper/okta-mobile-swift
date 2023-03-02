//
// Copyright (c) 2023-Present, Okta, Inc. and/or its affiliates. All rights reserved.
// The Okta software accompanied by this notice is provided pursuant to the Apache License, Version 2.0 (the "License.")
//
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0.
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//
// See the License for the specific language governing permissions and limitations under the License.
//

import Foundation
import AuthFoundation

public protocol DirectAuthenticationFlowDelegate: AuthenticationDelegate {
    /// Sent when an authentication session receives a token.
    func authentication<Flow>(flow: Flow, received state: DirectAuthenticationFlow.Status)
}

protocol DirectAuthTokenRequest {
    
}

public enum DirectAuthenticationFlowError: Error {
    case missingArguments(_ names: [String])
    case currentStatusMissing
}

public final class DirectAuthenticationFlow: AuthenticationFlow {
    public enum PrimaryFactor {
        case password(String)
        case otp(code: String)
        case oob(channel: Channel)
    }
    
    public enum SecondaryFactor {
        case otp(code: String)
        case oob(channel: Channel)
    }
    
    public enum Channel: String, Codable {
        case push
    }
    
    public struct MFAContext {
        public let supportedChallengeTypes: [GrantType]?
        let mfaToken: String
    }
    
    public enum Status {
        case success(_ token: Token)
        case failure(_ error: Error)
        
        // Only needed for 2FA
        case mfaRequired(_ context: MFAContext)
    }
    
    /// The OAuth2Client this authentication flow will use.
    public let client: OAuth2Client
    
    public let supportedGrantTypes: [GrantType]
    
    /// Indicates whether or not this flow is currently in the process of authenticating a user.
    public private(set) var isAuthenticating: Bool = false {
        didSet {
            guard oldValue != isAuthenticating else {
                return
            }
            
            if isAuthenticating {
                delegateCollection.invoke { $0.authenticationStarted(flow: self) }
            } else {
                delegateCollection.invoke { $0.authenticationFinished(flow: self) }
            }
        }
    }
    
    /// Convenience initializer to construct an authentication flow from variables.
    /// - Parameters:
    ///   - issuer: The issuer URL.
    ///   - clientId: The client ID
    ///   - scopes: The scopes to request
    ///   - additionalParameters: Additional parameters to supply to the server.
    public convenience init(issuer: URL,
                            clientId: String,
                            scopes: String,
                            supportedGrants grantTypes: [GrantType] = .directAuth)
    {
        self.init(supportedGrants: grantTypes,
                  client: .init(baseURL: issuer,
                                clientId: clientId,
                                scopes: scopes))
    }
    
    /// Initializer to construct an authentication flow from a pre-defined configuration and client.
    /// - Parameters:
    ///   - configuration: The configuration to use for this authentication flow.
    ///   - client: The `OAuth2Client` to use with this flow.
    public init(supportedGrants grantTypes: [GrantType] = .directAuth,
                client: OAuth2Client)
    {
        // Ensure this SDK's static version is included in the user agent.
        SDKVersion.register(sdk: Version)
        
        self.client = client
        self.supportedGrantTypes = grantTypes
        
        client.add(delegate: self)
    }
    
    /// Initializer that uses the configuration defined within the application's `Okta.plist` file.
    public convenience init() throws {
        try self.init(try .init())
    }
    
    /// Initializer that uses the configuration defined within the given file URL.
    /// - Parameter fileURL: File URL to a `plist` containing client configuration.
    public convenience init(plist fileURL: URL) throws {
        try self.init(try .init(plist: fileURL))
    }
    
    private convenience init(_ config: OAuth2Client.PropertyListConfiguration) throws {
        let supportedGrantTypes: [GrantType]
        if let supportedGrants = config.additionalParameters?["supportedGrants"] {
            supportedGrantTypes = try .from(string: supportedGrants)
        } else {
            supportedGrantTypes = .directAuth
        }
        
        self.init(issuer: config.issuer,
                  clientId: config.clientId,
                  scopes: config.scopes,
                  supportedGrants: supportedGrantTypes)
    }
    
    var stepHandler: (any StepHandler)?
    
    public func start(_ loginHint: String,
                      with factor: PrimaryFactor,
                      completion: @escaping (Result<Status, OAuth2Error>) -> Void)
    {
        runStep(loginHint: loginHint, with: factor, completion: completion)
    }
    
    public func resume(_ status: DirectAuthenticationFlow.Status,
                       with factor: SecondaryFactor,
                       completion: @escaping (Result<Status, OAuth2Error>) -> Void)
    {
        runStep(currentStatus: status, with: factor, completion: completion)
    }
    
    private func runStep<Factor: AuthenticationFactor>(loginHint: String? = nil,
                                                       currentStatus: Status? = nil,
                                                       with factor: Factor,
                                                       completion: @escaping (Result<DirectAuthenticationFlow.Status, OAuth2Error>) -> Void)
    {
        isAuthenticating = true
        
        client.openIdConfiguration { result in
            switch result {
            case .success(let configuration):
                do {
                    self.stepHandler = try factor.stepHandler(flow: self,
                                                              openIdConfiguration: configuration,
                                                              loginHint: loginHint,
                                                              currentStatus: currentStatus,
                                                              factor: factor)
                    self.stepHandler?.process { result in
                        self.stepHandler = nil
                        if case let .success(status) = result,
                            case .success(_) = status
                        {
                            self.reset()
                        }
                        completion(result)
                    }
                } catch {
                    self.send(error: .error(error), completion: completion)
                }
                
            case .failure(let error):
                self.send(error: error, completion: completion)
            }
        }
    }
    
    public func reset() {
        isAuthenticating = false
    }

    // MARK: Private properties / methods
    public let delegateCollection = DelegateCollection<DirectAuthenticationFlowDelegate>()
}

#if swift(>=5.5.1)
@available(iOS 15.0, tvOS 15.0, macOS 12.0, watchOS 8, *)
extension DirectAuthenticationFlow {
    public func start(_ loginHint: String, with factor: PrimaryFactor) async throws -> DirectAuthenticationFlow.Status {
        try await withCheckedThrowingContinuation { continuation in
            start(loginHint, with: factor) { result in
                continuation.resume(with: result)
            }
        }
    }
    
    public func resume(_ status: DirectAuthenticationFlow.Status, with factor: SecondaryFactor) async throws -> DirectAuthenticationFlow.Status {
        try await withCheckedThrowingContinuation { continuation in
            resume(status, with: factor) { result in
                continuation.resume(with: result)
            }
        }
    }
}
#endif

extension DirectAuthenticationFlow: UsesDelegateCollection {
    public typealias Delegate = DirectAuthenticationFlowDelegate
}

extension DirectAuthenticationFlow: OAuth2ClientDelegate {
    
}

extension OAuth2Client {
    public func directAuthenticationFlow(supportedGrants grantTypes: [GrantType] = .directAuth) -> DirectAuthenticationFlow
    {
        DirectAuthenticationFlow(supportedGrants: grantTypes,
                                 client: self)
    }
}
