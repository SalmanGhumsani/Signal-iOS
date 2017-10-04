//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

import Foundation

class GifPickerCell: UICollectionViewCell {
    let TAG = "[GifPickerCell]"

    // MARK: Properties

    var imageInfo: GiphyImageInfo? {
        didSet {
            AssertIsOnMainThread()

            ensureCellState()
        }
    }

    // Loading and playing GIFs is quite expensive (network, memory, cpu). 
    // Here's a bit of logic to not preload offscreen cells that are prefetched.
    var isCellVisible = false {
        didSet {
            AssertIsOnMainThread()

            ensureCellState()
        }
    }

    // We do "progressive" loading by loading stills (jpg or gif) and "animated" gifs.
    // This is critical on cellular connections.
    var stillAssetRequest: GiphyAssetRequest?
    var stillAsset: GiphyAsset?
    var animatedAssetRequest: GiphyAssetRequest?
    var animatedAsset: GiphyAsset?
    var imageView: YYAnimatedImageView?

    // MARK: Initializers

    deinit {
        stillAssetRequest?.cancel()
        animatedAssetRequest?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()

        imageInfo = nil
        isCellVisible = false
        stillAsset = nil
        stillAssetRequest?.cancel()
        stillAssetRequest = nil
        animatedAsset = nil
        animatedAssetRequest?.cancel()
        animatedAssetRequest = nil
        imageView?.removeFromSuperview()
        imageView = nil
    }

    private func clearStillAssetRequest() {
        stillAssetRequest?.cancel()
        stillAssetRequest = nil
    }

    private func clearAnimatedAssetRequest() {
        animatedAssetRequest?.cancel()
        animatedAssetRequest = nil
    }

    private func clearAssetRequests() {
        clearStillAssetRequest()
        clearAnimatedAssetRequest()
    }

    public func ensureCellState() {
        ensureLoadState()
        ensureViewState()
    }

    public func ensureLoadState() {
        guard isCellVisible else {
            // Don't load if cell is not visible.
            clearAssetRequests()
            return
        }
        guard let imageInfo = imageInfo else {
            // Don't load if cell is not configured.
            clearAssetRequests()
            return
        }
        guard self.animatedAsset == nil else {
            // Don't load if cell is already loaded.
            clearAssetRequests()
            return
        }
        // The Giphy API returns a slew of "renditions" for a given image. 
        // It's critical that we carefully "pick" the best rendition to use.
        guard let animatedRendition = imageInfo.pickAnimatedRendition() else {
            Logger.warn("\(TAG) could not pick gif rendition: \(imageInfo.giphyId)")
            clearAssetRequests()
            return
        }
        guard let stillRendition = imageInfo.pickStillRendition() else {
            Logger.warn("\(TAG) could not pick still rendition: \(imageInfo.giphyId)")
            clearAssetRequests()
            return
        }

        // Start still asset request if necessary.
        if stillAsset != nil || animatedAsset != nil {
            clearStillAssetRequest()
        } else if stillAssetRequest == nil {
            stillAssetRequest = GiphyDownloader.sharedInstance.requestAsset(rendition:stillRendition,
                                                                                priority:.high,
                                                                                success: { [weak self] assetRequest, asset in
                                                                                    guard let strongSelf = self else { return }
                                                                                    if assetRequest != nil && assetRequest != strongSelf.stillAssetRequest {
                                                                                        owsFail("Obsolete request callback.")
                                                                                        return
                                                                                    }
                                                                                    strongSelf.clearStillAssetRequest()
                                                                                    strongSelf.stillAsset = asset
                                                                                    strongSelf.ensureViewState()
                },
                                                                                failure: { [weak self] assetRequest in
                                                                                    guard let strongSelf = self else { return }
                                                                                    if assetRequest != strongSelf.stillAssetRequest {
                                                                                        owsFail("Obsolete request callback.")
                                                                                        return
                                                                                    }
                                                                                    strongSelf.clearStillAssetRequest()
            })
        }

        // Start animated asset request if necessary.
        if animatedAsset != nil {
            clearAnimatedAssetRequest()
        } else if animatedAssetRequest == nil {
            animatedAssetRequest = GiphyDownloader.sharedInstance.requestAsset(rendition:animatedRendition,
                                                                               priority:.low,
                                                                               success: { [weak self] assetRequest, asset in
                                                                                guard let strongSelf = self else { return }
                                                                                if assetRequest != nil && assetRequest != strongSelf.animatedAssetRequest {
                                                                                    owsFail("Obsolete request callback.")
                                                                                    return
                                                                                }
                                                                                // If we have the animated asset, we don't need the still asset.
                                                                                strongSelf.clearAssetRequests()
                                                                                strongSelf.animatedAsset = asset
                                                                                strongSelf.ensureViewState()
                },
                                                                               failure: { [weak self] assetRequest in
                                                                                guard let strongSelf = self else { return }
                                                                                if assetRequest != strongSelf.animatedAssetRequest {
                                                                                    owsFail("Obsolete request callback.")
                                                                                    return
                                                                                }
                                                                                strongSelf.clearAnimatedAssetRequest()
            })
        }
    }

    private func ensureViewState() {
        guard isCellVisible else {
            // Clear image view so we don't animate offscreen GIFs.
            clearViewState()
            return
        }
        guard let asset = pickBestAsset() else {
            clearViewState()
            return
        }
        guard let image = YYImage(contentsOfFile:asset.filePath) else {
            owsFail("\(TAG) could not load asset.")
            clearViewState()
            return
        }
        if imageView == nil {
            let imageView = YYAnimatedImageView()
            self.imageView = imageView
            self.contentView.addSubview(imageView)
            imageView.autoPinToSuperviewEdges()
        }
        guard let imageView = imageView else {
            owsFail("\(TAG) missing imageview.")
            clearViewState()
            return
        }
        imageView.image = image
        self.backgroundColor = nil
    }

    private func clearViewState() {
        imageView?.image = nil
        self.backgroundColor = UIColor(white:0.95, alpha:1.0)
    }

    private func pickBestAsset() -> GiphyAsset? {
        return animatedAsset ?? stillAsset
    }
}
