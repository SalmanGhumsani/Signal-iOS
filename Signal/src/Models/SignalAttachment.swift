//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

import Foundation
import MobileCoreServices

enum SignalAttachmentError: Error {
    case missingData
    case fileSizeTooLarge
    case invalidData
    case couldNotParseImage
    case couldNotConvertToJpeg
    case invalidFileFormat
}

extension SignalAttachmentError: LocalizedError {
    public var errorDescription: String {
        switch self {
        case .missingData:
            return NSLocalizedString("ATTACHMENT_ERROR_MISSING_DATA", comment: "Attachment error message for attachments without any data")
        case .fileSizeTooLarge:
            return NSLocalizedString("ATTACHMENT_ERROR_FILE_SIZE_TOO_LARGE", comment: "Attachment error message for attachments whose data exceed file size limits")
        case .invalidData:
            return NSLocalizedString("ATTACHMENT_ERROR_INVALID_DATA", comment: "Attachment error message for attachments with invalid data")
        case .couldNotParseImage:
            return NSLocalizedString("ATTACHMENT_ERROR_COULD_NOT_PARSE_IMAGE", comment: "Attachment error message for image attachments which cannot be parsed")
        case .couldNotConvertToJpeg:
            return NSLocalizedString("ATTACHMENT_ERROR_COULD_NOT_CONVERT_TO_JPEG", comment: "Attachment error message for image attachments which could not be converted to JPEG")
        case .invalidFileFormat:
            return NSLocalizedString("ATTACHMENT_ERROR_INVALID_FILE_FORMAT", comment: "Attachment error message for attachments with an invalid file format")
        }
    }
}

enum TSImageQuality {
    case uncropped
    case high
    case medium
    case low
}

// Represents a possible attachment to upload.
// The attachment may be invalid.
//
// Signal attachments are subject to validation and 
// in some cases, file format conversion.
//
// This class gathers that logic.  It offers factory methods
// for attachments that do the necessary work. 
//
// The return value for the factory methods will be nil if the input is nil.
//
// [SignalAttachment hasError] will be true for non-valid attachments.
//
// TODO: Perhaps do conversion off the main thread?
class SignalAttachment: NSObject {

    static let TAG = "[SignalAttachment]"

    // MARK: Properties

    let dataSource: DataSource

    public var data: Data {
        return dataSource.data()
    }
    public var dataLength: UInt {
        return dataSource.dataLength()
    }
    public var dataUrl: URL? {
        return dataSource.dataUrl()
    }
    public var sourceFilename: String? {
        return dataSource.sourceFilename
    }
    public var isValidImage: Bool {
        return dataSource.isValidImage()
    }

    // Attachment types are identified using UTIs.
    //
    // See: https://developer.apple.com/library/content/documentation/Miscellaneous/Reference/UTIRef/Articles/System-DeclaredUniformTypeIdentifiers.html
    let dataUTI: String

    var error: SignalAttachmentError? {
        didSet {
            AssertIsOnMainThread()

            assert(oldValue == nil)
            Logger.verbose("\(SignalAttachment.TAG) Attachment has error: \(String(describing: error))")
        }
    }

    // To avoid redundant work of repeatedly compressing/uncompressing
    // images, we cache the UIImage associated with this attachment if
    // possible.
    public var image: UIImage?

    private(set) public var isVoiceMessage = false

    // MARK: Constants

    /**
     * Media Size constraints from Signal-Android
     *
     * https://github.com/WhisperSystems/Signal-Android/blob/master/src/org/thoughtcrime/securesms/mms/PushMediaConstraints.java
     */
    static let kMaxFileSizeAnimatedImage = UInt(25 * 1024 * 1024)
    static let kMaxFileSizeImage = UInt(6 * 1024 * 1024)
    static let kMaxFileSizeVideo = UInt(100 * 1024 * 1024)
    static let kMaxFileSizeAudio = UInt(100 * 1024 * 1024)
    static let kMaxFileSizeGeneric = UInt(100 * 1024 * 1024)

    // MARK: Constructor

    // This method should not be called directly; use the factory
    // methods instead.
    internal required init(dataSource: DataSource, dataUTI: String) {
        self.dataSource = dataSource
        self.dataUTI = dataUTI
        super.init()
    }

    // MARK: Methods

    var hasError: Bool {
        return error != nil
    }

    var errorName: String? {
        guard let error = error else {
            // This method should only be called if there is an error.
            owsFail("Missing error")
            return nil
        }

        return "\(error)"
    }

    var localizedErrorDescription: String? {
        guard let error = self.error else {
            // This method should only be called if there is an error.
            owsFail("Missing error")
            return nil
        }

        return "\(error.errorDescription)"
    }

    class var missingDataErrorMessage: String {
        return SignalAttachmentError.missingData.errorDescription
    }

    // Returns the MIME type for this attachment or nil if no MIME type
    // can be identified.
    var mimeType: String {
        if isVoiceMessage {
            // Legacy iOS clients don't handle "audio/mp4" files correctly;
            // they are written to disk as .mp4 instead of .m4a which breaks
            // playback.  So we send voice messages as "audio/aac" to work
            // around this.
            //
            // TODO: Remove this Nov. 2016 or after.
            return "audio/aac"
        }

        if let filename = sourceFilename {
            let fileExtension = (filename as NSString).pathExtension
            if fileExtension.characters.count > 0 {
                if let mimeType = MIMETypeUtil.mimeType(forFileExtension:fileExtension) {
                    // UTI types are an imperfect means of representing file type;
                    // file extensions are also imperfect but far more reliable and
                    // comprehensive so we always prefer to try to deduce MIME type
                    // from the file extension.
                    return mimeType
                }
            }
        }
        if dataUTI == kOversizeTextAttachmentUTI {
            return OWSMimeTypeOversizeTextMessage
        }
        if dataUTI == kUnknownTestAttachmentUTI {
            return OWSMimeTypeUnknownForTests
        }
        guard let mimeType = UTTypeCopyPreferredTagWithClass(dataUTI as CFString, kUTTagClassMIMEType) else {
            return OWSMimeTypeApplicationOctetStream
        }
        return mimeType.takeRetainedValue() as String
    }

    // Use the filename if known. If not, e.g. if the attachment was copy/pasted, we'll generate a filename
    // like: "signal-2017-04-24-095918.zip"
    var filenameOrDefault: String {
        if let filename = sourceFilename {
            return filename
        } else {
            let kDefaultAttachmentName = "signal"

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "YYYY-MM-dd-HHmmss"
            let dateString = dateFormatter.string(from: Date())

            let withoutExtension = "\(kDefaultAttachmentName)-\(dateString)"
            if let fileExtension = self.fileExtension {
                return "\(withoutExtension).\(fileExtension)"
            }

            return withoutExtension
        }
    }

    // Returns the file extension for this attachment or nil if no file extension
    // can be identified.
    var fileExtension: String? {
        if let filename = sourceFilename {
            let fileExtension = (filename as NSString).pathExtension
            if fileExtension.characters.count > 0 {
                return fileExtension
            }
        }
        if dataUTI == kOversizeTextAttachmentUTI {
            return kOversizeTextAttachmentFileExtension
        }
        if dataUTI == kUnknownTestAttachmentUTI {
            return "unknown"
        }
        guard let fileExtension = MIMETypeUtil.fileExtension(forUTIType:dataUTI) else {
            return nil
        }
        return fileExtension
    }

    // Returns the set of UTIs that correspond to valid _input_ image formats
    // for Signal attachments.
    //
    // Image attachments may be converted to another image format before 
    // being uploaded.
    private class var inputImageUTISet: Set<String> {
         // HEIC is valid input, but not valid output. Non-iOS11 clients do not support it.
        let heicSet: Set<String> = Set(["public.heic", "public.heif"])

        return MIMETypeUtil.supportedImageUTITypes()
            .union(animatedImageUTISet)
            .union(heicSet)
    }

    // Returns the set of UTIs that correspond to valid _output_ image formats
    // for Signal attachments.
    private class var outputImageUTISet: Set<String> {
        return MIMETypeUtil.supportedImageUTITypes().union(animatedImageUTISet)
    }

    // Returns the set of UTIs that correspond to valid animated image formats
    // for Signal attachments.
    private class var animatedImageUTISet: Set<String> {
        return MIMETypeUtil.supportedAnimatedImageUTITypes()
    }

    // Returns the set of UTIs that correspond to valid video formats
    // for Signal attachments.
    private class var videoUTISet: Set<String> {
        return MIMETypeUtil.supportedVideoUTITypes()
    }

    // Returns the set of UTIs that correspond to valid audio formats
    // for Signal attachments.
    private class var audioUTISet: Set<String> {
        return MIMETypeUtil.supportedAudioUTITypes()
    }

    // Returns the set of UTIs that correspond to valid image, video and audio formats
    // for Signal attachments.
    private class var mediaUTISet: Set<String> {
        return audioUTISet.union(videoUTISet).union(animatedImageUTISet).union(inputImageUTISet)
    }

    public var isImage: Bool {
        return SignalAttachment.outputImageUTISet.contains(dataUTI)
    }

    public var isAnimatedImage: Bool {
        return SignalAttachment.animatedImageUTISet.contains(dataUTI)
    }

    public var isVideo: Bool {
        return SignalAttachment.videoUTISet.contains(dataUTI)
    }

    public var isAudio: Bool {
        return SignalAttachment.audioUTISet.contains(dataUTI)
    }

    public class func pasteboardHasPossibleAttachment() -> Bool {
        return UIPasteboard.general.numberOfItems > 0
    }

    public class func pasteboardHasText() -> Bool {
        if UIPasteboard.general.numberOfItems < 1 {
            return false
        }
        let itemSet = IndexSet(integer:0)
        guard let pasteboardUTITypes = UIPasteboard.general.types(forItemSet:itemSet) else {
            return false
        }
        let pasteboardUTISet = Set<String>(pasteboardUTITypes[0])

        // The pasteboard can be populated with multiple UTI types
        // with different payloads.  iMessage for example will copy
        // an animated GIF to the pasteboard with the following UTI
        // types:
        //
        // * "public.url-name"
        // * "public.utf8-plain-text"
        // * "com.compuserve.gif"
        //
        // We want to paste the animated GIF itself, not it's name.
        //
        // In general, our rule is to prefer non-text pasteboard
        // contents, so we return true IFF there is a text UTI type
        // and there is no non-text UTI type.
        var hasTextUTIType = false
        var hasNonTextUTIType = false
        for utiType in pasteboardUTISet {
            if UTTypeConformsTo(utiType as CFString, kUTTypeText) {
                hasTextUTIType = true
            } else if mediaUTISet.contains(utiType) {
                hasNonTextUTIType = true
            }
        }
        if pasteboardUTISet.contains(kUTTypeURL as String) {
            // Treat URL as a textual UTI type.
            hasTextUTIType = true
        }
        if hasNonTextUTIType {
            return false
        }
        return hasTextUTIType
    }

    // Returns an attachment from the pasteboard, or nil if no attachment
    // can be found.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    public class func attachmentFromPasteboard() -> SignalAttachment? {
        guard UIPasteboard.general.numberOfItems >= 1 else {
            return nil
        }
        // If pasteboard contains multiple items, use only the first.
        let itemSet = IndexSet(integer:0)
        guard let pasteboardUTITypes = UIPasteboard.general.types(forItemSet:itemSet) else {
            return nil
        }
        let pasteboardUTISet = Set<String>(pasteboardUTITypes[0])
        for dataUTI in inputImageUTISet {
            if pasteboardUTISet.contains(dataUTI) {
                guard let data = dataForFirstPasteboardItem(dataUTI:dataUTI) else {
                    owsFail("\(TAG) Missing expected pasteboard data for UTI: \(dataUTI)")
                    return nil
                }
                let dataSource = DataSourceValue.dataSource(with:data, utiType: dataUTI)
                return imageAttachment(dataSource : dataSource, dataUTI : dataUTI)
            }
        }
        for dataUTI in videoUTISet {
            if pasteboardUTISet.contains(dataUTI) {
                guard let data = dataForFirstPasteboardItem(dataUTI:dataUTI) else {
                    owsFail("\(TAG) Missing expected pasteboard data for UTI: \(dataUTI)")
                    return nil
                }
                let dataSource = DataSourceValue.dataSource(with:data, utiType: dataUTI)
                return videoAttachment(dataSource : dataSource, dataUTI : dataUTI)
            }
        }
        for dataUTI in audioUTISet {
            if pasteboardUTISet.contains(dataUTI) {
                guard let data = dataForFirstPasteboardItem(dataUTI:dataUTI) else {
                    owsFail("\(TAG) Missing expected pasteboard data for UTI: \(dataUTI)")
                    return nil
                }
                let dataSource = DataSourceValue.dataSource(with:data, utiType: dataUTI)
                return audioAttachment(dataSource : dataSource, dataUTI : dataUTI)
            }
        }

        let dataUTI = pasteboardUTISet[pasteboardUTISet.startIndex]
        guard let data = dataForFirstPasteboardItem(dataUTI:dataUTI) else {
            owsFail("\(TAG) Missing expected pasteboard data for UTI: \(dataUTI)")
            return nil
        }
        let dataSource = DataSourceValue.dataSource(with:data, utiType: dataUTI)
        return genericAttachment(dataSource : dataSource, dataUTI : dataUTI)
    }

    // This method should only be called for dataUTIs that
    // are appropriate for the first pasteboard item.
    private class func dataForFirstPasteboardItem(dataUTI: String) -> Data? {
        let itemSet = IndexSet(integer:0)
        guard let datas = UIPasteboard.general.data(forPasteboardType:dataUTI, inItemSet:itemSet) else {
            owsFail("\(TAG) Missing expected pasteboard data for UTI: \(dataUTI)")
            return nil
        }
        guard datas.count > 0 else {
            owsFail("\(TAG) Missing expected pasteboard data for UTI: \(dataUTI)")
            return nil
        }
        guard let data = datas[0] as? Data else {
            owsFail("\(TAG) Missing expected pasteboard data for UTI: \(dataUTI)")
            return nil
        }
        return data
    }

    // MARK: Image Attachments

    // Factory method for an image attachment.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func imageAttachment(dataSource: DataSource?, dataUTI: String) -> SignalAttachment {
        assert(dataUTI.characters.count > 0)

        assert(dataSource != nil)
        guard let dataSource = dataSource else {
            let attachment = SignalAttachment(dataSource : DataSourceValue.emptyDataSource(), dataUTI: dataUTI)
            attachment.error = .missingData
            return attachment
        }

        let attachment = SignalAttachment(dataSource : dataSource, dataUTI: dataUTI)

        guard inputImageUTISet.contains(dataUTI) else {
            attachment.error = .invalidFileFormat
            return attachment
        }

        guard dataSource.dataLength() > 0 else {
            owsFail("\(self.TAG) in \(#function) imageData was empty")
            attachment.error = .invalidData
            return attachment
        }

        if animatedImageUTISet.contains(dataUTI) {
            guard dataSource.dataLength() <= kMaxFileSizeAnimatedImage else {
                attachment.error = .fileSizeTooLarge
                return attachment
            }
            // Never re-encode animated images (i.e. GIFs) as JPEGs.
            Logger.verbose("\(TAG) Sending raw \(attachment.mimeType) to retain any animation")
            return attachment
        } else {
            guard let image = UIImage(data:dataSource.data()) else {
                attachment.error = .couldNotParseImage
                return attachment
            }
            attachment.image = image

            if isInputImageValidOutputImage(image: image, dataSource: dataSource, dataUTI: dataUTI) {
                Logger.verbose("\(TAG) Sending raw \(attachment.mimeType)")
                return attachment
            }

            Logger.verbose("\(TAG) Compressing attachment as image/jpeg")
            return compressImageAsJPEG(image : image, attachment : attachment, filename:dataSource.sourceFilename)
        }
    }

    private class func defaultImageUploadQuality() -> TSImageQuality {
        // Currently default to a original image quality and size.
        return .uncropped
    }

    // If the proposed attachment already conforms to the
    // file size and content size limits, don't recompress it.
    private class func isInputImageValidOutputImage(image: UIImage?, dataSource: DataSource?, dataUTI: String) -> Bool {
        guard let image = image else {
            return false
        }
        guard let dataSource = dataSource else {
            return false
        }
        guard SignalAttachment.outputImageUTISet.contains(dataUTI) else {
            return false
        }

        let maxSize = maxSizeForImage(image: image,
                                      imageUploadQuality:defaultImageUploadQuality())
        if image.size.width <= maxSize &&
            image.size.height <= maxSize &&
            dataSource.dataLength() <= kMaxFileSizeImage {
            return true
        }
        return false
    }

    // Factory method for an image attachment.
    //
    // NOTE: The attachment returned by this method may nil or not be valid.
    //       Check the attachment's error property.
    public class func imageAttachment(image: UIImage?, dataUTI: String, filename: String?) -> SignalAttachment {
        assert(dataUTI.characters.count > 0)

        guard let image = image else {
            let dataSource = DataSourceValue.emptyDataSource()
            dataSource.sourceFilename = filename
            let attachment = SignalAttachment(dataSource:dataSource, dataUTI: dataUTI)
            attachment.error = .missingData
            return attachment
        }

        // Make a placeholder attachment on which to hang errors if necessary.
        let dataSource = DataSourceValue.emptyDataSource()
        dataSource.sourceFilename = filename
        let attachment = SignalAttachment(dataSource : dataSource, dataUTI: dataUTI)
        attachment.image = image

        Logger.verbose("\(TAG) Writing \(attachment.mimeType) as image/jpeg")
        return compressImageAsJPEG(image : image, attachment : attachment, filename:filename)
    }

    private class func compressImageAsJPEG(image: UIImage, attachment: SignalAttachment, filename: String?) -> SignalAttachment {
        assert(attachment.error == nil)

        var imageUploadQuality = defaultImageUploadQuality()

        while true {
            let maxSize = maxSizeForImage(image: image, imageUploadQuality:imageUploadQuality)
            var dstImage: UIImage! = image
            if image.size.width > maxSize ||
                image.size.height > maxSize {
                dstImage = imageScaled(image, toMaxSize: maxSize)
            }
            guard let jpgImageData = UIImageJPEGRepresentation(dstImage,
                                                               jpegCompressionQuality(imageUploadQuality:imageUploadQuality)) else {
                                                                attachment.error = .couldNotConvertToJpeg
                                                                return attachment
            }

            guard let dataSource = DataSourceValue.dataSource(with:jpgImageData, fileExtension:"jpg") else {
                attachment.error = .couldNotConvertToJpeg
                return attachment
            }
            dataSource.sourceFilename = filename

            if UInt(jpgImageData.count) <= kMaxFileSizeImage {
                let recompressedAttachment = SignalAttachment(dataSource : dataSource, dataUTI: kUTTypeJPEG as String)
                recompressedAttachment.image = dstImage
                return recompressedAttachment
            }

            // If the JPEG output is larger than the file size limit,
            // continue to try again by progressively reducing the
            // image upload quality.
            switch imageUploadQuality {
            case .uncropped:
                imageUploadQuality = .high
            case .high:
                imageUploadQuality = .medium
            case .medium:
                imageUploadQuality = .low
            case .low:
                attachment.error = .fileSizeTooLarge
                return attachment
            }
        }
    }

    private class func imageScaled(_ image: UIImage, toMaxSize size: CGFloat) -> UIImage {
        var scaleFactor: CGFloat
        let aspectRatio: CGFloat = image.size.height / image.size.width
        if aspectRatio > 1 {
            scaleFactor = size / image.size.width
        } else {
            scaleFactor = size / image.size.height
        }
        let newSize = CGSize(width: CGFloat(image.size.width * scaleFactor), height: CGFloat(image.size.height * scaleFactor))
        UIGraphicsBeginImageContext(newSize)
        image.draw(in: CGRect(x: CGFloat(0), y: CGFloat(0), width: CGFloat(newSize.width), height: CGFloat(newSize.height)))
        let updatedImage: UIImage? = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return updatedImage!
    }

    private class func maxSizeForImage(image: UIImage, imageUploadQuality: TSImageQuality) -> CGFloat {
        switch imageUploadQuality {
        case .uncropped:
            return max(image.size.width, image.size.height)
        case .high:
            return 2048
        case .medium:
            return 1024
        case .low:
            return 512
        }
    }

    private class func jpegCompressionQuality(imageUploadQuality: TSImageQuality) -> CGFloat {
        switch imageUploadQuality {
        case .uncropped:
            return 1
        case .high:
            return 0.9
        case .medium:
            return 0.5
        case .low:
            return 0.3
        }
    }

    // MARK: Video Attachments

    // Factory method for video attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func videoAttachment(dataSource: DataSource?, dataUTI: String) -> SignalAttachment {
        return newAttachment(dataSource : dataSource,
                             dataUTI : dataUTI,
                             validUTISet : videoUTISet,
                             maxFileSize : kMaxFileSizeVideo)
    }

    // MARK: Audio Attachments

    // Factory method for audio attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func audioAttachment(dataSource: DataSource?, dataUTI: String) -> SignalAttachment {
        return newAttachment(dataSource : dataSource,
                             dataUTI : dataUTI,
                             validUTISet : audioUTISet,
                             maxFileSize : kMaxFileSizeAudio)
    }

    // MARK: Oversize Text Attachments

    // Factory method for oversize text attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func oversizeTextAttachment(text: String?) -> SignalAttachment {
        let dataSource = DataSourceValue.dataSource(withOversizeText:text)
        return newAttachment(dataSource : dataSource,
                             dataUTI : kOversizeTextAttachmentUTI,
                             validUTISet : nil,
                             maxFileSize : kMaxFileSizeGeneric)
    }

    // MARK: Generic Attachments

    // Factory method for generic attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func genericAttachment(dataSource: DataSource?, dataUTI: String) -> SignalAttachment {
        return newAttachment(dataSource : dataSource,
                             dataUTI : dataUTI,
                             validUTISet : nil,
                             maxFileSize : kMaxFileSizeGeneric)
    }

    // MARK: Voice Messages

    public class func voiceMessageAttachment(dataSource: DataSource?, dataUTI: String) -> SignalAttachment {
        let attachment = audioAttachment(dataSource : dataSource, dataUTI : dataUTI)
        attachment.isVoiceMessage = true
        return attachment
    }

    // MARK: Attachments

    // Factory method for attachments of any kind.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    public class func attachment(dataSource: DataSource?, dataUTI: String) -> SignalAttachment {
        if inputImageUTISet.contains(dataUTI) {
            return imageAttachment(dataSource : dataSource, dataUTI : dataUTI)
        } else if videoUTISet.contains(dataUTI) {
            return videoAttachment(dataSource : dataSource, dataUTI : dataUTI)
        } else if audioUTISet.contains(dataUTI) {
            return audioAttachment(dataSource : dataSource, dataUTI : dataUTI)
        } else {
            return genericAttachment(dataSource : dataSource, dataUTI : dataUTI)
        }
    }

    public class func empty() -> SignalAttachment {
        return SignalAttachment.attachment(dataSource : DataSourceValue.emptyDataSource(),
                                           dataUTI: kUTTypeContent as String)
    }

    // MARK: Helper Methods

    private class func newAttachment(dataSource: DataSource?,
                                     dataUTI: String,
                                     validUTISet: Set<String>?,
                                     maxFileSize: UInt) -> SignalAttachment {
        assert(dataUTI.characters.count > 0)

        assert(dataSource != nil)
        guard let dataSource = dataSource else {
            let attachment = SignalAttachment(dataSource : DataSourceValue.emptyDataSource(), dataUTI: dataUTI)
            attachment.error = .missingData
            return attachment
        }

        let attachment = SignalAttachment(dataSource : dataSource, dataUTI: dataUTI)

        if let validUTISet = validUTISet {
            guard validUTISet.contains(dataUTI) else {
                attachment.error = .invalidFileFormat
                return attachment
            }
        }

        guard dataSource.dataLength() > 0 else {
            owsFail("Empty attachment")
            assert(dataSource.dataLength() > 0)
            attachment.error = .invalidData
            return attachment
        }

        guard dataSource.dataLength() <= maxFileSize else {
            attachment.error = .fileSizeTooLarge
            return attachment
        }

        // Attachment is valid
        return attachment
    }
}
