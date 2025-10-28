import Foundation
import CoreData
import Logging
import FloatplaneAPIClient
import NIO
import AVKit
import SwiftUI

class VideoViewModel: BaseViewModel, ObservableObject {
	
	enum VideoError: Error, CustomStringConvertible {
		case badResponse
		case noQualityLevelsFound
		
		var description: String {
			switch self {
			case .badResponse:
				return "There was an error retrieving the livestream information. Please try again."
			case .noQualityLevelsFound:
				return "Unable to find any playable content from this video for your device."
			}
		}
	}
	
	@Published var state: ViewModelState<(CdnDeliveryV3Response, ContentVideoV3Response)> = .idle
	
	private let fpApiService: FPAPIService
	let videoAttachment: VideoAttachmentModel
	let contentPost: ContentPostV3Response
	let description: AttributedString
	
	let supportedSpeeds = [AVPlaybackSpeed(rate: 0.5, localizedName: "x0.5"),
						   AVPlaybackSpeed(rate: 0.75, localizedName: "x0.75"),
						   AVPlaybackSpeed(rate: 1.0, localizedName: "x1.0"),
						   AVPlaybackSpeed(rate: 1.25, localizedName: "x1.25"),
						   AVPlaybackSpeed(rate: 1.5, localizedName: "x1.5"),
						   AVPlaybackSpeed(rate: 1.75, localizedName: "x1.75"),
						   AVPlaybackSpeed(rate: 2.0, localizedName: "x2.0")]
	
	var avMetadataItems: [AVMetadataItem] {
		let desc = String(description.characters)
		
		var releaseDate = videoAttachment.releaseDate?.formatted(.dateTime) ?? ""
		if releaseDate == "" {
			releaseDate = contentPost.releaseDate.formatted(.dateTime)
		}
		
		return [
			metadataItem(identifier: .commonIdentifierTitle, value: videoAttachment.title),
			metadataItem(identifier: .commonIdentifierDescription, value: desc),
			metadataItem(identifier: .iTunesMetadataTrackSubTitle, value: releaseDate),
//			metadataItem(identifier: .commonIdentifierArtwork, value: videoAttachment.thumbnail.path),
		]
	}
	
	private(set) var qualityLevels: [String: (URL, CdnDeliveryV3Variant)] = [:]
	
	init(fpApiService: FPAPIService, videoAttachment: VideoAttachmentModel, contentPost: ContentPostV3Response, description: AttributedString) {
		self.fpApiService = fpApiService
		self.videoAttachment = videoAttachment
		self.contentPost = contentPost
		self.description = description
	}
	
	func load() {
		Task { @MainActor in
			self.state = .loading
			
			let type: CDNV2API.ModelType_getDeliveryInfo = .vod
			self.logger.info("Loading video information.", metadata: [
				"type": "\(type)",
				"id": "\(videoAttachment.guid)",
			])
			
			let deliveryInfo: CdnDeliveryV3Response
			let videoContent: ContentVideoV3Response
			do {
				deliveryInfo = try await self.fpApiService.getDeliveryInfo(scenario: .ondemand, entityId: videoAttachment.guid, outputKind: nil)
				videoContent = try await self.fpApiService.getVideoContent(id: videoAttachment.id)
			} catch {
				self.state = .failed(error)
				return
			}
			.whenComplete { result in
				DispatchQueue.main.async {
					switch result {
					case let .success(response):
						self.logger.notice("Received video information.", metadata: [
							"cdn": "\(response.cdn)",
						])
						let baseCdn = response.cdn
						let pathTemplate = response.resource.uri!
                        var screenWidth = UIScreen.main.bounds.width
                        if screenWidth < UIScreen.main.bounds.height {
                            screenWidth = UIScreen.main.bounds.height
                        }
						let levels = response.resource.data.qualityLevels?
							.filter({ qualityLevel in
								// Filter out resolutions larger than the device's screen resolution.
								// LTT's videos at the stated 1080p are actually 2160x1080 instead of 1920x1080, like most
								// television screens are. With a strict comparison, LTT 1080p videos would be filtered
								// out on 1080p televisions. Thus, add 15% to the screen size to account for this. This
								// will allow for actually getting 1080p on 1080p screens, with only a little bit of downsampling.
								// But, it wouldn't make sense to show 4k on a 1080p screen. Waste of bandwidth, and the
								// hardware may not like the massive downsampling.
								let result = CGFloat(qualityLevel.width) <= (screenWidth * 1.15)
								if !result {
									self.logger.warning("Ignoring quality level \(String(describing: qualityLevel)) due to larger-than-screen width of \(screenWidth)")
								}
								return result
							})
							.compactMap({ (qualityLevel) -> (String, URL)? in
								// Map the quality levels to the correct URL
								guard let param = response.resource.data.qualityLevelParams?[qualityLevel.name] else {
									self.logger.warning("Ignoring quality level \(qualityLevel.name) because no parameter information was found.")
									return nil
								}
								let path = pathTemplate
									.replacingOccurrences(of: "{qualityLevels}", with: qualityLevel.name)
									.replacingOccurrences(of: "{qualityLevelParams.token}", with: param.token)
								return (qualityLevel.name, URL(string: baseCdn + path)!)
							})
							?? [(String, URL)]()
						self.qualityLevels = Dictionary(uniqueKeysWithValues: levels)
						
						if self.qualityLevels.isEmpty {
							self.logger.warning("No quality levels were able to be parsed from the video response. Showing an error to the user.", metadata: [
								"id": "\(self.videoAttachment.guid)",
								"qualityLevelNames": "\(response.resource.data.qualityLevels?.map({ $0.name }).joined(separator: ", ") ?? "no quality levels found")",
								"qualityLevelParams": "\(response.resource.data.qualityLevelParams?.keys.joined(separator: ", ") ?? "no params found")",
							])
							self.state = .failed(VideoError.noQualityLevelsFound)
						}
						
						self.state = .loaded(response)
					case let .failure(error):
						self.logger.error("Encountered an unexpected error while loading video information. Reporting the error to the user. Error: \(String(reflecting: error))")
						self.state = .failed(error)
					}
				}
				return enabled && !hidden && videoSizeOkay
			})
			
			let qualityLevelsAndUrls = filteredVariants?.compactMap({ variant -> (String, (URL, CdnDeliveryV3Variant))? in
				// Map the quality level to the correct URL
				if let url = DeliveryHelper.getBestUrl(variant: variant, group: group) {
					return (variant.name, (url, variant))
				}
				return nil
			}) ?? []
			self.qualityLevels = Dictionary(uniqueKeysWithValues: qualityLevelsAndUrls)
			
			if self.qualityLevels.isEmpty {
				self.logger.warning("No quality levels were able to be parsed from the video response. Showing an error to the user.", metadata: [
					"id": "\(self.videoAttachment.guid)",
					"qualityLevelNames": "\(group?.variants.map(\.name).joined(separator: ", ") ?? "<nil>")",
				])
				self.state = .failed(VideoError.noQualityLevelsFound)
			}
			
			self.state = .loaded((deliveryInfo, videoContent))
		}
	}
	
	private func metadataItem(identifier: AVMetadataIdentifier, value: Any) -> AVMetadataItem {
		let item = AVMutableMetadataItem()
		item.value = value as? NSCopying & NSObjectProtocol
		item.identifier = identifier
		item.extendedLanguageTag = "und" // undefined (wildcard) language
		return item
	}
	
	func createAVPlayerItem(desiredQuality: String) -> AVPlayerItem {
		self.logger.notice("Creating new AVPlayerItem for video playback.", metadata: [
			"id": "\(videoAttachment.guid)",
			"desiredQuality": "\(desiredQuality)",
		])
		var url = qualityLevels[desiredQuality]?.0
		if url == nil {
			let sortedUrls = qualityLevels
				.sorted(by: { $0.value.1.meta?.video?.height ?? 0 < $1.value.1.meta?.video?.height ?? 0 })
			// Just get the highest available. It's difficult to be smart about next highest from the selection, because the label isn't
			// sortable, so let's just guess that if a desired quality isn't available, it's because it was too high and this video
			// doesn't have it, but the user wants higher quality. It's also an Apple TV instead of a mobiel device, so higher quality
			// is expected. The expected use case is 4K is desired, but only up to 1080p is available, so default to 1080p.
			url = sortedUrls
				.last?
				.value.0
		}
		guard let url else {
			self.logger.critical("No playable URL was found for the video. Invalid state. Closing the application.")
			fatalError()
		}
		self.logger.debug("Setting up AVPlayerItem with matched content url.", metadata: [
			"url": "\(url)",
		])
		
		let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: HTTPCookieStorage.shared.cookies as Any])
		let templateItem = AVPlayerItem(asset: asset)
		templateItem.externalMetadata = avMetadataItems
		
		return templateItem
	}
	
	func updateProgress(progressSeconds: Int, managedObjectContext: NSManagedObjectContext) {
		Task {
			guard case let .loaded((_, videoModel)) = self.state else {
				return
			}
			
			logger.notice("Attempting to record watch progress for a video.", metadata: [
				"blogPostId": "\(videoModel.primaryBlogPost)",
				"videoId": "\(videoModel.id)",
				"progressSeconds": "\(progressSeconds)",
			])
			
			// First save to local storage
			Self.updateLocalProgress(logger: logger, blogPostId: contentPost.id, videoId: videoAttachment.id, videoDuration: videoAttachment.duration, progressSeconds: progressSeconds, managedObjectContext: managedObjectContext)
			
			// Next save to FP API
			do {
				try await self.fpApiService.updateProgress(id: videoModel.id, contentType: .video, progress: progressSeconds)
			} catch {
				logger.warning("Could not update progress. Not showing an error as this is not critical.", metadata: [
					"id": "\(videoModel.id)",
					"progress": "\(progressSeconds)",
				])
			}
		}
	}
	
	static func updateLocalProgress(logger: Logger, blogPostId: String, videoId: String, videoDuration: Double, progressSeconds: Int, managedObjectContext: NSManagedObjectContext) {
		let fetchRequest = WatchProgress.fetchRequest()
		let progress: Double = Double(progressSeconds) / videoDuration
		do {
			fetchRequest.predicate = NSPredicate(format: "blogPostId = %@ and videoId = %@", blogPostId, videoId)
			if let fetchResult = (try? managedObjectContext.fetch(fetchRequest))?.first {
				logger.info("Did find previous watchProgress. Will mutate with new progress.", metadata: [
					"previous": "\(String(reflecting: fetchResult))",
				])
				fetchResult.progress = progress
			} else {
				logger.info("No previous watchProgress found. Will create new WatchProgress entity.")
				let newWatchProgress = WatchProgress(context: managedObjectContext)
				newWatchProgress.blogPostId = blogPostId
				newWatchProgress.videoId = videoId
				newWatchProgress.progress = progress
			}
			try managedObjectContext.save()
			logger.info("Successfully saved watch progress for \(blogPostId) \(videoId)")
		} catch {
			logger.error("Error saving watch progress for for \(blogPostId) \(videoId): \(String(reflecting: error))")
			// Otherwise, this has minimal impact on the user of this application.
			// No need to further handle the error.
		}
	}
}
