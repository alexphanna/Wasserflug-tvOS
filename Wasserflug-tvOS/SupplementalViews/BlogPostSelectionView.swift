import SwiftUI
import FloatplaneAPIClient

private let relativeTimeConverter: RelativeDateTimeFormatter = {
	let formatter = RelativeDateTimeFormatter()
	formatter.unitsStyle = .full
	return formatter
}()

struct BlogPostSelectionView: View {
	
	let blogPost: BlogPostModelV3
	@State var geometrySize: CGSize?
	
	@EnvironmentObject var navCoordinator: NavigationCoordinator<WasserflugRoute>
	
	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Button(action: {
				if blogPost.isAccessible {
					navCoordinator.push(route: .blogPostView(blogPostId: blogPost.id, autoPlay: false))
				}
			}, label: {
				// Thumbnail
				ZStack(alignment: .center) {
					MediaThumbnail(thumbnail: blogPost.thumbnail,
								   watchProgresses: FetchRequest(entity: WatchProgress.entity(), sortDescriptors: [], predicate: NSPredicate(format: "blogPostId = %@ and videoId = %@", blogPost.id, blogPost.firstVideoAttachmentId ?? ""), animation: .default))
					
					// Optional lock icon if the post is inaccessible.
					if !blogPost.isAccessible {
						VisualEffectView(effect: UIBlurEffect(style: .dark))
							.frame(width: 150, height: 150)
							.cornerRadius(75.0)
						Image(systemName: "lock.fill")
							.resizable()
							.scaledToFit()
							.frame(width: 100, height: 100)
							.foregroundColor(.white)
					}
				}
				
				HStack(alignment: .top, spacing: 0) {
					let profileImageSize: CGFloat = 35
					if case let .home(creatorOwner) = viewOrigin,
					   let profileImagePath = creatorOwner?.profileImage.path,
					   let profileImageUrl = URL(string: profileImagePath) {
						CachedAsyncImage(url: profileImageUrl, content: { image in
							image
								.resizable()
								.scaledToFit()
								.frame(width: profileImageSize, height: profileImageSize)
								.cornerRadius(profileImageSize / 2)
						}, placeholder: {
							ProgressView()
								.frame(width: profileImageSize, height: profileImageSize)
						})
							.padding([.all], 5)
					}
					VStack(alignment: .leading, spacing: 4) {
						Text(verbatim: blogPost.title)
							.font(.caption2)
							.lineLimit(2)
						HStack(spacing: 10) {
							let meta = blogPost.metadata
							Text("\(meta.hasVideo ? "Video" : meta.hasAudio ? "Audio" : meta.hasGallery ? "Gallery" : "Picture")")
		//						.font(.caption2)
								.padding([.all], 5)
								.foregroundColor(.white)
								.background(.gray)
								.cornerRadius(10)
							
							let duration: TimeInterval = meta.hasVideo ? meta.videoDuration : meta.hasAudio ? meta.audioDuration : 0.0
							if duration != 0 {
								Image(systemName: "clock")
								Text("\(TimeInterval(duration).floatplaneTimestamp)")
							}
							Spacer()
							Text("\(relativeTimeConverter.localizedString(for: blogPost.releaseDate, relativeTo: Date()))")
								.lineLimit(1)
						}
							.font(.system(size: 18, weight: .light))
						if case .home(_) = viewOrigin {
							Text(verbatim: blogPost.creator.title)
								.font(.system(size: 18, weight: .light))
						}
					}
				}
			}
				.padding()
		})
			.buttonStyle(.plain)
            #if os(tvOS)
			.onPlayPauseCommand(perform: {
				if blogPost.isAccessible {
					navCoordinator.push(route: .blogPostView(blogPostId: blogPost.id, autoPlay: true))
				}
			})
            #endif
			.sheet(isPresented: $isSelected, onDismiss: {
				shouldAutoPlay = false
				isSelected = false
			}, content: {
				BlogPostView(viewModel: BlogPostViewModel(fpApiService: fpApiService, id: blogPost.id), shouldAutoPlay: shouldAutoPlay)
			})
	}
}

struct BlogPostSelectionView_Previews: PreviewProvider {
	static var previews: some View {
		BlogPostSelectionView(
			blogPost: MockData.blogPosts.blogPosts.first!
		)
		.previewLayout(.fixed(width: 600, height: 500))
		BlogPostSelectionView(
			blogPost: MockData.blogPosts.blogPosts.first!
		)
		.previewLayout(.fixed(width: 600, height: 500))
	}
}
