/*
 * Onion Browser
 * Copyright (c) 2012-2018, Tigas Ventures, LLC (Mike Tigas)
 *
 * This file is part of Onion Browser. See LICENSE file for redistribution terms.
 */
// swiftlint:disable all
import Foundation
import Reachability
import Tor

enum OnionManagerErrors: Error {
    case missingCookieFile
}

protocol OnionManagerDelegate {
    func torConnProgress(_: Int)
    func torPortsOpened()
    func torConnFinished(configuration: URLSessionConfiguration)
    func torConnError()
}

public class OnionManager: NSObject {
    public enum TorState: Int {
        case none
        case started
        case connected
        case stopped
    }

    public static let shared = OnionManager()

    public static let CONTROL_ADDRESS = "127.0.0.1"
    public static let CONTROL_PORT: UInt16 = 39069

    public static func getCookie() throws -> Data {
        if let cookieURL = OnionManager.torBaseConf.dataDirectory?.appendingPathComponent("control_auth_cookie") {
            let cookie = try Data(contentsOf: cookieURL)

            TariLogger.tor("cookieURL=\(cookieURL)")
            TariLogger.tor("cookie=\(cookie)")

            return cookie
        } else {
            throw OnionManagerErrors.missingCookieFile
        }
    }

    private var reachability: Reachability?
    private var isListeningForNetworkChanges = false
    
    // Show Tor log in iOS' app log.
    private static let isTorLogging = true
    
    private static let torBaseConf: TorConfiguration = {
        // Store data in <appdir>/Library/Caches/tor (Library/Caches/ is for things that can persist between
        // launches -- which we'd like so we keep descriptors & etc -- but don't need to be backed up because
        // they can be regenerated by the app)
        let dataDir =  TariSettings.shared.storageDirectory.appendingPathComponent("tor", isDirectory: true)

        TariLogger.tor("dataDir=\(dataDir)")

        // Create tor data directory if it does not yet exist
        do {
            try FileManager.default.createDirectory(atPath: dataDir.path, withIntermediateDirectories: true, attributes: nil)
        } catch let error as NSError {
            TariLogger.tor("Failed to create tor directory", error: error)
        }
        // Create tor v3 auth directory if it does not yet exist
        let authDir = URL(fileURLWithPath: dataDir.path, isDirectory: true).appendingPathComponent("auth", isDirectory: true)
        do {
            try FileManager.default.createDirectory(atPath: authDir.path, withIntermediateDirectories: true, attributes: nil)
        } catch let error as NSError {
            TariLogger.tor("Failed to create tor auth directory", error: error)
        }

        // Configure tor and return the configuration object
        let configuration = TorConfiguration()
        configuration.cookieAuthentication = true
        configuration.dataDirectory = dataDir

        #if DEBUG
        let log_loc = "notice stdout"
        #else
        let log_loc = "notice file /dev/null"
        #endif

        var config_args = [
            "--allow-missing-torrc",
            "--ignore-missing-torrc",
            "--clientonly", "1",
            "--socksport", "39059",
            "--controlport", "\(OnionManager.CONTROL_ADDRESS):\(OnionManager.CONTROL_PORT)",
            "--log", log_loc,
            "--clientuseipv6", "1",
            "--ClientTransportPlugin", "obfs4 socks5 127.0.0.1:47351",
            "--ClientTransportPlugin", "meek_lite socks5 127.0.0.1:47352",
            "--ClientOnionAuthDir", authDir.path
        ]

        configuration.arguments = config_args
        return configuration
    }()

    // MARK: - OnionManager instance
    private var torController: TorController?
    var delegate: OnionManagerDelegate?

    private var torThread: TorThread?

    public var state: TorState = .none
        
    private var initRetry: DispatchWorkItem?
    private var failGuard: DispatchWorkItem?

    private var customBridges: [String]?
    private var needsReconfiguration: Bool = false

    @objc func networkChange() {
        TariLogger.tor("Network change detected")
        var confs: [Dictionary<String, String>] = []

        confs.append(["key": "ClientPreferIPv6DirPort", "value": "auto"])
        confs.append(["key": "ClientPreferIPv6ORPort", "value": "auto"])
        confs.append(["key": "clientuseipv4", "value": "1"])

        torController?.setConfs(confs, completion: { [weak self] _, _ in
            guard let self = self else { return }
            self.torReconnect()
        })
    }

    func torReconnect() {
        guard self.torThread != nil else {
            TariLogger.tor("No tor thread, aborting reconnect")
            return
        }
        
        TariLogger.tor("Tor reconnecting...")
        
        torController?.resetConnection({ (complete) in
            TariLogger.tor("Tor reconnected")
        })
    }
    
    func reconnectOnNetworkChanges() {
        guard !isListeningForNetworkChanges else {
            return //Don't want to add 2 observers
        }
        
        do {
            reachability = try Reachability()
            try reachability?.startNotifier()
            NotificationCenter.default.addObserver(self, selector: #selector(self.networkChange), name: NSNotification.Name.reachabilityChanged, object: nil)
            isListeningForNetworkChanges = true
            TariLogger.tor("Listening for reachability changes to reconnect tor")
        } catch {
            TariLogger.tor("Failed to init Reachability", error: error)
        }
    }

    func startTor(delegate: OnionManagerDelegate) {
        self.delegate = delegate
        cancelInitRetry()
        cancelFailGuard()
        
        state = .started

        if (self.torController == nil) {
            self.torController = TorController(socketHost: OnionManager.CONTROL_ADDRESS, port: OnionManager.CONTROL_PORT)
        }

        if ((self.torThread == nil) || (self.torThread?.isCancelled ?? true)) {
            self.torThread = nil

            let torConf = OnionManager.torBaseConf

            let args = torConf.arguments

            TariLogger.tor(String(describing: args))

            torConf.arguments = args
            self.torThread = TorThread(configuration: torConf)
            needsReconfiguration = false

            self.torThread?.start()

            TariLogger.tor("Starting Tor")
        } else {
            if needsReconfiguration {
                // Not using bridges, so null out the "Bridge" conf
                torController?.setConfForKey("usebridges", withValue: "0", completion: { _, _ in
                })
                torController?.resetConf(forKey: "bridge", completion: { _, _ in
                })
            }
        }

        // Wait long enough for tor itself to have started. It's OK to wait for this
        // because Tor is already trying to connect; this is just the part that polls for
        // progress.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: { [weak self] in
            guard let self = self else { return }

//            if OnionManager.isTorLogging {
//                TORInstallTorLoggingCallback { severity, msg in
//                    var type = ""
//                    switch severity {
//                    case .debug:
//                        type = "debug"
//                    case .error:
//                        type = "error"
//                    case .fault:
//                        type = "fault"
//                    case .info:
//                        type = "info"
//                    default:
//                        type = "default"
//                    }
//
//                    TariLogger.tor("[Tor \(type)] \(String(cString: msg))")
//                }
//
//                TORInstallEventLoggingCallback { severity, msg in
//                    //Logic here is duplicated from above. Moving to shared funcrtion causes error:
//                    //"a C function pointer cannot be formed from a closure that captures context"
//                    var type = ""
//                    switch severity {
//                    case .debug:
//                        return // Ignore libevent debug messages. Just too many of typically no importance.
//                    case .error:
//                        type = "error"
//                    case .fault:
//                        type = "fault"
//                    case .info:
//                        type = "info"
//                    default:
//                        type = "default"
//                    }
//
//                    TariLogger.tor("[Tor libevent \(type)] \(String(cString: msg))")
//                }
//            }

            if !(self.torController?.isConnected ?? false) {
                do {
                    try self.torController?.connect()
                } catch {
                    TariLogger.tor("Tor controller connection", error: error)
                }
            }

            do {
                let cookie = try OnionManager.getCookie()

                self.torController?.authenticate(with: cookie, completion: { [weak self] success, error in
                    guard let self = self else { return }

                    if success {
                        self.delegate?.torPortsOpened()
                        TariLogger.tor("Tor cookie auth success and ports opened")

                        var completeObserver: Any?
                                                
                        completeObserver = self.torController?.addObserver(forCircuitEstablished: { established in
                            if established || self.torController?.isConnected ?? false {
                                self.state = .connected
                                self.torController?.removeObserver(completeObserver)
                                self.cancelInitRetry()
                                self.cancelFailGuard()
                                self.reconnectOnNetworkChanges()

                                TariLogger.tor("Tor connection established")

                                self.torController?.getSessionConfiguration({ [weak self] configuration in
                                    guard let self = self else { return }
                                    //TODO once below issue is resolved we can update to < 400.6.3 then the session config will not be nil
                                    //https://github.com/iCepa/Tor.framework/issues/60
                                    self.delegate?.torConnFinished(configuration: configuration ?? URLSessionConfiguration.default)
                                })
                            } else {
                                TariLogger.tor("Tor connection not established")
                            }
                        }) // torController.addObserver
                        var progressObserver: Any?
                        
                        progressObserver = self.torController?.addObserver(forStatusEvents: { [weak self]
                            (type: String, _: String, action: String, arguments: [String: String]?) -> Bool in
                            guard let self = self else { return false }

                            if type == "STATUS_CLIENT" && action == "BOOTSTRAP" {
                                guard let args = arguments else { return false }
                                guard let progressArg = args["PROGRESS"] else { return false }
                                guard let progress = Int(progressArg) else { return false }

                                TariLogger.tor("Tor bootstrap progress: \(progress)")

                                self.delegate?.torConnProgress(progress)
                                
                                if progress >= 100 {
                                    self.torController?.removeObserver(progressObserver)
                                }

                                return true
                            }

                            return false
                        }) // torController.addObserver
                    } // if success (authenticate)
                    else {
                        TariLogger.tor("Didn't connect to control port.", error: error)
                    }
                }) // controller authenticate
            } catch {
                TariLogger.tor("Tor auth error", error: error)
            }
        }) //delay
        initRetry = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            TariLogger.tor("Triggering Tor connection retry.")

            self.torController?.setConfForKey("DisableNetwork", withValue: "1", completion: { _, _ in
            })

            self.torController?.setConfForKey("DisableNetwork", withValue: "0", completion: { _, _ in
            })

            self.failGuard = DispatchWorkItem {
                if self.state != .connected {
                    self.delegate?.torConnError()
                }
            }

            // Show error to user, when, after 90 seconds (30 sec + one retry of 60 sec), Tor has still not started.
            guard let executeFailGuard = self.failGuard else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: executeFailGuard)
        }

        // On first load: If Tor hasn't finished bootstrap in 30 seconds,
        // HUP tor once in case we have partially bootstrapped but got stuck.
        guard let executeRetry = initRetry else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: executeRetry)
    }// startTor
    /**
     Experimental Tor shutdown.
     */
    @objc func stopTor() {
        TariLogger.tor("Stopping tor")
        
        // under the hood, TORController will SIGNAL SHUTDOWN and set it's channel to nil, so
        // we actually rely on that to stop tor and reset the state of torController. (we can
        // SIGNAL SHUTDOWN here, but we can't reset the torController "isConnected" state.)
        
        //torController?.removeObserver(self) //Causes EXC_BAD_ACCESS (code=257). Setting the controller to nil should acomplish the same.
        torController?.disconnect()

        torController = nil

        // More cleanup
        torThread?.cancel()
        state = .stopped
    }

    /**
     Cancel the connection retry
     */
    private func cancelInitRetry() {
        initRetry?.cancel()
        initRetry = nil
    }

    /**
     Cancel the fail guard.
     */
    private func cancelFailGuard() {
        failGuard?.cancel()
        failGuard = nil
    }
}
