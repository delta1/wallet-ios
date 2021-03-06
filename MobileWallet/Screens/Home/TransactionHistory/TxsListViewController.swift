//  TxsListViewController.swift

/*
	Package MobileWallet
	Created by S.Shovkoplyas on 28.09.2020
	Using Swift 5.0
	Running on macOS 10.15

	Copyright 2019 The Tari Project

	Redistribution and use in source and binary forms, with or
	without modification, are permitted provided that the
	following conditions are met:

	1. Redistributions of source code must retain the above copyright notice,
	this list of conditions and the following disclaimer.

	2. Redistributions in binary form must reproduce the above
	copyright notice, this list of conditions and the following disclaimer in the
	documentation and/or other materials provided with the distribution.

	3. Neither the name of the copyright holder nor the names of
	its contributors may be used to endorse or promote products
	derived from this software without specific prior written permission.

	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
	CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
	INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
	OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
	DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
	CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
	SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
	NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
	LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
	HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
	CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
	OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
	SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

import UIKit
import Lottie

protocol TxsTableViewDelegate: class {
    func onTxSelect(_: Any)
    func onScrollTopHit(_: Bool)
}

class TxsListViewController: UIViewController {
    weak var actionDelegate: TxsTableViewDelegate?

    let tableView = UITableView(frame: .zero, style: .plain)
    private let animatedRefresher = AnimatedRefreshingView()

    private var txModels = [TxTableViewModel]()

    private let txDataUpdateQueue = DispatchQueue(
        label: "com.tari.wallet.tx_list.data_update_queue",
        attributes: .concurrent
    )

    private var hasReceivedTxWhileUpdating = false
    private var hasMinedTxWhileUpdating = false
    private var hasBroadcastTxWhileUpdating = false
    private var hasCancelledTxWhileUpdating = false

    private var baseNodeSyncRequestId: UInt64 = 0

    enum BackgroundViewType: Equatable {
        case none
        case intro
        case empty
    }

    var backgroundType: BackgroundViewType = .none {
        didSet {
            if oldValue == backgroundType { return }
            removeBackgroundView { [weak self] in
                guard let `self` = self else { return }
                switch self.backgroundType {
                case .empty:
                    self.setEmptyView()
                case .intro:
                    self.setIntroView()
                default: break
                }
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewSetup()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.0 + CATransaction.animationDuration()
        ) {
            self.registerEvents()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if backgroundType != .intro {
            safeRefreshTable()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if tableView.refreshControl?.isRefreshing == false {
            animatedRefresher.stateType = .none
        }
    }

    func safeRefreshTable(_ completion:(() -> Void)? = nil) {
         TariLib.shared.waitIfWalletIsRestarting {
             [weak self] (success) in
             if success == true {
                 self?.txDataUpdateQueue.async(flags: .barrier) {
                    if self?.fetchTx() == true {
                        DispatchQueue.main.async {
                            [weak self] in
                            self?.tableView.reloadData()
                        }
                    }
                    DispatchQueue.main.async { completion?() }
                 }
             } else {
                 completion?()
             }
         }
     }

    @discardableResult
    private func fetchTx() -> Bool {
        //All completed/cancelled txs
        let (allTxs, allTxsError) = TariLib.shared.tariWallet!.allTxs

        guard allTxsError == nil else {
            DispatchQueue.main.async {
                UserFeedback.shared.error(
                    title: localized("tx_list.error.grouped_transactions.title"),
                    description: localized("tx_list.error.grouped_transactions.descritpion"),
                    error: allTxsError
                )
            }
            return false
        }

        var newTxFetched = false
        for (i, tx) in allTxs.enumerated() {
            if let model = txModels.first(where: { $0.id == tx.id.0 }) {
                model.update(tx: tx)
            } else {
                newTxFetched = true
                let model = TxTableViewModel(tx: tx)
                if !txModels.contains(model) && i <= txModels.count {
                    txModels.insert(model, at: i)
                }
            }
        }
        return newTxFetched
    }
}

// MARK: AnimatedRefreshingView behavior
extension TxsListViewController {

    private func beginRefreshing() {
        if animatedRefresher.stateType != .none { return }
        animatedRefresher.stateType = .updateData
        animatedRefresher.updateState(.loading, animated: false)
        animatedRefresher.animateIn()

        do {
            if let wallet = TariLib.shared.tariWallet {
                //If we sync before tor is connected it will fail. A base node sync is triggered when tor does connect.
                if TariLib.shared.isTorConnected {
                    baseNodeSyncRequestId = try wallet.syncBaseNode()
                    hasReceivedTxWhileUpdating = false
                    hasBroadcastTxWhileUpdating = false
                    hasMinedTxWhileUpdating = false
                    hasCancelledTxWhileUpdating = false
                }
            }
        } catch {
            UserFeedback.shared.error(
                title: localized("tx_list.error.sync_to_base_node.title"),
                description: localized("tx_list.error.sync_to_base_node.description"),
                error: error
            )
        }
    }

    private func endRefreshingWithSuccess() {
        if animatedRefresher.stateType != .updateData { return }
        // play animations

        safeRefreshTable {
            [weak self] in
            self?.animatedRefresher.animateOut {
                [weak self] in
                self?.animatedRefresher.stateType = .none
                self?.hasReceivedTxWhileUpdating = false
                self?.hasMinedTxWhileUpdating = false
                self?.hasBroadcastTxWhileUpdating = false
                self?.hasCancelledTxWhileUpdating = false

                self?.tableView.endRefreshing()
            }
        }
    }

}

// MARK: UITableViewDelegate & UITableViewDataSource
extension TxsListViewController: UITableViewDelegate, UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        if backgroundType != .intro {
            if txModels.count == 0 {
                backgroundType = .empty
            } else {
                backgroundType = .none
            }
        }

        return 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return txModels.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: TxTableViewCell

        cell = tableView.dequeueReusableCell(
            withIdentifier: String(describing: TxTableViewCell.self),
            for: indexPath
        ) as! TxTableViewCell
        cell.configure(with: txModels[indexPath.row])
        txModels[indexPath.row].downloadGif()

        cell.updateCell = {
            DispatchQueue.main.async {
                tableView.reloadRows(at: [indexPath], with: .fade)
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        actionDelegate?.onTxSelect(txModels[indexPath.row].tx)
    }
}

// MARK: UITableViewDataSourcePrefetching
extension TxsListViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        indexPaths.forEach { (indexPath) in
            txModels[indexPath.row].downloadGif()
        }
    }
}

// MARK: UIScrollViewDelegate
extension TxsListViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.contentOffset.y <= 0 {
            actionDelegate?.onScrollTopHit(true)
        } else {
            actionDelegate?.onScrollTopHit(false)
        }
    }
}

// MARK: TariBus events observation
extension TxsListViewController {

    @objc private func registerEvents() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registerEvents),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(unregisterEvents),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        // Event for table refreshing
        TariEventBus.onMainThread(self, eventType: .txListUpdate) {
            [weak self] (_) in
            guard let self = self else { return }
            if self.animatedRefresher.stateType != .updateData {
                self.safeRefreshTable()
            }
        }

        TariEventBus.onBackgroundThread(self, eventType: .receivedTx) {
            [weak self] (_) in
            guard let self = self else { return }
            if self.animatedRefresher.stateType == .updateData {
                self.hasReceivedTxWhileUpdating = true
            }
        }

        TariEventBus.onBackgroundThread(self, eventType: .txBroadcast) {
            [weak self] (_) in
            guard let self = self else { return }
            if self.animatedRefresher.stateType == .updateData {
                self.hasBroadcastTxWhileUpdating = true
            }
        }

        TariEventBus.onBackgroundThread(self, eventType: .txMined) {
            [weak self] (_) in
            guard let self = self else { return }
            if self.animatedRefresher.stateType == .updateData {
                self.hasMinedTxWhileUpdating = true
            }
        }

        TariEventBus.onBackgroundThread(self, eventType: .txCancellation) {
            [weak self] (_) in
            guard let self = self else { return }
            if self.animatedRefresher.stateType == .updateData {
                self.hasCancelledTxWhileUpdating = true
            }
        }

        TariEventBus.onMainThread(self, eventType: .baseNodeSyncComplete) {
            [weak self]
            (result) in
            guard let self = self else { return }
            if let result: [String: Any] = result?.object as? [String: Any] {
                let success = (result["success"] as? Bool) ?? false
                let requestId = result["requestId"] as? UInt64 ?? UInt64(0)
                if success && self.baseNodeSyncRequestId == requestId {
                    if self.animatedRefresher.stateType != .none {
                        self.animatedRefresher.playUpdateSequence(
                            hasReceivedTx: self.hasReceivedTxWhileUpdating,
                            hasMinedTx: self.hasMinedTxWhileUpdating,
                            hasBroadcastTx: self.hasBroadcastTxWhileUpdating,
                            hasCancelledTx: self.hasCancelledTxWhileUpdating
                        ) {
                            [weak self] in
                            self?.endRefreshingWithSuccess()
                        }
                    }
                    NotificationManager.shared.cancelAllFutureReminderNotifications()
                } else {
                    self.animatedRefresher.animateOut { [weak self] in
                        self?.animatedRefresher.stateType = .none
                        self?.tableView.endRefreshing()
                    }
                }
            }
        }
    }

    @objc private func unregisterEvents() {
        animatedRefresher.animateOut()
        tableView.endRefreshing()
        animatedRefresher.stateType = .none
        TariEventBus.unregister(self)
    }
}

// MARK: setup UI
extension TxsListViewController {
    private func viewSetup() {
        if backgroundType == .intro {
            setIntroView()
        }

        setupTableView()
        setupRefreshControl()
    }

    private func setupTableView() {
        view.addSubview(tableView)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
        tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
        tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true

        tableView.register(
            TxTableViewCell.self,
            forCellReuseIdentifier: String(describing: TxTableViewCell.self)
        )
        tableView.estimatedRowHeight = 300
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never

        tableView.prefetchDataSource = self
        tableView.delegate = self
        tableView.dataSource = self

        tableView.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)

        view.backgroundColor = Theme.shared.colors.txTableBackground
    }

    private func setEmptyView() {
        let emptyView = UIView(frame: CGRect(x: tableView.center.x, y: tableView.center.y, width: tableView.bounds.size.width, height: tableView.bounds.size.height))
        let messageLabel = UILabel()
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addSubview(messageLabel)

        messageLabel.numberOfLines = 0
        messageLabel.text = localized("tx_list.empty")
        messageLabel.textAlignment = .center
        messageLabel.textColor = Theme.shared.colors.txSmallSubheadingLabel
        messageLabel.font = Theme.shared.fonts.txListEmptyMessageLabel

        messageLabel.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor, constant: -20).isActive = true
        messageLabel.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor).isActive = true
        messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: messageLabel.font.pointSize * 1.2).isActive = true

        tableView.backgroundView = emptyView
    }

    private func removeBackgroundView(completion:(() -> Void)? = nil) {
        if tableView.backgroundView == nil {
            completion?()
            return
        }

        UIView.animate(
            withDuration: CATransaction.animationDuration(),
            animations: {
                [weak self] in
                self?.tableView.backgroundView?.alpha = 0.0
            }
        ) {
            [weak self] (_) in
            self?.tableView.backgroundView = nil
            completion?()
        }
    }

    private func setIntroView() {
        let introView = UIView(
            frame: CGRect(
                x: tableView.center.x,
                y: tableView.center.y,
                width: tableView.bounds.size.width,
                height: tableView.bounds.size.height
            )
        )

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        introView.addSubview(titleLabel)

        let titleText = localized("tx_list.intro")

        let attributedTitle = NSMutableAttributedString(
            string: titleText,
            attributes: [NSAttributedString.Key.font: Theme.shared.fonts.introTitle]
        )

        titleLabel.attributedText = attributedTitle
        titleLabel.textAlignment = .center
        titleLabel.centerYAnchor.constraint(
            equalTo: introView.centerYAnchor
        ).isActive = true
        titleLabel.centerXAnchor.constraint(
            equalTo: introView.centerXAnchor
        ).isActive = true

        titleLabel.heightAnchor.constraint(
            greaterThanOrEqualToConstant: titleLabel.font.pointSize * 1.2
        ).isActive = true

        let messageLabel = UILabel()
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        introView.addSubview(messageLabel)

        messageLabel.text = localized("tx_list.intro_message")
        messageLabel.textAlignment = .center
        messageLabel.textColor = Theme.shared.colors.txSmallSubheadingLabel
        messageLabel.font = Theme.shared.fonts.txListEmptyMessageLabel

        messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 15).isActive = true
        messageLabel.centerXAnchor.constraint(equalTo: introView.centerXAnchor).isActive = true
        messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: messageLabel.font.pointSize * 1.2).isActive = true

        let waveAnimation = AnimationView()
        waveAnimation.backgroundBehavior = .pauseAndRestore
        waveAnimation.animation = Animation.named(.waveEmoji)
        introView.addSubview(waveAnimation)

        waveAnimation.translatesAutoresizingMaskIntoConstraints = false
        waveAnimation.widthAnchor.constraint(equalToConstant: 70).isActive = true
        waveAnimation.heightAnchor.constraint(equalToConstant: 70).isActive = true
        waveAnimation.centerXAnchor.constraint(equalTo: introView.centerXAnchor).isActive = true
        waveAnimation.bottomAnchor.constraint(equalTo: titleLabel.topAnchor).isActive = true

        waveAnimation.play(
            fromProgress: 0,
            toProgress: 1,
            loopMode: .playOnce,
            completion: {
                [weak self] _ in
                self?.backgroundType = .none
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + CATransaction.animationDuration()
                ) {
                    [weak self] in
                    self?.tableView.reloadData()
                }
            }
        )

        tableView.backgroundView = introView
    }

    private func setupRefreshControl() {
        let refreshControl = UIRefreshControl()
        refreshControl.clipsToBounds = true
        refreshControl.backgroundColor = .clear
        refreshControl.tintColor = .clear
        refreshControl.addTarget(
            self,
            action: #selector(self.refresh(_:)),
            for: .valueChanged
        )
        refreshControl.subviews.first?.alpha = 0

        tableView.refreshControl = refreshControl
        view.addSubview(animatedRefresher)
        tableView.bringSubviewToFront(animatedRefresher)

        animatedRefresher.translatesAutoresizingMaskIntoConstraints = false
        animatedRefresher.topAnchor.constraint(
            equalTo: view.topAnchor,
            constant: 5
        ).isActive = true

        let leading = animatedRefresher.leadingAnchor.constraint(
            equalTo: refreshControl.leadingAnchor,
            constant: Theme.shared.sizes.appSidePadding
        )
        leading.isActive = true
        leading.priority = .defaultHigh

        let trailing = animatedRefresher.trailingAnchor.constraint(
            equalTo: refreshControl.trailingAnchor,
            constant: -Theme.shared.sizes.appSidePadding
        )
        trailing.isActive = true
        trailing.priority = .defaultHigh

        animatedRefresher.heightAnchor.constraint(equalToConstant: 48).isActive = true
        animatedRefresher.setupView(.loading)
    }

    @objc private func refresh(_ sender: AnyObject) {
        beginRefreshing()
    }
}
