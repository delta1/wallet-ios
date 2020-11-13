//  Backup.swift

/*
	Package MobileWallet
	Created by S.Shovkoplyas on 09.07.2020
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

import Foundation

class Backup {

    let url: URL
    let folderPath: String
    let dateCreation: Date
    let dateCreationString: String
    let isEncrypted: Bool

    var isValid: Bool {
        return !ICloudBackup.shared.inProgress && !ICloudBackup.shared.isLastBackupFailed && !BackupScheduler.shared.isBackupScheduled
    }

    init(url: URL) throws {
        if try !url.checkResourceIsReachable() {
            throw ICloudBackupError.backupUrlNotValid
        }

        self.url = url
        folderPath = url.deletingLastPathComponent().path
        isEncrypted = !url.absoluteString.contains(".zip")

        guard let date = try url.resourceValues(forKeys: [.creationDateKey]).allValues.first?.value as? Date else {
            throw ICloudBackupError.unableToDetermineDateOfBackup
        }

        dateCreation = date
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM dd yyy 'at' h:mm a"
        dateFormatter.timeZone = .current
        dateCreationString = dateFormatter.string(from: date)
    }

}
