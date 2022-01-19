//
// Copyright (c) 2022-Present, Okta, Inc. and/or its affiliates. All rights reserved.
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

class UserCoordinator {
    var userDataSource: UserDataSource {
        didSet {
            userDataSource.delegate = self
        }
    }
    
    var tokenStorage: TokenStorage {
        didSet {
            tokenStorage.delegate = self
            
            if let defaultToken = tokenStorage.defaultToken {
                _default = userDataSource.user(for: defaultToken)
            } else {
                _default = nil
            }
        }
    }
        
    private var _default: User?
    var `default`: User? {
        get { _default }
        set { tokenStorage.defaultToken = newValue?.token }
    }
    
    public var allUsers: [User] {
        tokenStorage.allTokens.map { userDataSource.user(for: $0) }
    }

    func `for`(token: Token) -> User {
        try? tokenStorage.add(token: token)
        return userDataSource.user(for: token)
    }
    
    init(tokenStorage: TokenStorage = DefaultTokenStorage(),
         userDataSource: UserDataSource = DefaultUserDataSource())
    {
        self.userDataSource = userDataSource
        self.tokenStorage = tokenStorage

        self.userDataSource.delegate = self
        self.tokenStorage.delegate = self

        if let defaultToken = tokenStorage.defaultToken {
            _default = userDataSource.user(for: defaultToken)
        }
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(received(notification:)),
                                               name: .oauth2ClientCreated,
                                               object: nil)
    }
    
    @objc private func received(notification: Notification) {
        switch notification.name {
        case .oauth2ClientCreated:
            guard let client = notification.object as? OAuth2Client else { break }
            client.add(delegate: self)
        default: break
        }
    }
}

extension UserCoordinator: OAuth2ClientDelegate {
    func api(client: APIClient, didSend request: URLRequest, received error: APIClientError) {
        print("Error happened: \(error)")
    }

    func oauth(client: OAuth2Client, didRefresh token: Token, replacedWith newToken: Token?) {
        guard let newToken = newToken else {
            return
        }

        do {
            try tokenStorage.replace(token: token, with: newToken)
        } catch {
            print("Error happened refreshing: \(error)")
        }
    }
}

extension UserCoordinator: TokenStorageDelegate {
    func token(storage: TokenStorage, defaultChanged token: Token?) {
        guard _default?.token != token else { return }

        if let token = token {
            _default = userDataSource.user(for: token)
        } else {
            _default = nil
        }

        NotificationCenter.default.post(name: .defaultUserChanged,
                                        object: _default)
    }
    
    func token(storage: TokenStorage, added token: Token?) {
    }
    
    func token(storage: TokenStorage, removed token: Token?) {
    }
    
    func token(storage: TokenStorage, replaced oldToken: Token, with newToken: Token) {
        guard userDataSource.hasUser(for: oldToken) else { return }
        
        // Doing nothing with this, for now...
    }
    
}

extension UserCoordinator: UserDataSourceDelegate {
    func user(dataSource: UserDataSource, created user: User) {
        user.coordinator = self
        
        NotificationCenter.default.post(name: .userCreated, object: user)
    }
    
    func user(dataSource: UserDataSource, removed user: User) {
        user.coordinator = nil

        NotificationCenter.default.post(name: .userRemoved, object: user)
    }
    
    func user(dataSource: UserDataSource, updated user: User) {
    }
}
